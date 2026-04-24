import 'dart:convert';
import 'package:sqflite/sqflite.dart';

class SyncQueue {
  final Database db;

  SyncQueue(this.db);

  Future<void> clearSyncQueue() async {
    await db.delete('SyncQueue');
  }
}

// Add new task. Returns new task id.
Future<int> enqueueTask(Database db, String type, Map<String, dynamic> payload) async {
  return await db.insert('sync_tasks', {
    'type': type,
    'payload': jsonEncode(payload),
    'status': 'pending',
    'attempts': 0,
    'created_at': DateTime.now().millisecondsSinceEpoch,
  });
}

// Fetch next pending task and set status to 'in_progress'. Returns null if empty.
Future<Map<String, dynamic>?> claimNextTask(Database db) async {
  final result = await db.rawQuery('''
    SELECT * FROM sync_tasks 
    WHERE status = 'pending' 
    ORDER BY id ASC 
    LIMIT 1
  ''');

  if (result.isEmpty) {
    return null;
  }

  final task = result.first;
  await db.rawUpdate('''
    UPDATE sync_tasks 
    SET status = 'in_progress', attempts = attempts + 1 
    WHERE id = ?
  ''', [task['id']]);

  // Parse the payload from JSON string back to a map
  final payload = jsonDecode(task['payload'].toString());
  
  return {
    'id': task['id'],
    'type': task['type'].toString(),
    'payload': payload,
    'attempts': task['attempts'] as int,
  };
}

// Mark task complete and delete it.
Future<void> completeTask(Database db, int id) async {
  await db.delete('sync_tasks', where: 'id = ?', whereArgs: [id]);
}

// Increment attempts, store error, reset to 'pending'.
Future<void> failTask(Database db, int id, String error) async {
  await db.rawUpdate('''
    UPDATE sync_tasks 
    SET status = 'pending', last_error = ? 
    WHERE id = ?
  ''', [error, id]);
}

// On app start: reset all 'in_progress' tasks to 'pending'.
Future<void> resetInProgressTasks(Database db) async {
  await db.rawUpdate("UPDATE sync_tasks SET status = 'pending' WHERE status = 'in_progress'");
}

// Return count of pending + in_progress tasks.
Future<int> getPendingCount(Database db) async {
  final result = await db.rawQuery('''
    SELECT COUNT(*) AS count 
    FROM sync_tasks 
    WHERE status IN ('pending', 'in_progress')
  ''');
  return result.first['count'] as int;
}