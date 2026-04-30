import 'package:sqflite/sqflite.dart';

import '../models/participant.dart';
import 'database_helper.dart';

class ParticipantQueryResult {
  final List<Participant> participants;
  final int totalCount;

  const ParticipantQueryResult({
    required this.participants,
    required this.totalCount,
  });
}

class ParticipantsDao {
  final Database _db;

  ParticipantsDao(this._db);

  static Future<ParticipantsDao> getInstance() async {
    final db = await DatabaseHelper.database;
    return ParticipantsDao(db);
  }

  Future<void> upsertParticipant(Participant p) async {
    final rowsUpdated = await _db.update(
      'participants',
      {
        'full_name': p.fullName,
        'stake': p.stake,
        'ward': p.ward,
        'gender': p.gender,
        'room_number': p.roomNumber,
        'table_number': p.tableNumber,
        'tshirt_size': p.tshirtSize,
        'medical_info': p.medicalInfo,
        'note': p.note,
        'status': p.status,
        'verified_at': p.verifiedAt,
        'printed_at': p.printedAt,
        'registered_by': p.registeredBy,
        'sheets_row': p.sheetsRow,
        'raw_json': p.rawJson,
        'updated_at': p.updatedAt,
        'age': p.age,
        'birthday': p.birthday,
      },
      where: 'id = ?',
      whereArgs: [p.id],
    );

    if (rowsUpdated == 0) {
      await _db.insert(
          'participants',
          {
            'id': p.id,
            'full_name': p.fullName,
            'stake': p.stake,
            'ward': p.ward,
            'gender': p.gender,
            'room_number': p.roomNumber,
            'table_number': p.tableNumber,
            'tshirt_size': p.tshirtSize,
            'medical_info': p.medicalInfo,
            'note': p.note,
            'status': p.status,
            'verified_at': p.verifiedAt,
            'printed_at': p.printedAt,
            'registered_by': p.registeredBy,
            'sheets_row': p.sheetsRow,
            'raw_json': p.rawJson,
            'updated_at': p.updatedAt,
            'age': p.age,
            'birthday': p.birthday,
          },
          conflictAlgorithm: ConflictAlgorithm.ignore);
    }
  }

  static Future<void> upsert(Participant p) async {
    final dao = await getInstance();
    await dao.upsertParticipant(p);
  }

  Future<Participant?> getParticipantById(String id) async {
    final List<Map<String, Object?>> results =
        await _db.query('participants', where: 'id = ?', whereArgs: [id]);
    if (results.isEmpty) return null;
    return Participant.fromDbRow(results.first);
  }

  Future<void> markVerifiedLocally(
      String id, String deviceId, int verifiedAt) async {
    await _db.update(
      'participants',
      {
        'verified_at': verifiedAt,
        'registered_by': deviceId,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> markUnverifiedLocally(String id) async {
    await _db.update(
      'participants',
      {
        'verified_at': null,
        'printed_at': null,
        'registered_by': null,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> markPrintedLocally(String id, int printedAt) async {
    await _db.update(
      'participants',
      {
        'printed_at': printedAt,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<List<Participant>> getAllParticipants() async {
    final List<Map<String, Object?>> results =
        await _db.query('participants', orderBy: 'full_name ASC');
    return results.map(Participant.fromDbRow).toList();
  }

  Future<int> getParticipantsCount() async {
    final result =
        await _db.rawQuery('SELECT COUNT(*) AS count FROM participants');
    return result.first['count'] as int? ?? 0;
  }

  Future<int> getSearchParticipantsCount(String query) async {
    final ftsQuery = _buildFtsQuery(query);
    if (ftsQuery == null) {
      return getParticipantsCount();
    }

    final result = await _db.rawQuery(
      '''
      SELECT COUNT(*) AS count
      FROM participants_search s
      JOIN participants p ON p.id = s.id
      WHERE participants_search MATCH ?
      ''',
      [ftsQuery],
    );
    return result.first['count'] as int? ?? 0;
  }

  Future<List<Participant>> getParticipantsPage({
    required int limit,
    required int offset,
  }) async {
    final List<Map<String, Object?>> results = await _db.query(
      'participants',
      orderBy: 'full_name ASC',
      limit: limit,
      offset: offset,
    );
    return results.map(Participant.fromDbRow).toList();
  }

  Future<ParticipantQueryResult> searchParticipants(
    String query, {
    required int limit,
    required int offset,
  }) async {
    final ftsQuery = _buildFtsQuery(query);
    if (ftsQuery == null) {
      final participants = await getParticipantsPage(limit: limit, offset: offset);
      final totalCount = await getParticipantsCount();
      return ParticipantQueryResult(
        participants: participants,
        totalCount: totalCount,
      );
    }

    final totalCount = await getSearchParticipantsCount(query);
    final List<Map<String, Object?>> results = await _db.rawQuery(
      '''
      SELECT p.*
      FROM participants_search s
      JOIN participants p ON p.id = s.id
      WHERE participants_search MATCH ?
      ORDER BY p.full_name ASC
      LIMIT ? OFFSET ?
      ''',
      [ftsQuery, limit, offset],
    );
    return ParticipantQueryResult(
      participants: results.map(Participant.fromDbRow).toList(),
      totalCount: totalCount,
    );
  }

  String? _buildFtsQuery(String query) {
    final tokens = query
        .trim()
        .split(RegExp(r'\s+'))
        .map((token) => token.replaceAll(RegExp(r'["*:()\-]'), ''))
        .where((token) => token.isNotEmpty)
        .toList();

    if (tokens.isEmpty) {
      return null;
    }

    return tokens.map((token) => '$token*').join(' AND ');
  }

  static Future<int> getRegisteredCount() async {
    final db = await DatabaseHelper.database;
    final result = await db.rawQuery(
      'SELECT COUNT(*) AS count FROM participants WHERE verified_at IS NOT NULL',
    );
    return result.first['count'] as int? ?? 0;
  }
}
