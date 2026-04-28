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

  /// Print receipt for a participant. Fire-and-forget — never awaited by UI.
  /// On success: records printed_at in SQLite, enqueues mark_printed task.
  /// On failure: returns false, does NOT block registration flow.
  static Future<bool> printReceipt(Participant participant, String deviceId) async {
    try {
      debugPrint('[PrinterService] Starting print for ${participant.fullName}');

      final db = await DatabaseHelper.database;

      // Get event name from settings
      final eventResult = await db.query(
        'app_settings',
        where: 'key = ?',
        whereArgs: ['event_name'],
      );
      final eventName = eventResult.isNotEmpty
          ? eventResult.first['value'] as String
          : 'FSY Event';

      // Get saved printer address
      final printerResult = await db.query(
        'app_settings',
        where: 'key = ?',
        whereArgs: ['printer_address'],
      );
      if (printerResult.isEmpty) {
        debugPrint('[PrinterService] No printer address saved');
        return false;
      }
      final printerAddress = printerResult.first['value'] as String;

      // Find the printer
      await _printerPlugin.getPrinters(connectionTypes: [ConnectionType.BLE]);
      final printers = await _printerPlugin.devicesStream.first.timeout(
        const Duration(seconds: 5),
        onTimeout: () => [],
      );

      final targetPrinter = printers.firstWhere(
        (p) => p.address == printerAddress,
        orElse: () => throw Exception('Printer not found or out of range'),
      );

      // Connect and print
      final connected = await _printerPlugin.connect(targetPrinter);
      if (!connected) {
        debugPrint('[PrinterService] Failed to connect to printer');
        return false;
      }

      // Build receipt text and print
      final receiptText = ReceiptBuilder.build(participant, eventName, deviceId);
      final bytes = utf8.encode(receiptText);
      await _printerPlugin.printData(targetPrinter, bytes);
      await _printerPlugin.disconnect(targetPrinter);

      // On success: record printed_at and enqueue mark_printed task (fire-and-forget)
      final now = DateTime.now().millisecondsSinceEpoch;
      unawaited(_onPrintSuccess(participant, now));

      debugPrint('[PrinterService] Print successful');
      return true;
    } catch (e) {
      debugPrint('[PrinterService] Print failed: $e');
      return false;
    }
  }

  /// Handle post-print success operations asynchronously
  static Future<void> _onPrintSuccess(Participant participant, int printedAt) async {
    try {
      final db = await DatabaseHelper.database;
      final dao = ParticipantsDao(db);
      await dao.markPrintedLocally(participant.id, printedAt);

      // Enqueue mark_printed task with CORRECT payload format
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