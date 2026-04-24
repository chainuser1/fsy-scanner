import 'dart:convert';
import 'package:http/http.dart' as http;

import '../models/participant.dart';

/// Fetch all rows from the specified sheet
Future<List<List<dynamic>>> fetchAllRows(String token, String sheetId, String tabName) async {
  // Construct the URL to access the Google Sheet
  final url = 'https://sheets.googleapis.com/v4/spreadsheets/$sheetId/values/$tabName';
  
  final headers = {
    'Authorization': 'Bearer $token',
  };

  try {
    final response = await http.get(Uri.parse(url), headers: headers);
    
    if (response.statusCode == 200) {
      final Map<String, dynamic> data = jsonDecode(response.body);
      final List<dynamic>? rows = data['values'] as List<dynamic>?;
      
      // Convert to the expected format
      return (rows ?? []).cast<List<dynamic>>();
    } else {
      throw Exception('Failed to fetch sheet data: ${response.statusCode} - ${response.body}');
    }
  } catch (e) {
    throw Exception('Error fetching sheet data: $e');
  }
}

/// Update a participant's registration status in the sheet
Future<void> markRegistered(String sheetId, String tabName, String regId, String deviceId, String token) async {
  // Implementation would go here
  print('Marking participant $regId as registered in sheet $sheetId');
}

/// Mark a participant as printed in the sheet
Future<void> markPrinted(String sheetId, String tabName, String regId, String token) async {
  // Implementation would go here
  print('Marking participant $regId as printed in sheet $sheetId');
}

/// Upsert a participant in the sheet
Future<void> upsertParticipant(Participant participant, String token) async {
  // Implementation would go here
  print('Upserting participant ${participant.id} in sheet');
}

/// Update participant information
Future<void> updateParticipant(Participant participant) async {
  // Implementation would go here
  print('Updating participant ${participant.id}');
}