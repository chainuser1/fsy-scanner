import 'package:sqflite/sqflite.dart';
import '../db/sync_queue_dao.dart';
import '../models/participant.dart';
import 'sheets_api.dart';  // Changed from SheetsApi to sheets_api

/// Push changes from local SQLite to Sheets
Future<void> drainQueue(Database db, String token, String sheetId, String tabName) async {
  while (true) {
    // 1. claimNextTask() — returns one task or null
    final task = await claimNextTask(db);
    if (task == null) {
      // 2. If null: return (queue empty)
      return;
    }

    try {
      // 3. Parse payload JSON is done in claimNextTask
      final type = task['type'] as String;
      final payload = task['payload'] as Map<String, dynamic>;
      final taskId = task['id'] as int;

      // 4. If type = 'mark_registered':
      if (type == 'mark_registered') {
        // Write: Registered=Y, Verified At=ISO timestamp, Registered By=device_id
        final regId = payload['regId'] as String;
        final deviceId = payload['deviceId'] as String;
        
        await markRegistered(sheetId, tabName, regId, deviceId, token);  // Updated function name
      } 
      // If type = 'mark_printed':
      else if (type == 'mark_printed') {
        // Write: Printed At=ISO timestamp
        final regId = payload['regId'] as String;
        
        await markPrinted(sheetId, tabName, regId, token);  // Updated function name
      }
      else if (type == 'upsert_participant') {
        // Handle upserting a participant
        final participant = Participant.fromJson(payload);
        await upsertParticipant(participant, token);  // Updated function name
      }

      // 6. On HTTP 200: completeTask(), repeat from step 1
      await completeTask(db, taskId);
    } catch (e) {
      final taskId = task['id'] as int;
      final attempts = task['attempts'] as int;
      
      // 7. On SheetsRateLimitException: failTask(), throw upward for backoff
      if (e.toString().contains('RateLimit')) {
        await failTask(db, taskId, e.toString());
        rethrow; // Re-throw to trigger backoff at higher level
      }
      
      // 8. On other error: failTask(), if attempts >= 10 notify AppState, continue to next task
      await failTask(db, taskId, e.toString());
      
      if (attempts >= 10) {
        print('Task $taskId failed after 10 attempts: $e');
      }
      // Continue to next task
    }
  }
}