import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';
import '../auth/google_auth.dart';
import '../db/database_helper.dart';
import '../db/sync_queue_dao.dart';
import '../models/sync_task.dart';
import 'sheets_api.dart';

class Pusher {
  static Future<bool> pushPendingUpdates() async {
    debugPrint('[Pusher] Starting pending updates...');
    
    try {
      final token = await GoogleAuth.getValidToken();
      if (token == null) return false;

      final db = await DatabaseHelper.database;
      
      // Get sheet config
      final sheetIdResult = await db.query('app_settings', where: 'key = ?', whereArgs: ['sheets_id']);
      final sheetTabResult = await db.query('app_settings', where: 'key = ?', whereArgs: ['sheets_tab']);
      final colMapResult = await db.query('app_settings', where: 'key = ?', whereArgs: ['col_map']);

      if (sheetIdResult.isEmpty || sheetTabResult.isEmpty || colMapResult.isEmpty) {
        debugPrint('[Pusher] Missing sheet configuration');
        return false;
      }

      final sheetId = sheetIdResult.first['value'] as String;
      final tabName = sheetTabResult.first['value'] as String;
      final colMap = Map<String, int>.from(jsonDecode(colMapResult.first['value'] as String));

      while (true) {
        final task = await SyncQueueDao.claimNextTask();
        if (task == null) break;

        final success = await _processTask(db, token, sheetId, tabName, colMap, task);
        
        if (success) {
          await SyncQueueDao.markCompleted(task.id!);
        } else {
          await SyncQueueDao.markFailed(task.id!, 'Failed to update Sheets');
          // If we failed, stop draining to avoid rate limits or repeated errors
          return false;
        }
      }
      
      return true;
    } catch (e) {
      debugPrint('[Pusher] Error pushing updates: $e');
      return false;
    }
  }
  
  static Future<bool> _processTask(Database db, String token, String sheetId, String tabName, Map<String, int> colMap, SyncTask task) async {
    try {
      final Map<String, dynamic> payload = jsonDecode(task.payload);
      final int sheetsRow = payload['sheetsRow'] ?? 0;
      if (sheetsRow == 0) return false;

      final Map<String, String> values = {};

      if (task.type == 'mark_registered') {
        values['Registered'] = 'Y';
        values['Verified At'] = DateTime.fromMillisecondsSinceEpoch(payload['verifiedAt']).toIso8601String();
        // Section 7.8 also mentions Registered By, but the sheet contract 4.1 doesn't have it as a column.
        // I'll stick to what's in the contract 4.1 table.
      } else if (task.type == 'mark_printed') {
        values['Printed At'] = DateTime.fromMillisecondsSinceEpoch(payload['printedAt']).toIso8601String();
      } else if (task.type == 'UPDATE') {
        // Generic update from my previous fix
        if (payload['registered'] == 1) values['Registered'] = 'Y';
        if (payload['verified_at'] != null) {
          values['Verified At'] = DateTime.fromMillisecondsSinceEpoch(payload['verified_at']).toIso8601String();
        }
        if (payload['printed_at'] != null) {
          values['Printed At'] = DateTime.fromMillisecondsSinceEpoch(payload['printed_at']).toIso8601String();
        }
      }

      if (values.isEmpty) return true;

      await SheetsApi.updateRegistrationRow(token, sheetId, tabName, sheetsRow, colMap, values);
      return true;
    } catch (e) {
      debugPrint('[Pusher] Error processing task ${task.id}: $e');
      return false;
    }
  }
}
