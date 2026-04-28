import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

import '../db/participants_dao.dart';
import '../models/participant.dart';
import '../utils/logger.dart';
import 'sheets_api.dart';

class Puller {
  static Future<void> pull(
    Database db,
    String token,
    String sheetId,
    String tabName,
  ) async {
    LoggerUtil.debug('[Puller] Starting pull operation for $sheetId/$tabName');
    
    try {
      final rows = await SheetsApi.fetchAllRows(token, sheetId, tabName);
      if (rows == null) {
        LoggerUtil.warn('[Puller] No rows returned from Sheets API');
        return;
      }

      // Skip header row
      final dataRows = rows.skip(1).toList();
      LoggerUtil.info('[Puller] Processing ${dataRows.length} data rows from sheet');

      // Batch process participants
      for (final row in dataRows) {
        final participant = _parseRow(row);
        if (participant != null) {
          await ParticipantsDao.upsert(participant);
        } else {
          LoggerUtil.warn('[Puller] Failed to parse row: $row');
        }
      }
      
      // Update last pulled timestamp
      await db.insert(
        'app_settings',
        {'key': 'last_pulled_at', 'value': DateTime.now().millisecondsSinceEpoch.toString()},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      
      LoggerUtil.info('[Puller] Successfully completed pull operation, ${dataRows.length} rows processed');
    } catch (e) {
      LoggerUtil.error('[Puller] Error during pull operation: $e', error: e);
      rethrow;
    }
  }

  static Participant? _parseRow(List<dynamic> row) {
    try {
      // Per plan Section 7.7, we expect: [ID, Registered, Verified At, Printed At, ...]
      if (row.length < 4) {
        LoggerUtil.warn('[Puller] Row has insufficient columns: $row');
        return null;
      }

      // Safely access columns by index
      final id = _safeRowAccess(row, 0);
      final registered = _safeRowAccess(row, 1);
      final verifiedAt = _safeRowAccess(row, 2);
      final printedAt = _safeRowAccess(row, 3);

      if (id == null) {
        LoggerUtil.warn('[Puller] Row has null ID: $row');
        return null;
      }

      return Participant(
        id: id,
        fullName: id, // Use the ID as the full name since we don't have the name in the parsed row
        registered: registered == 'Y' ? 1 : 0,
        verifiedAt: verifiedAt != null ? _parseTimestamp(verifiedAt) : null,
        printedAt: printedAt != null ? _parseTimestamp(printedAt) : null,
        sheetsRow: 0, // Will be set when upserting if new
      );
    } catch (e) {
      LoggerUtil.error('[Puller] Error parsing row: $e', error: e);
      return null;
    }
  }

  static String? _safeRowAccess(List<dynamic> row, int index) {
    if (index < 0 || index >= row.length) {
      return null;
    }
    final value = row[index];
    if (value == null) {
      return null;
    }
    return value.toString().trim();
  }

  static int? _parseTimestamp(String timestampStr) {
    try {
      // Per plan Section 7.7, timestamps are ISO 8601 format
      final dt = DateTime.parse(timestampStr);
      return dt.millisecondsSinceEpoch;
    } catch (e) {
      LoggerUtil.warn('[Puller] Failed to parse timestamp: $timestampStr - Error: $e');
      return null;
    }
  }
}