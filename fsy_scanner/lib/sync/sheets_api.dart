import 'dart:convert';
import 'dart:io';
import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

import '../utils/logger.dart';

/// Column name constants matching the plan's sheet contract (Section 4.1)
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
  static const String tableNumber = 'Table Number';
  static const String roomNumber = 'Hotel Room Number';
  static const String verifiedAt = 'Verified At';
  static const String printedAt = 'Printed At';
  
  /// All columns in sheet order
  static const List<String> allColumns = [
    id, qrCode, stake, ward, name, gender, registered, signedBy,
    status, medicalInfo, note, tshirtSize, tableNumber, roomNumber,
    verifiedAt, printedAt,
  ];
}

class SheetsApi {
  static const String baseUrl = 'https://sheets.googleapis.com/v4/spreadsheets';

  /// Update registration row using colMap to write to correct columns
  static Future<void> updateRegistrationRow(
    String accessToken,
    String sheetId,
    String tabName,
    int sheetsRow,
    Map<String, int> colMap,
    Map<String, String> values,
  ) async {
    // Build a row array with empty strings for all columns,
    // then fill in values at their correct column positions
    final maxCol = colMap.values.reduce((a, b) => a > b ? a : b);
    final rowValues = List<String>.filled(maxCol + 1, '');
    
    for (final entry in values.entries) {
      final colIndex = colMap[entry.key];
      if (colIndex != null) {
        rowValues[colIndex] = entry.value;
      }
    }
    
    // Convert column indices to A1 notation range
    final minColIndex = colMap.values.reduce((a, b) => a < b ? a : b);
    final colLetter = _columnIndexToLetter(minColIndex);
    final endColLetter = _columnIndexToLetter(maxCol);
    final range = '$tabName!$colLetter$sheetsRow:$endColLetter$sheetsRow';
    
    final url = Uri.parse('$baseUrl/$sheetId/values/$range?valueInputOption=RAW');
    
    try {
      LoggerUtil.debug('[SheetsApi] Updating row $sheetsRow, range: $range');
      
      final response = await http.put(
        url,
        headers: {
          HttpHeaders.authorizationHeader: 'Bearer $accessToken',
          HttpHeaders.contentTypeHeader: 'application/json',
        },
        body: jsonEncode({
          'values': [rowValues],
        }),
      ).timeout(const Duration(seconds: 30));

      LoggerUtil.networkRequest('PUT', url.toString(), statusCode: response.statusCode);

      if (response.statusCode == 429) {
        LoggerUtil.warn('[SheetsApi] Rate limit exceeded');
        throw SheetsRateLimitException();
      } else if (response.statusCode != 200) {
        LoggerUtil.error('[SheetsApi] Update failed: ${response.statusCode}', error: response.body);
        throw SheetsException('Failed to update row: ${response.statusCode}');
      }
      
      LoggerUtil.debug('[SheetsApi] Successfully updated row $sheetsRow');
    } on TimeoutException {
      LoggerUtil.error('[SheetsApi] Timeout updating row $sheetsRow');
      throw SheetsException('Request timeout');
    } catch (e) {
      if (e is SheetsException) rethrow;
      LoggerUtil.error('[SheetsApi] Error updating row: $e', error: e);
      rethrow;
    }
  }

  /// Fetch all rows from sheet (up to 1000 rows, 16 columns)
  static Future<List<List<dynamic>>?> fetchAllRows(
    String accessToken,
    String sheetId,
    String tabName,
  ) async {
    final range = '$tabName!A1:P1000';
    final url = Uri.parse('$baseUrl/$sheetId/values/$range');
    
    try {
      LoggerUtil.debug('[SheetsApi] Fetching rows: $range');
      
      final response = await http.get(
        url,
        headers: {
          HttpHeaders.authorizationHeader: 'Bearer $accessToken',
        },
      ).timeout(const Duration(seconds: 30));

      LoggerUtil.networkRequest('GET', url.toString(), statusCode: response.statusCode);

      if (response.statusCode == 429) {
        LoggerUtil.warn('[SheetsApi] Rate limit exceeded');
        throw SheetsRateLimitException();
      } else if (response.statusCode != 200) {
        LoggerUtil.error('[SheetsApi] Fetch failed: ${response.statusCode}', error: response.body);
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
  /// Returns map of header name → 0-based column index
  /// Throws SheetsColMapException if required columns are missing
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
        headers: {
          HttpHeaders.authorizationHeader: 'Bearer $accessToken',
        },
      ).timeout(const Duration(seconds: 30));

      LoggerUtil.networkRequest('GET', url.toString(), statusCode: response.statusCode);

      if (response.statusCode == 429) {
        LoggerUtil.warn('[SheetsApi] Rate limit exceeded');
        throw SheetsRateLimitException();
      } else if (response.statusCode != 200) {
        LoggerUtil.error('[SheetsApi] Header fetch failed: ${response.statusCode}');
        throw SheetsColMapException('Failed to fetch headers: ${response.statusCode}');
      }

      final data = jsonDecode(response.body);
      final values = data['values'] as List<dynamic>?;
      
      if (values == null || values.isEmpty) {
        throw SheetsColMapException('No header row found in sheet');
      }

      final headerRow = values.first as List<dynamic>;
      
      // Build column map: header name → 0-based index
      final colMap = <String, int>{};
      for (int i = 0; i < headerRow.length; i++) {
        final header = headerRow[i].toString().trim();
        if (header.isNotEmpty) {
          colMap[header] = i;
        }
      }
      
      // Verify required write headers exist
      const requiredHeaders = ['Registered', 'Verified At', 'Printed At'];
      final missingHeaders = <String>[];
      for (final required in requiredHeaders) {
        if (!colMap.containsKey(required)) {
          missingHeaders.add(required);
        }
      }
      
      if (missingHeaders.isNotEmpty) {
        throw SheetsColMapException(
          'Missing required columns: ${missingHeaders.join(', ')}. '
          'Sheet headers: ${colMap.keys.join(', ')}'
        );
      }

      // Save to app_settings
      await db.insert(
        'app_settings',
        {'key': 'col_map', 'value': jsonEncode(colMap)},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      
      LoggerUtil.info('[SheetsApi] Column map detected: $colMap');
      return colMap;
    } on SheetsException {
      rethrow;
    } catch (e) {
      LoggerUtil.error('[SheetsApi] Error detecting columns: $e', error: e);
      throw SheetsColMapException(e.toString());
    }
  }
  
  /// Convert 0-based column index to A1 notation (0→A, 1→B, ..., 26→AA, etc.)
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
  SheetsColMapException(String message) : super(message);
}