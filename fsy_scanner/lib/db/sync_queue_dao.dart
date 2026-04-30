import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../models/sync_task.dart';
import 'database_helper.dart';

class SyncQueueDao {
  static const String typeMarkRegistered = 'mark_registered';
  static const String typeMarkPrinted = 'mark_printed';
  static const String typeMarkUnverified = 'mark_unverified';

  static Future<int> enqueueTask(
    String type,
    Map<String, dynamic> payload,
  ) async {
    final db = await DatabaseHelper.database;
    return db.transaction(
      (txn) => enqueueTaskInTransaction(txn, type, payload),
    );
  }

  static Future<int> enqueueTaskInTransaction(
    DatabaseExecutor db,
    String type,
    Map<String, dynamic> payload,
  ) async {
    await _coalescePendingTasks(db, type, payload);
    return db.insert('sync_tasks', {
      'type': type,
      'payload': jsonEncode(payload),
      'status': 'pending',
      'attempts': 0,
      'created_at': DateTime.now().millisecondsSinceEpoch,
    });
  }

  static Future<void> _coalescePendingTasks(
    DatabaseExecutor db,
    String type,
    Map<String, dynamic> payload,
  ) async {
    final participantId = payload['participantId'] as String?;
    if (participantId == null || participantId.isEmpty) {
      return;
    }

    final results = await db.query(
      'sync_tasks',
      where: 'status = ?',
      whereArgs: ['pending'],
      orderBy: 'created_at ASC',
    );

    final idsToDelete = <int>[];
    for (final row in results) {
      final rowId = row['id'] as int?;
      if (rowId == null) {
        continue;
      }

      final rowType = row['type'] as String? ?? '';
      final rawPayload = row['payload'] as String? ?? '{}';
      Map<String, dynamic> rowPayload;
      try {
        rowPayload = Map<String, dynamic>.from(jsonDecode(rawPayload));
      } catch (_) {
        continue;
      }

      final rowParticipantId = rowPayload['participantId'] as String?;
      if (rowParticipantId != participantId) {
        continue;
      }

      if (type == typeMarkRegistered) {
        if (rowType == typeMarkRegistered || rowType == typeMarkUnverified) {
          idsToDelete.add(rowId);
        }
      } else if (type == typeMarkUnverified) {
        if (rowType == typeMarkRegistered ||
            rowType == typeMarkPrinted ||
            rowType == typeMarkUnverified) {
          idsToDelete.add(rowId);
        }
      } else if (type == typeMarkPrinted) {
        if (rowType == typeMarkPrinted) {
          idsToDelete.add(rowId);
        }
      }
    }

    if (idsToDelete.isEmpty) {
      return;
    }

    final placeholders = List.filled(idsToDelete.length, '?').join(', ');
    await db.delete(
      'sync_tasks',
      where: 'id IN ($placeholders)',
      whereArgs: idsToDelete,
    );
  }

  static Future<SyncTask?> claimNextTask() async {
    final db = await DatabaseHelper.database;
    return db.transaction((txn) async {
      final List<Map<String, Object?>> results = await txn.query(
        'sync_tasks',
        where: 'status = ?',
        whereArgs: ['pending'],
        limit: 1,
        orderBy: 'created_at ASC',
      );
      if (results.isEmpty) return null;
      final task = SyncTask.fromJson(results.first);
      await txn.update(
        'sync_tasks',
        {'status': 'in_progress'},
        where: 'id = ?',
        whereArgs: [task.id],
      );
      return task;
    });
  }

  static Future<void> markCompleted(int taskId) async {
    final db = await DatabaseHelper.database;
    await db.delete('sync_tasks', where: 'id = ?', whereArgs: [taskId]);
  }

  static Future<void> markFailed(int taskId, String error) async {
    final db = await DatabaseHelper.database;
    await db.rawUpdate(
      'UPDATE sync_tasks SET status = ?, attempts = attempts + 1, last_error = ? WHERE id = ?',
      ['pending', error, taskId],
    );
  }

  static Future<void> resetInProgressTasks() async {
    final db = await DatabaseHelper.database;
    await db.update(
      'sync_tasks',
      {'status': 'pending'},
      where: 'status = ?',
      whereArgs: ['in_progress'],
    );
  }

  static Future<SyncTask?> getTask(int taskId) async {
    final db = await DatabaseHelper.database;
    final results = await db.query(
      'sync_tasks',
      where: 'id = ?',
      whereArgs: [taskId],
    );
    if (results.isEmpty) return null;
    return SyncTask.fromJson(results.first);
  }

  static Future<int> getPendingCount() async {
    final db = await DatabaseHelper.database;
    final result = await db.rawQuery(
      "SELECT COUNT(*) AS count FROM sync_tasks WHERE status IN ('pending', 'in_progress')",
    );
    return result.first['count'] as int? ?? 0;
  }

  static Future<Set<String>> getPendingParticipantIds() async {
    final db = await DatabaseHelper.database;
    final results = await db.query(
      'sync_tasks',
      columns: ['payload'],
      where: 'status IN (?, ?)',
      whereArgs: ['pending', 'in_progress'],
    );

    final participantIds = <String>{};
    for (final row in results) {
      final rawPayload = row['payload'] as String? ?? '{}';
      try {
        final payload = Map<String, dynamic>.from(jsonDecode(rawPayload));
        final participantId = payload['participantId'] as String?;
        if (participantId != null && participantId.isNotEmpty) {
          participantIds.add(participantId);
        }
      } catch (_) {
        continue;
      }
    }
    return participantIds;
  }

  // For queue visualizer: get all pending tasks with payload
  static Future<List<Map<String, dynamic>>> getAllPendingTasks() async {
    final db = await DatabaseHelper.database;
    final results = await db.rawQuery(
      "SELECT * FROM sync_tasks WHERE status IN ('pending', 'in_progress') ORDER BY created_at ASC",
    );
    return results
        .map(
          (row) => {
            'id': row['id'],
            'type': row['type'],
            'payload': row['payload'],
            'status': row['status'],
            'attempts': row['attempts'],
          },
        )
        .toList();
  }
}
