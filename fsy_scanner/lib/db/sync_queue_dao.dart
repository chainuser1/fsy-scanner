import 'dart:convert';

import '../models/sync_task.dart';
import 'database_helper.dart';

class SyncQueueDao {
  // Define constants for task types to ensure consistency
  static const String typeMarkRegistered = 'mark_registered';
  static const String typeMarkPrinted = 'mark_printed';

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

  // Mark task as completed - just delete directly
  static Future<void> markCompleted(int taskId) async {
    final db = await DatabaseHelper.database;
    await db.delete('sync_tasks', where: 'id = ?', whereArgs: [taskId]);
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

  // Get task by ID
  static Future<SyncTask?> getTask(int taskId) async {
    final db = await DatabaseHelper.database;
    final results = await db.query(
      'sync_tasks',
      where: 'id = ?',
      whereArgs: [taskId],
    );
    
    if (results.isEmpty) {
      return null;
    }
    
    return SyncTask.fromJson(results.first);
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

  // Get count of pending tasks - count both 'pending' and 'in_progress' statuses
  static Future<int> getPendingCount() async {
    final db = await DatabaseHelper.database;
    final result = await db.rawQuery("SELECT COUNT(*) AS count FROM sync_tasks WHERE status IN ('pending', 'in_progress')");
    final count = result.first['count'] as int;
    return count;
  }
}