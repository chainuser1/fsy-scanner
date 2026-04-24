import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

import '../auth/google_auth.dart';
import '../db/participants_dao.dart';
import '../models/participant.dart';
import 'sheets_api.dart';

class Puller {
  static Future<void> pull(Database db, String token, String sheetId, String tabName) async {
    // Fetch all rows from Sheets
    final List<List<String>> allRows = await SheetsApi.fetchAllRows(token, sheetId, tabName);
    
    // Skip header row (index 0) and process data rows
    for (int i = 1; i < allRows.length; i++) {
      final List<String> row = allRows[i];
      
      // Assuming the column map has already been detected and saved
      // This would be available from app_settings as a JSON string
      final List<Map<String, Object?>> colMapResults = await db.query(
        'app_settings',
        where: 'key = ?',
        whereArgs: ['col_map'],
      );
      
      if (colMapResults.isEmpty) {
        throw Exception('Column map not found in settings');
      }
      
      final Map<String, int> colMap = Map<String, int>.from(
        jsonDecode(colMapResults.first['value'] as String)
      );

      // Extract values using the column map
      final String id = row[colMap['ID'] ?? -1] ?? '';
      if (id.isEmpty) continue; // Skip rows without an ID

      // Create participant object
      final Participant participant = Participant(
        id: id,
        fullName: row[colMap['Name'] ?? -1] ?? '',
        stake: row[colMap['Stake'] ?? -1],
        ward: row[colMap['Ward'] ?? -1],
        gender: row[colMap['Gender'] ?? -1],
        roomNumber: row[colMap['Hotel Room Number'] ?? -1],
        tableNumber: row[colMap['Table Number'] ?? -1],
        tshirtSize: row[colMap['T-Shirt Size'] ?? -1],
        medicalInfo: row[colMap['Medical/Food Info'] ?? -1],
        note: row[colMap['Note'] ?? -1],
        status: row[colMap['Status'] ?? -1],
        registered: row[colMap['Registered'] ?? -1] == 'Y' ? 1 : 0,
        verifiedAt: _parseTimestamp(row[colMap['Verified At'] ?? -1]),
        printedAt: _parseTimestamp(row[colMap['Printed At'] ?? -1]),
        sheetsRow: i + 1, // Sheets uses 1-based indexing
        rawJson: jsonEncode(row),
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      );

      // Upsert participant (this will respect the registered=1 guard)
      await ParticipantsDao.upsert(participant);
    }

    // Update last_pulled_at in app_settings
    await db.insert(
      'app_settings',
      {'key': 'last_pulled_at', 'value': DateTime.now().millisecondsSinceEpoch.toString()},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  static int? _parseTimestamp(String? timestampStr) {
    if (timestampStr == null || timestampStr.isEmpty) {
      return null;
    }
    
    try {
      // Convert ISO string to milliseconds
      final DateTime dateTime = DateTime.parse(timestampStr);
      return dateTime.millisecondsSinceEpoch;
    } catch (e) {
      // If parsing fails, return null
      return null;
    }
  }
}

