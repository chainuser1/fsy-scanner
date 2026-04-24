import 'package:sqflite/sqflite.dart';
import '../db/participants_dao.dart';
import '../models/participant.dart';
import 'sheets_api.dart';

// Pull changes from Sheets into local SQLite
Future<void> pull(Database db, String token, String sheetId, String tabName) async {
  // Fetch all rows via sheetsApi.fetchAllRows()
  final allRows = await fetchAllRows(token, sheetId, tabName);
  
  // Convert rows to Participant objects using new fromSheetRow() factory
  final participants = <Participant>[];
  for (final row in allRows) {
    try {
      final participant = Participant.fromSheetRow(row);
      participants.add(participant);
    } catch(e) {
      // Log error but continue processing other rows
      print('Error parsing participant from sheet row: $e');
    }
  }
  
  // Get the DAO instance and bulk replace participants in local DB
  final dao = ParticipantsDao(db);
  await dao.replaceParticipants(participants);
}
