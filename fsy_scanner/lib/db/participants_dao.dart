import 'package:sqflite/sqflite.dart';

import '../models/participant.dart';
import 'database_helper.dart';

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
        },
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    }
  }

  static Future<void> upsert(Participant p) async {
    final dao = await getInstance();
    await dao.upsertParticipant(p);
  }

  Future<Participant?> getParticipantById(String id) async {
    final List<Map<String, Object?>> results = await _db.query(
      'participants',
      where: 'id = ?',
      whereArgs: [id],
    );

    if (results.isEmpty) return null;
    return Participant.fromDbRow(results.first);
  }

  Future<void> markVerifiedLocally(String id, String deviceId, int verifiedAt) async {
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
    final List<Map<String, Object?>> results = await _db.query(
      'participants',
      orderBy: 'full_name ASC',
    );

    return results.map((row) => Participant.fromDbRow(row)).toList();
  }

  Future<List<Participant>> searchParticipants(String query) async {
    final List<Map<String, Object?>> results = await _db.query(
      'participants',
      where: 'LOWER(full_name) LIKE ?',
      whereArgs: ['%${query.toLowerCase()}%'],
      limit: 50,
    );

    return results.map((row) => Participant.fromDbRow(row)).toList();
  }

  static Future<int> getRegisteredCount() async {
    final db = await DatabaseHelper.database;
    final result = await db.rawQuery(
      'SELECT COUNT(*) AS count FROM participants WHERE verified_at IS NOT NULL',
    );
    return result.first['count'] as int? ?? 0;
  }
}