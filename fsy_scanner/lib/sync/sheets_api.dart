import 'dart:convert';
import 'dart:io';
import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

import '../models/participant.dart';
import '../utils/logger.dart';

class SheetsApi {
  static const String baseUrl = 'https://sheets.googleapis.com/v4/spreadsheets';

  // Custom exception for rate limiting
  static Future<void> updateRegistrationRow(
    String accessToken,
    String sheetId,
    String tabName,
    int row,
    Map<String, String> values,
  ) async {
    final url = Uri.parse('$baseUrl/$sheetId/values/$tabName!A$row:C$row');
    
    try {
      LoggerUtil.debug('Starting update registration row request for row $row');
      
      final response = await http.put(
        url,
        headers: {
          HttpHeaders.authorizationHeader: 'Bearer $accessToken',
          HttpHeaders.contentTypeHeader: 'application/json',
        },
        body: jsonEncode({
          'values': [values.values.toList()], // Ensure order: Registered, Verified At, Printed At
        }),
      ).timeout(const Duration(seconds: 30)); // Adding 30-second timeout

      LoggerUtil.networkRequest('PUT', url.toString(), statusCode: response.statusCode);

      if (response.statusCode == 429) {
        LoggerUtil.warn('Rate limit exceeded when updating registration row');
        throw SheetsRateLimitException();
      } else if (response.statusCode != 200) {
        LoggerUtil.error('Failed to update registration row: ${response.statusCode}', error: response.body);
        throw Exception('Failed to update registration row: ${response.statusCode}');
      }
      
      LoggerUtil.debug('Successfully updated registration row $row');
    } on TimeoutException {
      LoggerUtil.error('Timeout when updating registration row for row $row');
      throw Exception('Request timeout when updating registration row');
    } catch (e) {
      LoggerUtil.error('Error updating registration row: $e', error: e);
      rethrow;
    }
  }

  static Future<List<List<dynamic>>?> fetchAllRows(
    String accessToken,
    String sheetId,
    String tabName,
  ) async {
    final url = Uri.parse('$baseUrl/$sheetId/values/$tabName');
    
    try {
      LoggerUtil.debug('Starting fetch all rows request for tab $tabName');
      
      final response = await http.get(
        url,
        headers: {
          HttpHeaders.authorizationHeader: 'Bearer $accessToken',
        },
      ).timeout(const Duration(seconds: 30)); // Adding 30-second timeout

      LoggerUtil.networkRequest('GET', url.toString(), statusCode: response.statusCode);

      if (response.statusCode == 429) {
        LoggerUtil.warn('Rate limit exceeded when fetching all rows');
        throw SheetsRateLimitException();
      } else if (response.statusCode != 200) {
        LoggerUtil.error('Failed to fetch all rows: ${response.statusCode}', error: response.body);
        return null;
      }

      final data = jsonDecode(response.body);
      final values = data['values'] as List<dynamic>?;
      
      if (values == null) {
        LoggerUtil.warn('No values returned when fetching all rows');
        return null;
      }

      // Convert to List<List<dynamic>>
      final result = <List<dynamic>>[];
      for (final row in values.cast<List<dynamic>>()) {
        result.add(row);
      }
      
      LoggerUtil.debug('Successfully fetched ${result.length} rows from tab $tabName');
      return result;
    } on TimeoutException {
      LoggerUtil.error('Timeout when fetching all rows for sheet $sheetId tab $tabName');
      throw Exception('Request timeout when fetching all rows');
    } catch (e) {
      LoggerUtil.error('Error fetching all rows: $e', error: e);
      rethrow;
    }
  }

  static Future<void> detectColMap(
    dynamic db, // Database type varies by platform
    String accessToken,
    String sheetId,
    String tabName,
  ) async {
    final url = Uri.parse('$baseUrl/$sheetId/values/$tabName!1:1'); // Get first row (headers)
    
    try {
      LoggerUtil.debug('Starting column map detection for tab $tabName');
      
      final response = await http.get(
        url,
        headers: {
          HttpHeaders.authorizationHeader: 'Bearer $accessToken',
        },
      ).timeout(const Duration(seconds: 30)); // Adding 30-second timeout

      LoggerUtil.networkRequest('GET', url.toString(), statusCode: response.statusCode);

      if (response.statusCode == 429) {
        LoggerUtil.warn('Rate limit exceeded when detecting column map');
        throw SheetsRateLimitException();
      } else if (response.statusCode != 200) {
        LoggerUtil.error('Failed to fetch headers for column detection: ${response.statusCode}', error: response.body);
        throw SheetsColMapException('Failed to fetch headers: ${response.statusCode}');
      }

      final data = jsonDecode(response.body);
      final headerRow = data['values']?.first as List<dynamic>?;

      if (headerRow == null) {
        LoggerUtil.error('No header row returned for column detection');
        throw SheetsColMapException('No header row found');
      }

      // Create mapping from header names to column indices
      final colMap = <String, int>{};
      for (int i = 0; i < headerRow.length; i++) {
        final header = headerRow[i].toString().trim();
        if (header.toLowerCase() == 'id') {
          colMap['ID'] = i;
        } else if (header.toLowerCase() == 'registered') {
          colMap['Registered'] = i;
        } else if (header.toLowerCase() == 'verified at') {
          colMap['Verified At'] = i;
        } else if (header.toLowerCase() == 'printed at') {
          colMap['Printed At'] = i;
        }
      }

      // Verify required columns exist
      if (!colMap.containsKey('ID')) {
        LoggerUtil.error('Required column "ID" not found in sheet');
        throw SheetsColMapException('Required column "ID" not found in sheet');
      }

      // Save to app_settings
      await db.insert(
        'app_settings',
        {'key': 'col_map', 'value': jsonEncode(colMap)},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      
      LoggerUtil.info('Successfully detected and saved column map: $colMap');
    } on TimeoutException {
      LoggerUtil.error('Timeout when detecting column map for sheet $sheetId tab $tabName');
      throw Exception('Request timeout when detecting column map');
    } catch (e) {
      LoggerUtil.error('Error detecting column map: $e', error: e);
      if (e is SheetsException) {
        rethrow;
      }
      throw SheetsColMapException(e.toString());
    }
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