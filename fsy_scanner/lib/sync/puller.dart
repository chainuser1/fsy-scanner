import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../db/participants_dao.dart';
import '../db/sync_queue_dao.dart';
import '../models/participant.dart';
import '../utils/logger.dart';
import 'sheets_api.dart';

class Puller {
  /// Pull all rows from Sheets and upsert into local SQLite
  static Future<void> pull(
    Database db,
    String token,
    String sheetId,
    String tabName,
  ) async {
    LoggerUtil.debug('[Puller] Starting pull operation');

    try {
      final colMapResult = await db.query(
        'app_settings',
        where: 'key = ?',
        whereArgs: ['col_map'],
      );

      if (colMapResult.isEmpty) {
        LoggerUtil.error('[Puller] No column map found in settings');
        throw Exception(
          'Column map not configured. Run column detection first.',
        );
      }

      final colMapJson = colMapResult.first['value'] as String;
      final colMap = Map<String, int>.from(jsonDecode(colMapJson));
      LoggerUtil.debug(
        '[Puller] Loaded column map with ${colMap.length} columns',
      );

      final rows = await SheetsApi.fetchAllRows(token, sheetId, tabName);
      if (rows == null || rows.isEmpty) {
        LoggerUtil.warn('[Puller] No rows returned from Sheets');
        return;
      }

      final dataRows = rows.length > 1 ? rows.sublist(1) : <List<dynamic>>[];
      LoggerUtil.info('[Puller] Processing ${dataRows.length} participants');
      final pendingParticipantIds =
          await SyncQueueDao.getPendingParticipantIds();
      final pullStartedAt = DateTime.now().millisecondsSinceEpoch;

      int upsertedCount = 0;
      int skippedCount = 0;

      for (int i = 0; i < dataRows.length; i++) {
        final row = dataRows[i];
        final sheetsRow = i + 2; // 1‑based, header is row 1

        final participant = _parseRow(row, colMap, sheetsRow);
        if (participant != null) {
          await ParticipantsDao.upsertFromPull(
            participant,
            pendingParticipantIds: pendingParticipantIds,
            pullStartedAt: pullStartedAt,
          );
          upsertedCount++;
        } else {
          skippedCount++;
        }
      }

      await db.insert(
          'app_settings',
          {
            'key': 'last_pulled_at',
            'value': DateTime.now().millisecondsSinceEpoch.toString(),
          },
          conflictAlgorithm: ConflictAlgorithm.replace);

      LoggerUtil.info(
        '[Puller] Complete: $upsertedCount upserted, $skippedCount skipped',
      );
    } catch (e) {
      LoggerUtil.error('[Puller] Error during pull: $e', error: e);
      rethrow;
    }
  }

  /// Parse a single row from Sheets using column map
  static Participant? _parseRow(
    List<dynamic> row,
    Map<String, int> colMap,
    int sheetsRow,
  ) {
    try {
      final idIndex = colMap[SheetColumns.id];
      final nameIndex = colMap[SheetColumns.name];

      if (idIndex == null || nameIndex == null) {
        LoggerUtil.warn(
          '[Puller] Missing required columns (ID or Name) in map',
        );
        return null;
      }

      final id = _safeString(row, idIndex);
      final fullName = _safeString(row, nameIndex);

      if (id == null || id.isEmpty) {
        LoggerUtil.warn('[Puller] Row $sheetsRow has empty ID, skipping');
        return null;
      }

      if (fullName == null || fullName.isEmpty) {
        LoggerUtil.warn('[Puller] Row $sheetsRow has empty Name, skipping');
        return null;
      }

      final verifiedAt = _parseTimestamp(
        _safeString(row, colMap[SheetColumns.verifiedAt]),
      );
      final printedAt = _parseTimestamp(
        _safeString(row, colMap[SheetColumns.printedAt]),
      );
      final ageStr = _safeString(row, colMap[SheetColumns.age]);
      final age = ageStr != null ? int.tryParse(ageStr) : null;
      final birthday = _safeString(row, colMap[SheetColumns.birthday]);

      return Participant(
        id: id,
        fullName: fullName,
        stake: _safeString(row, colMap[SheetColumns.stake]),
        ward: _safeString(row, colMap[SheetColumns.ward]),
        gender: _safeString(row, colMap[SheetColumns.gender]),
        roomNumber: _safeString(row, colMap[SheetColumns.roomNumber]),
        tableNumber: _safeString(row, colMap[SheetColumns.tableNumber]),
        tshirtSize: _safeString(row, colMap[SheetColumns.tshirtSize]),
        medicalInfo: _safeString(row, colMap[SheetColumns.medicalInfo]),
        note: _safeString(row, colMap[SheetColumns.note]),
        status: _safeString(row, colMap[SheetColumns.status]),
        age: age,
        birthday: birthday,
        verifiedAt: verifiedAt,
        printedAt: printedAt,
        registeredBy: _safeString(row, colMap[SheetColumns.deviceId]),
        sheetsRow: sheetsRow,
        rawJson: jsonEncode(row.map((e) => e?.toString() ?? '').toList()),
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      );
    } catch (e) {
      LoggerUtil.error('[Puller] Error parsing row $sheetsRow: $e', error: e);
      return null;
    }
  }

  static String? _safeString(List<dynamic> row, int? index) {
    if (index == null || index < 0 || index >= row.length) return null;
    final value = row[index];
    if (value == null) return null;
    final str = value.toString().trim();
    return str.isEmpty ? null : str;
  }

  static int? _parseTimestamp(String? timestampStr) {
    if (timestampStr == null || timestampStr.isEmpty) return null;
    try {
      final dt = DateTime.parse(timestampStr);
      return dt.millisecondsSinceEpoch;
    } catch (e) {
      LoggerUtil.warn(
        '[Puller] Failed to parse timestamp: "$timestampStr" - $e',
      );
      return null;
    }
  }
}
