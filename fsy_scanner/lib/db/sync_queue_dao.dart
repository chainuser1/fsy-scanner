import 'dart:convert';

import '../models/sync_task.dart';
import 'database_helper.dart';

class SyncQueueDao {
  // Add new task. Returns new task id.
  static Future<int> enqueueTask(String type, Map<String, dynamic> payload) async {
    final db = await DatabaseHelper.database;
    final taskId = await db.insert(
      'sync_tasks',
      {
        'type': type,
        'payload': jsonEncode(payload),
        'created_at': DateTime.now().millisecondsSinceEpoch,
      },
    );
    return taskId;
  }

  // Fetch next pending task and set status to 'in_progress'. Returns null if empty.
  static Future<SyncTask?> claimNextTask() async {
    final db = await DatabaseHelper.database;
    // Begin transaction to ensure atomicity
    return db.transaction((txn) async {
      // Find the first pending task
      final List<Map<String, Object?>> results = await txn.query(
        'sync_tasks',
        where: 'status = ?',
        whereArgs: ['pending'],
        limit: 1,
        orderBy: 'created_at ASC', // Process oldest first
      );

      if (results.isEmpty) {
        return null; // No pending tasks
      }

      // Extract task
      final task = SyncTask.fromJson(results.first);

      // Update its status to prevent others from claiming
      await txn.update(
        'sync_tasks',
        {'status': 'in_progress'},
        where: 'id = ?',
        whereArgs: [task.id],
      );

      return task;
    });
  }

  // Mark task as completed
  static Future<void> markCompleted(int taskId) async {
    final db = await DatabaseHelper.database;
    await db.update(
      'sync_tasks',
      {'status': 'completed', 'completed_at': DateTime.now().millisecondsSinceEpoch},
      where: 'id = ?',
      whereArgs: [taskId],
    );
  }

  // Mark task as failed
  static Future<void> markFailed(int taskId, String error) async {
    final db = await DatabaseHelper.database;
    await db.rawUpdate(
      'UPDATE sync_tasks SET status = ?, attempts = attempts + 1, last_error = ? WHERE id = ?',
      ['pending', error, taskId],
    );
  }

  // On app start: reset all 'in_progress' tasks to 'pending'.
  static Future<void> resetInProgressTasks() async {
    final db = await DatabaseHelper.database;
    await db.update(
      'sync_tasks',
      {'status': 'pending'},
      where: 'status = ?',
      whereArgs: ['in_progress'],
    );
  }

  // Get pending tasks
  static Future<List<SyncTask>> getPendingTasks() async {
    final db = await DatabaseHelper.database;
    final List<Map<String, Object?>> results = await db.query(
      'sync_tasks',
      where: 'status = ?',
      whereArgs: ['pending'],
      orderBy: 'created_at ASC',
    );

    return results.map(SyncTask.fromJson).toList();
  }

  // Get count of pending tasks
  static Future<int> getPendingCount() async {
    final db = await DatabaseHelper.database;
    final result = await db.rawQuery('SELECT COUNT(*) AS count FROM sync_tasks WHERE status = ?', ['pending']);
    final count = result.first['count'] as int;
    return count;
  }
}
