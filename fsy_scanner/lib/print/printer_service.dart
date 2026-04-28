import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_thermal_printer/flutter_thermal_printer.dart';
import 'package:flutter_thermal_printer/utils/printer.dart';

import '../db/database_helper.dart';
import '../db/participants_dao.dart';
import '../db/sync_queue_dao.dart';
import '../models/participant.dart';
import 'receipt_builder.dart';

class PrinterService {
  static final _printerPlugin = FlutterThermalPrinter.instance;

  // Simple in‑memory queue of failed print jobs
  static final List<_FailedPrintJob> _failedJobs = [];

  /// Scan for nearby Bluetooth printers
  static Future<List<Printer>> scanPrinters() async {
    try {
      await _printerPlugin.getPrinters(connectionTypes: [ConnectionType.BLE]);
      return await _printerPlugin.devicesStream.first.timeout(
        const Duration(seconds: 5),
        onTimeout: () => [],
      );
    } catch (e) {
      debugPrint('[PrinterService] Scan error: $e');
      return [];
    }
  }

  /// Print receipt for a participant. Fire‑and‑forget.
  /// On failure, adds the job to a retry queue.
  static Future<bool> printReceipt(
      Participant participant, String deviceId) async {
    try {
      debugPrint('[PrinterService] Starting print for ${participant.fullName}');

      final db = await DatabaseHelper.database;

      final eventResult = await db
          .query('app_settings', where: 'key = ?', whereArgs: ['event_name']);
      final eventName = eventResult.isNotEmpty
          ? eventResult.first['value'] as String
          : 'FSY Event';

      final printerResult = await db.query('app_settings',
          where: 'key = ?', whereArgs: ['printer_address']);
      if (printerResult.isEmpty) {
        debugPrint('[PrinterService] No printer address saved');
        _addFailedJob(participant, deviceId);
        return false;
      }
      final printerAddress = printerResult.first['value'] as String;

      await _printerPlugin.getPrinters(connectionTypes: [ConnectionType.BLE]);
      final printers = await _printerPlugin.devicesStream.first.timeout(
        const Duration(seconds: 5),
        onTimeout: () => [],
      );

      final targetPrinter = printers.firstWhere(
        (p) => p.address == printerAddress,
        orElse: () => throw Exception('Printer not found or out of range'),
      );

      final connected = await _printerPlugin.connect(targetPrinter);
      if (!connected) {
        debugPrint('[PrinterService] Failed to connect');
        _addFailedJob(participant, deviceId);
        return false;
      }

      final receiptText =
          ReceiptBuilder.build(participant, eventName, deviceId);
      final bytes = utf8.encode(receiptText);
      await _printerPlugin.printData(targetPrinter, bytes);
      await _printerPlugin.disconnect(targetPrinter);

      // Success – record locally and enqueue mark_printed task
      final now = DateTime.now().millisecondsSinceEpoch;
      unawaited(_onPrintSuccess(participant, now));

      debugPrint('[PrinterService] Print successful');
      return true;
    } catch (e) {
      debugPrint('[PrinterService] Print failed: $e');
      _addFailedJob(participant, deviceId);
      return false;
    }
  }

  /// Add a failed job to the retry queue
  static void _addFailedJob(Participant participant, String deviceId) {
    // Avoid duplicates
    if (!_failedJobs.any((job) => job.participant.id == participant.id)) {
      _failedJobs
          .add(_FailedPrintJob(participant: participant, deviceId: deviceId));
    }
  }

  /// Retry all failed print jobs. Call this e.g. from Settings.
  static Future<int> retryFailedPrints() async {
    if (_failedJobs.isEmpty) return 0;
    int success = 0;
    final jobs = List<_FailedPrintJob>.from(_failedJobs);
    _failedJobs.clear();
    for (final job in jobs) {
      final ok = await printReceipt(job.participant, job.deviceId);
      if (ok) success++;
    }
    return success;
  }

  /// Number of currently queued failed jobs
  static int get failedJobCount => _failedJobs.length;

  static Future<void> _onPrintSuccess(
      Participant participant, int printedAt) async {
    try {
      final db = await DatabaseHelper.database;
      final dao = ParticipantsDao(db);
      await dao.markPrintedLocally(participant.id, printedAt);

      await SyncQueueDao.enqueueTask(
        SyncQueueDao.typeMarkPrinted,
        {
          'participantId': participant.id,
          'sheetsRow': participant.sheetsRow,
          'printedAt': printedAt,
        },
      );
    } catch (e) {
      debugPrint('[PrinterService] Error recording print: $e');
    }
  }
}

class _FailedPrintJob {
  final Participant participant;
  final String deviceId;
  _FailedPrintJob({required this.participant, required this.deviceId});
}
