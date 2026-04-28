import 'package:sqflite/sqflite.dart';

import '../models/participant.dart';
import 'database_helper.dart';

class ParticipantsDao {
  final Database _db;

  ParticipantsDao(this._db);

  // Get a database-connected DAO instance
  static Future<ParticipantsDao> getInstance() async {
    final db = await DatabaseHelper.database;
    return ParticipantsDao(db);
  }

  // Insert or update participant. NEVER overwrite registered=1 with registered=0.
  Future<void> upsertParticipant(Participant p) async {
    // First try to update only if registered is currently 0
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
        'registered': p.registered,
        'verified_at': p.verifiedAt,
        'printed_at': p.printedAt,
        'registered_by': p.registeredBy,
        'sheets_row': p.sheetsRow,
        'raw_json': p.rawJson,
        'updated_at': p.updatedAt,
      },
      where: 'id = ? AND registered = 0',
      whereArgs: [p.id],
    );

    if (rowsUpdated == 0) {
      // Either participant doesn't exist yet or registered=1, so insert OR IGNORE
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
          'registered': p.registered,
          'verified_at': p.verifiedAt,
          'printed_at': p.printedAt,
          'registered_by': p.registeredBy,
          'sheets_row': p.sheetsRow,
          'raw_json': p.rawJson,
          'updated_at': p.updatedAt,
        },
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    }
  }

  // Static helper to upsert a participant
  static Future<void> upsert(Participant p) async {
    final dao = await getInstance();
    await dao.upsertParticipant(p);
  }

  // Look up participant by id. Returns null if not found.
  Future<Participant?> getParticipantById(String id) async {
    final List<Map<String, Object?>> results = await _db.query(
      'participants',
      where: 'id = ?',
      whereArgs: [id],
    );

    if (results.isEmpty) {
      return null;
    }

    return Participant.fromDbRow(results.first);
  }

  // Mark participant as registered locally.
  Future<void> markRegisteredLocally(String id, String deviceId, int verifiedAt) async {
    await _db.update(
      'participants',
      {
        'registered': 1,
        'verified_at': verifiedAt,
        'registered_by': deviceId,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  // Mark participant as printed locally.
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

  // Return all participants ordered by full_name ASC.
  Future<List<Participant>> getAllParticipants() async {
    final List<Map<String, Object?>> results = await _db.query(
      'participants',
      orderBy: 'full_name ASC',
    );

    return results.map((row) => Participant.fromDbRow(row)).toList();
  }

  // Search participants by name (case-insensitive). Returns up to 50 results.
  Future<List<Participant>> searchParticipants(String query) async {
    final List<Map<String, Object?>> results = await _db.query(
      'participants',
      where: 'LOWER(full_name) LIKE ?',
      whereArgs: ['%${query.toLowerCase()}%'],
      limit: 50,
    );

    return results.map((row) => Participant.fromDbRow(row)).toList();
  }

  // Get count of registered participants
  static Future<int> getRegisteredCount() async {
    final db = await DatabaseHelper.database;
    final result = await db.rawQuery(
      'SELECT COUNT(*) AS count FROM participants WHERE registered = 1',
    );
    return result.first['count'] as int? ?? 0;
  }
}