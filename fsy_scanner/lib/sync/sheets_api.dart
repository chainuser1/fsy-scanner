import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:sqflite/sqflite.dart';

import '../utils/logger.dart';

/// Column name constants for Google Sheets headers
class SheetColumns {
  static const String id = 'ID';
  static const String qrCode = 'QR Code';
  static const String stake = 'Stake';
  static const String ward = 'Ward';
  static const String name = 'Name';
  static const String gender = 'Gender';
  static const String registered = 'Registered';
  static const String signedBy = 'Signed by';
  static const String status = 'Status';
  static const String medicalInfo = 'Medical/Food Info';
  static const String note = 'Note';
  static const String tshirtSize = 'T-Shirt Size';
  static const String age = 'Age';
  static const String birthday = 'Birthday';
  static const String tableNumber = 'Group Number';
  static const String roomNumber = 'Hotel Room Number';
  static const String verifiedAt = 'Verified At';
  static const String printedAt = 'Printed At';
  static const String deviceId = 'Device ID';
}

class SheetsApi {
  static const String baseUrl = 'https://sheets.googleapis.com/v4/spreadsheets';

  /// Update only the given columns on a specific row.
  /// Each column is updated individually to avoid overwriting other cells.
  static Future<void> updateCells({
    required String accessToken,
    required String sheetId,
    required String tabName,
    required int row,
    required Map<String, int> colMap,
    required Map<String, String> values,
  }) async {
    for (final entry in values.entries) {
      final colIndex = colMap[entry.key];
      if (colIndex == null) {
        LoggerUtil.warn('[SheetsApi] Column "${entry.key}" not in col_map');
        continue;
      }
      final colLetter = _columnIndexToLetter(colIndex);
      final cell = '$colLetter$row';
      final range = '$tabName!$cell:$cell';
      final url = Uri.parse(
        '$baseUrl/$sheetId/values/$range?valueInputOption=RAW',
      );

      try {
        final response = await http
            .put(
              url,
              headers: {
                HttpHeaders.authorizationHeader: 'Bearer $accessToken',
                HttpHeaders.contentTypeHeader: 'application/json',
              },
              body: jsonEncode({
                'values': [
                  [entry.value],
                ],
              }),
            )
            .timeout(const Duration(seconds: 30));

        LoggerUtil.networkRequest(
          'PUT',
          url.toString(),
          statusCode: response.statusCode,
        );

        if (response.statusCode == 429) {
          throw SheetsRateLimitException();
        } else if (response.statusCode != 200) {
          LoggerUtil.error(
            '[SheetsApi] Cell update failed: ${response.statusCode}',
            error: response.body,
          );
          throw SheetsException(
            'Failed to update cell $cell: ${response.statusCode}',
          );
        }
      } on TimeoutException {
        throw SheetsException('Timeout updating cell $cell');
      }
    }
  }

  /// Search for a value in the ID column and return the 1‑based row index.
  /// Returns null if not found or on error.
  static Future<int?> findRowByValue({
    required String accessToken,
    required String sheetId,
    required String tabName,
    required Map<String, int> colMap,
    required String searchValue,
  }) async {
    final idColIndex = colMap[SheetColumns.id];
    if (idColIndex == null) {
      LoggerUtil.warn('[SheetsApi] ID column not in col_map');
      return null;
    }
    final colLetter = _columnIndexToLetter(idColIndex);
    final range = '$tabName!$colLetter:$colLetter';
    final url = Uri.parse('$baseUrl/$sheetId/values/$range');

    try {
      final response = await http.get(
        url,
        headers: {HttpHeaders.authorizationHeader: 'Bearer $accessToken'},
      ).timeout(const Duration(seconds: 15));

      if (response.statusCode == 429) {
        throw SheetsRateLimitException();
      } else if (response.statusCode != 200) {
        LoggerUtil.error(
          '[SheetsApi] findRowByValue failed: ${response.statusCode}',
        );
        return null;
      }

      final data = jsonDecode(response.body);
      final values = data['values'] as List<dynamic>?;
      if (values == null) return null;

      for (int i = 0; i < values.length; i++) {
        final rowData = values[i] as List<dynamic>?;
        if (rowData != null &&
            rowData.isNotEmpty &&
            rowData[0].toString().trim() == searchValue) {
          return i + 1; // 1‑based row index
        }
      }
      LoggerUtil.warn('[SheetsApi] ID $searchValue not found in sheet');
      return null;
    } on SheetsException {
      rethrow;
    } catch (e) {
      LoggerUtil.error('[SheetsApi] findRowByValue error: $e');
      return null;
    }
  }

  /// Fetch all populated rows from the sheet without a fixed row cap.
  static Future<List<List<dynamic>>?> fetchAllRows(
    String accessToken,
    String sheetId,
    String tabName,
  ) async {
    final range = tabName;
    final url = Uri.parse('$baseUrl/$sheetId/values/$range');

    try {
      LoggerUtil.debug('[SheetsApi] Fetching rows: $range');

      final response = await http.get(
        url,
        headers: {HttpHeaders.authorizationHeader: 'Bearer $accessToken'},
      ).timeout(const Duration(seconds: 30));

      LoggerUtil.networkRequest(
        'GET',
        url.toString(),
        statusCode: response.statusCode,
      );

      if (response.statusCode == 429) {
        LoggerUtil.warn('[SheetsApi] Rate limit exceeded');
        throw SheetsRateLimitException();
      } else if (response.statusCode != 200) {
        LoggerUtil.error(
          '[SheetsApi] Fetch failed: ${response.statusCode}',
          error: response.body,
        );
        return null;
      }

      final data = jsonDecode(response.body);
      final values = data['values'] as List<dynamic>?;

      if (values == null) {
        LoggerUtil.warn('[SheetsApi] No values returned');
        return null;
      }

      final result = values.cast<List<dynamic>>().toList();
      LoggerUtil.info('[SheetsApi] Fetched ${result.length} rows');
      return result;
    } on TimeoutException {
      LoggerUtil.error('[SheetsApi] Timeout fetching rows');
      throw SheetsException('Request timeout');
    } catch (e) {
      if (e is SheetsException) rethrow;
      LoggerUtil.error('[SheetsApi] Error fetching rows: $e', error: e);
      rethrow;
    }
  }

  /// Detect column map from header row (row 1)
  static Future<Map<String, int>> detectColMap(
    Database db,
    String accessToken,
    String sheetId,
    String tabName,
  ) async {
    final range = '$tabName!1:1';
    final url = Uri.parse('$baseUrl/$sheetId/values/$range');

    try {
      LoggerUtil.debug('[SheetsApi] Detecting column map...');

      final response = await http.get(
        url,
        headers: {HttpHeaders.authorizationHeader: 'Bearer $accessToken'},
      ).timeout(const Duration(seconds: 30));

      LoggerUtil.networkRequest(
        'GET',
        url.toString(),
        statusCode: response.statusCode,
      );

      if (response.statusCode == 429) {
        LoggerUtil.warn('[SheetsApi] Rate limit exceeded');
        throw SheetsRateLimitException();
      } else if (response.statusCode != 200) {
        LoggerUtil.error(
          '[SheetsApi] Header fetch failed: ${response.statusCode}',
        );
        throw SheetsColMapException(
          'Failed to fetch headers: ${response.statusCode}',
        );
      }

      final data = jsonDecode(response.body);
      final values = data['values'] as List<dynamic>?;

      if (values == null || values.isEmpty) {
        throw SheetsColMapException('No header row found in sheet');
      }

      final headerRow = values.first as List<dynamic>;

      final colMap = <String, int>{};
      for (int i = 0; i < headerRow.length; i++) {
        final header = headerRow[i].toString().trim();
        if (header.isNotEmpty) {
          colMap[header] = i;
        }
      }

      // Required headers for reliable lookup and writeback.
      const requiredHeaders = <String>[
        SheetColumns.id,
        SheetColumns.verifiedAt,
        SheetColumns.printedAt,
        SheetColumns.deviceId,
      ];
      final missingHeaders = <String>[];
      for (final required in requiredHeaders) {
        if (!colMap.containsKey(required)) {
          missingHeaders.add(required);
        }
      }

      if (missingHeaders.isNotEmpty) {
        throw SheetsColMapException(
          'Missing required columns: ${missingHeaders.join(', ')}. '
          'Sheet headers: ${colMap.keys.join(', ')}',
        );
      }

      await db.insert(
          'app_settings',
          {
            'key': 'col_map',
            'value': jsonEncode(colMap),
          },
          conflictAlgorithm: ConflictAlgorithm.replace);

      LoggerUtil.info('[SheetsApi] Column map detected: $colMap');
      return colMap;
    } on SheetsException {
      rethrow;
    } catch (e) {
      LoggerUtil.error('[SheetsApi] Error detecting columns: $e', error: e);
      throw SheetsColMapException(e.toString());
    }
  }

  static String _columnIndexToLetter(int index) {
    final letters = <String>[];
    int n = index;
    while (n >= 0) {
      letters.insert(0, String.fromCharCode(65 + (n % 26)));
      n = n ~/ 26 - 1;
    }
    return letters.join();
  }
}

class SheetsException implements Exception {
  final String message;
  SheetsException(this.message);
  @override
  String toString() => 'SheetsException: $message';
}

class SheetsRateLimitException extends SheetsException {
  SheetsRateLimitException() : super('Rate limit exceeded');
}

class SheetsColMapException extends SheetsException {
  SheetsColMapException(super.message);
}
