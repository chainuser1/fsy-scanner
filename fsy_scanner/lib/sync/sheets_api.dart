import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:sqflite/sqflite.dart';

// Custom exceptions for Sheets API errors
class SheetsAuthException implements Exception {
  final String message;
  SheetsAuthException(this.message);
}

class SheetsRateLimitException implements Exception {
  final String message;
  SheetsRateLimitException(this.message);
}

class SheetsServerException implements Exception {
  final String message;
  SheetsServerException(this.message);
}

class SheetsNetworkException implements Exception {
  final String message;
  SheetsNetworkException(this.message);
}

class SheetsColMapException implements Exception {
  final List<String> missingHeaders;
  SheetsColMapException(this.missingHeaders);
  
  @override
  String toString() {
    return 'SheetsColMapException: Missing required headers - ${missingHeaders.join(', ')}';
  }
}

class SheetsApi {
  // Fetch all rows. Returns raw 2D list (List<List<String>>).
  static Future<List<List<String>>> fetchAllRows(String token, String sheetId, String tabName) async {
    final url = Uri.parse('https://sheets.googleapis.com/v4/spreadsheets/$sheetId/values/$tabName!A1:Z1000');
    
    try {
      final response = await http.get(
        url,
        headers: {
          'Authorization': 'Bearer $token',
        },
      );

      if (response.statusCode == 401 || response.statusCode == 403) {
        throw SheetsAuthException('Authentication failed: ${response.statusCode}');
      } else if (response.statusCode == 429) {
        throw SheetsRateLimitException('Rate limit exceeded');
      } else if (response.statusCode >= 500) {
        throw SheetsServerException('Server error: ${response.statusCode}');
      } else if (response.statusCode != 200) {
        throw Exception('Unexpected response: ${response.statusCode}, ${response.body}');
      }

      final data = jsonDecode(response.body);
      final values = data['values'] as List<dynamic>?;
      
      if (values == null) {
        return [];
      }

      // Convert to List<List<String>>
      return values.map((row) {
        return row.cast<String?>().map((cell) => cell ?? '').toList();
      }).cast<List<String>>().toList();
    } catch (e) {
      if (e is SheetsAuthException || e is SheetsRateLimitException || e is SheetsServerException) {
        rethrow;
      }
      throw SheetsNetworkException('Network request failed: $e');
    }
  }

  // Detect column map from header row. Saves to app_settings.
  // Throws SheetsColMapException if required write headers missing.
  static Future<Map<String, int>> detectColMap(Database db, String token, String sheetId, String tabName) async {
    final allRows = await fetchAllRows(token, sheetId, tabName);
    
    if (allRows.isEmpty) {
      throw SheetsColMapException(['Header row not found']);
    }
    
    final headerRow = allRows[0];
    final colMap = <String, int>{};
    
    // Build the column map
    for (int i = 0; i < headerRow.length; i++) {
      colMap[headerRow[i]] = i;
    }
    
    // Check for required write headers
    final requiredHeaders = ['Registered', 'Verified At', 'Printed At'];
    final missingHeaders = <String>[];
    
    for (final header in requiredHeaders) {
      if (!colMap.containsKey(header)) {
        missingHeaders.add(header);
      }
    }
    
    if (missingHeaders.isNotEmpty) {
      throw SheetsColMapException(missingHeaders);
    }
    
    // Save the column map to app_settings
    await db.insert(
      'app_settings',
      {'key': 'col_map', 'value': jsonEncode(colMap)},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    
    return colMap;
  }

  // Write registration data to a specific row.
  static Future<void> updateRegistrationRow(
    String token, 
    String sheetId, 
    String tabName,
    int sheetsRow, 
    Map<String, int> colMap, 
    Map<String, String> values,
  ) async {
    // Build the range for the update (e.g., 'Sheet1!A2:C2')
    final rangeUpdates = <Map<String, String>>[];
    
    values.forEach((header, value) {
      final colIndex = colMap[header];
      if (colIndex != null) {
        // Convert column index to letter (A=0, B=1, etc.)
        final String colLetter = _columnToLetter(colIndex);
        final String range = '$tabName!$colLetter$sheetsRow';
        
        rangeUpdates.add({
          'range': range,
          'value': value,
        });
      } else {
        debugPrint('[SheetsApi] Warning: Column "$header" not found in column map');
      }
    });

    // Perform batch update
    for (final update in rangeUpdates) {
      final url = Uri.parse('https://sheets.googleapis.com/v4/spreadsheets/$sheetId/values/${update['range']}?valueInputOption=RAW');
      
      final requestBody = {
        'values': [
          [update['value']]
        ]
      };
      
      try {
        final response = await http.put(
          url,
          headers: {
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json',
          },
          body: jsonEncode(requestBody),
        );

        if (response.statusCode == 401 || response.statusCode == 403) {
          throw SheetsAuthException('Authentication failed: ${response.statusCode}');
        } else if (response.statusCode == 429) {
          throw SheetsRateLimitException('Rate limit exceeded');
        } else if (response.statusCode >= 500) {
          throw SheetsServerException('Server error: ${response.statusCode}');
        } else if (response.statusCode != 200) {
          throw Exception('Unexpected response: ${response.statusCode}, ${response.body}');
        }
      } catch (e) {
        if (e is SheetsAuthException || e is SheetsRateLimitException || e is SheetsServerException) {
          rethrow;
        }
        throw SheetsNetworkException('Network request failed: $e');
      }
    }
  }
  
  // Helper to convert column index to letter (0 -> A, 1 -> B, etc.)
  static String _columnToLetter(int columnIndex) {
    String result = '';
    while (columnIndex >= 0) {
      result = String.fromCharCode((columnIndex % 26) + 65) + result;
      columnIndex = (columnIndex ~/ 26) - 1;
    }
    return result;
  }
}
