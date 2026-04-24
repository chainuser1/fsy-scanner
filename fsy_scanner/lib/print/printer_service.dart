import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_thermal_printer/flutter_thermal_printer.dart';
import 'package:flutter_thermal_printer/utils/printer.dart';

import '../db/participants_dao.dart';
import '../db/sync_queue_dao.dart';
import '../models/participant.dart';
import 'receipt_builder.dart';
import '../db/database_helper.dart';

class PrinterService {
  static final _printerPlugin = FlutterThermalPrinter.instance;

  // Scan for nearby Bluetooth printers.
  static Future<List<Printer>> scanPrinters() async {
    try {
      await _printerPlugin.getPrinters(connectionTypes: [ConnectionType.BLE]);
      // We return the stream's current value or wait for a bit
      // In a real app, this would be a stream, but following the plan's static method signature
      return await _printerPlugin.devicesStream.first.timeout(const Duration(seconds: 5), onTimeout: () => []);
    } catch (e) {
      debugPrint('[PrinterService] Scan error: $e');
      return [];
    }
  }

  // Print receipt for a participant. Fire-and-forget.
  static Future<bool> printReceipt(Participant participant, String deviceId) async {
    try {
      debugPrint('[PrinterService] Starting print for ${participant.fullName}');
      
      final db = await DatabaseHelper.database;
      
      // Get event name from settings
      final eventResult = await db.query('app_settings', where: 'key = ?', whereArgs: ['event_name']);
      final eventName = eventResult.isNotEmpty ? eventResult.first['value'] as String : 'FSY Event';
      
      // Get saved printer address
      final printerResult = await db.query('app_settings', where: 'key = ?', whereArgs: ['printer_address']);
      if (printerResult.isEmpty) {
        debugPrint('[PrinterService] No printer address saved');
        return false;
      }
      final printerAddress = printerResult.first['value'] as String;

      // Find the printer in currently discovered devices
      // This is a bit simplified; in reality, we might need to reconnect if not in range
      await _printerPlugin.getPrinters(connectionTypes: [ConnectionType.BLE]);
      final printers = await _printerPlugin.devicesStream.first;
      final targetPrinter = printers.firstWhere(
        (p) => p.address == printerAddress,
        orElse: () => throw Exception('Printer not found or out of range'),
      );

      // Connect
      final connected = await _printerPlugin.connect(targetPrinter);
      if (!connected) {
        debugPrint('[PrinterService] Failed to connect to printer');
        return false;
      }

      // Build receipt text
      final receiptText = ReceiptBuilder.build(participant, eventName, deviceId);
      
      // Convert to bytes
      final bytes = utf8.encode(receiptText);
      
      // Print
      await _printerPlugin.printData(targetPrinter, bytes);
      
      // Disconnect
      await _printerPlugin.disconnect(targetPrinter);

      // On success: record printed_at in SQLite
      final now = DateTime.now().millisecondsSinceEpoch;
      final dao = ParticipantsDao(db);
      await dao.markPrintedLocally(participant.id, now);

      // Enqueue mark_printed task
      await SyncQueueDao.enqueueTask(
        'UPDATE',
        participant.toJson()..['printed_at'] = now,
      );

      debugPrint('[PrinterService] Print successful');
      return true;
    } catch (e) {
      debugPrint('[PrinterService] Print failed: $e');
      return false;
    }
  }
  
  // Method to mark as printed manually (used by pusher or other flows)
  static Future<void> markPrinted(Participant participant) async {
    debugPrint('[PrinterService] Marking printed: ${participant.fullName}');
    await ParticipantsDao.upsert(participant);
    
    await SyncQueueDao.enqueueTask(
      'UPDATE', 
      participant.toJson()
    );
  }
}
