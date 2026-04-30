import '../db/database_helper.dart';

class AnalyticsSavedView {
  final int id;
  final String name;
  final String committeeView;
  final bool isDefault;
  final int createdAt;
  final int updatedAt;

  const AnalyticsSavedView({
    required this.id,
    required this.name,
    required this.committeeView,
    required this.isDefault,
    required this.createdAt,
    required this.updatedAt,
  });

  factory AnalyticsSavedView.fromDbRow(Map<String, Object?> row) {
    return AnalyticsSavedView(
      id: row['id'] as int? ?? 0,
      name: row['name'] as String? ?? '',
      committeeView: row['committee_view'] as String? ?? 'all',
      isDefault: (row['is_default'] as int? ?? 0) == 1,
      createdAt: row['created_at'] as int? ?? 0,
      updatedAt: row['updated_at'] as int? ?? 0,
    );
  }
}

class AnalyticsSavedViewsService {
  static Future<List<AnalyticsSavedView>> listViews() async {
    final db = await DatabaseHelper.database;
    final rows = await db.query(
      'analytics_saved_views',
      orderBy: 'is_default DESC, LOWER(name) ASC, updated_at DESC',
    );
    return rows.map(AnalyticsSavedView.fromDbRow).toList();
  }

  static Future<AnalyticsSavedView> saveView({
    int? id,
    required String name,
    required String committeeView,
    required bool isDefault,
  }) async {
    final db = await DatabaseHelper.database;
    final now = DateTime.now().millisecondsSinceEpoch;
    final trimmedName = name.trim();
    late final int savedId;

    await db.transaction((txn) async {
      if (isDefault) {
        await txn.update('analytics_saved_views', {'is_default': 0});
      }

      final values = <String, Object?>{
        'name': trimmedName,
        'committee_view': committeeView,
        'is_default': isDefault ? 1 : 0,
        'updated_at': now,
      };

      if (id == null) {
        values['created_at'] = now;
        savedId = await txn.insert('analytics_saved_views', values);
      } else {
        await txn.update(
          'analytics_saved_views',
          values,
          where: 'id = ?',
          whereArgs: [id],
        );
        savedId = id;
      }
    });

    final rows = await db.query(
      'analytics_saved_views',
      where: 'id = ?',
      whereArgs: [savedId],
      limit: 1,
    );
    if (rows.isEmpty) {
      throw StateError('Saved analytics view could not be reloaded.');
    }
    return AnalyticsSavedView.fromDbRow(rows.first);
  }

  static Future<void> deleteView(int id) async {
    final db = await DatabaseHelper.database;
    await db.delete('analytics_saved_views', where: 'id = ?', whereArgs: [id]);
  }
}
