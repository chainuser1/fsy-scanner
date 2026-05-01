import 'package:sqflite/sqflite.dart';

import '../models/participant.dart';
import 'database_helper.dart';
import 'sync_queue_dao.dart';

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

  Future<void> upsertParticipant(
    Participant p, {
    bool preserveLocalVerificationState = false,
    int? pullStartedAt,
  }) async {
    final existing = await getParticipantById(p.id);
    final existingUpdatedAt = existing?.updatedAt ?? 0;
    final shouldPreserveVerificationState = existing != null &&
        (preserveLocalVerificationState ||
            (pullStartedAt != null && existingUpdatedAt > pullStartedAt));
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
        'registration_source': p.registrationSource,
        'signed_by': p.signedBy,
        'verified_at': shouldPreserveVerificationState
            ? existing.verifiedAt
            : p.verifiedAt,
        'printed_at':
            shouldPreserveVerificationState ? existing.printedAt : p.printedAt,
        'registered_by': shouldPreserveVerificationState
            ? existing.registeredBy
            : p.registeredBy,
        'sheets_row': p.sheetsRow,
        'raw_json': p.rawJson,
        'updated_at':
            shouldPreserveVerificationState ? existing.updatedAt : p.updatedAt,
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
            'registration_source': p.registrationSource,
            'signed_by': p.signedBy,
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

  static Future<void> upsertFromPull(
    Participant p, {
    required Set<String> pendingParticipantIds,
    required int pullStartedAt,
  }) async {
    final dao = await getInstance();
    await dao.upsertParticipant(
      p,
      preserveLocalVerificationState: pendingParticipantIds.contains(p.id),
      pullStartedAt: pullStartedAt,
    );
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

  Future<void> markVerifiedLocally(
    String id,
    String deviceId,
    int verifiedAt,
  ) async {
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

  static Future<void> markVerifiedAndQueue(
    String id,
    String deviceId,
    int verifiedAt,
  ) async {
    final db = await DatabaseHelper.database;
    await db.transaction((txn) async {
      final updatedAt = DateTime.now().millisecondsSinceEpoch;
      await txn.update(
        'participants',
        {
          'verified_at': verifiedAt,
          'registered_by': deviceId,
          'updated_at': updatedAt,
        },
        where: 'id = ?',
        whereArgs: [id],
      );
      await SyncQueueDao.enqueueTaskInTransaction(
        txn,
        SyncQueueDao.typeMarkRegistered,
        {
          'participantId': id,
          'verifiedAt': verifiedAt,
          'registeredBy': deviceId,
        },
      );
    });
  }

  static Future<void> markUnverifiedAndQueue(String id) async {
    final db = await DatabaseHelper.database;
    await db.transaction((txn) async {
      final updatedAt = DateTime.now().millisecondsSinceEpoch;
      await txn.update(
        'participants',
        {
          'verified_at': null,
          'printed_at': null,
          'registered_by': null,
          'updated_at': updatedAt,
        },
        where: 'id = ?',
        whereArgs: [id],
      );
      await SyncQueueDao.enqueueTaskInTransaction(
        txn,
        SyncQueueDao.typeMarkUnverified,
        {'participantId': id},
      );
    });
  }

  static Future<void> markPrintedAndQueue(String id, int printedAt) async {
    final db = await DatabaseHelper.database;
    await db.transaction((txn) async {
      final updatedAt = DateTime.now().millisecondsSinceEpoch;
      await txn.update(
        'participants',
        {'printed_at': printedAt, 'updated_at': updatedAt},
        where: 'id = ?',
        whereArgs: [id],
      );
      await SyncQueueDao.enqueueTaskInTransaction(
        txn,
        SyncQueueDao.typeMarkPrinted,
        {'participantId': id, 'printedAt': printedAt},
      );
    });
  }

  Future<List<Participant>> getAllParticipants() async {
    final List<Map<String, Object?>> results = await _db.query(
      'participants',
      orderBy: 'full_name ASC',
    );
    return results.map(Participant.fromDbRow).toList();
  }

  Future<int> getParticipantsCount() async {
    final result = await _db.rawQuery(
      'SELECT COUNT(*) AS count FROM participants',
    );
    return result.first['count'] as int? ?? 0;
  }

  Future<int> getSearchParticipantsCount(String query) async {
    final searchTerm = _buildSearchTerm(query);
    if (searchTerm == null) {
      return getParticipantsCount();
    }

    final result = await _db.rawQuery('''
      SELECT COUNT(*) AS count
      FROM participants p
      WHERE
        LOWER(COALESCE(p.full_name, '')) LIKE ? OR
        LOWER(COALESCE(p.stake, '')) LIKE ? OR
        LOWER(COALESCE(p.ward, '')) LIKE ? OR
        LOWER(COALESCE(p.room_number, '')) LIKE ? OR
        LOWER(COALESCE(p.table_number, '')) LIKE ? OR
        LOWER(COALESCE(p.gender, '')) LIKE ? OR
        LOWER(COALESCE(p.status, '')) LIKE ? OR
        LOWER(COALESCE(p.registration_source, '')) LIKE ? OR
        LOWER(COALESCE(p.signed_by, '')) LIKE ? OR
        LOWER(COALESCE(p.tshirt_size, '')) LIKE ? OR
        LOWER(COALESCE(p.medical_info, '')) LIKE ? OR
        LOWER(COALESCE(p.note, '')) LIKE ? OR
        LOWER(COALESCE(p.birthday, '')) LIKE ? OR
        CAST(COALESCE(p.age, '') AS TEXT) LIKE ?
      ''', List<String>.filled(14, searchTerm));
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
    final searchTerm = _buildSearchTerm(query);
    if (searchTerm == null) {
      final participants = await getParticipantsPage(
        limit: limit,
        offset: offset,
      );
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
      FROM participants p
      WHERE
        LOWER(COALESCE(p.full_name, '')) LIKE ? OR
        LOWER(COALESCE(p.stake, '')) LIKE ? OR
        LOWER(COALESCE(p.ward, '')) LIKE ? OR
        LOWER(COALESCE(p.room_number, '')) LIKE ? OR
        LOWER(COALESCE(p.table_number, '')) LIKE ? OR
        LOWER(COALESCE(p.gender, '')) LIKE ? OR
        LOWER(COALESCE(p.status, '')) LIKE ? OR
        LOWER(COALESCE(p.registration_source, '')) LIKE ? OR
        LOWER(COALESCE(p.signed_by, '')) LIKE ? OR
        LOWER(COALESCE(p.tshirt_size, '')) LIKE ? OR
        LOWER(COALESCE(p.medical_info, '')) LIKE ? OR
        LOWER(COALESCE(p.note, '')) LIKE ? OR
        LOWER(COALESCE(p.birthday, '')) LIKE ? OR
        CAST(COALESCE(p.age, '') AS TEXT) LIKE ?
      ORDER BY p.full_name ASC
      LIMIT ? OFFSET ?
      ''',
      [...List<String>.filled(14, searchTerm), limit, offset],
    );
    return ParticipantQueryResult(
      participants: results.map(Participant.fromDbRow).toList(),
      totalCount: totalCount,
    );
  }

  String? _buildSearchTerm(String query) {
    final trimmed = query.trim().toLowerCase();
    if (trimmed.isEmpty) {
      return null;
    }
    return '%$trimmed%';
  }

  static Future<int> getRegisteredCount() async {
    final db = await DatabaseHelper.database;
    final result = await db.rawQuery(
      'SELECT COUNT(*) AS count FROM participants WHERE verified_at IS NOT NULL',
    );
    return result.first['count'] as int? ?? 0;
  }

  // Add this inside ParticipantsDao after the existing search methods.

  Future<ParticipantQueryResult> searchParticipantsFiltered(
    String query, {
    required int limit,
    required int offset,
    bool? isVerified,
    bool? isFullyVerified,
    bool? hasMedical,
    bool? hasPendingPrintConfirmation,
    required Set<String> pendingConfirmationParticipantIds,
  }) async {
    final searchTerm = _buildSearchTerm(query);

    String? searchWhere;
    if (searchTerm != null) {
      searchWhere = '''
        (LOWER(COALESCE(p.full_name, '')) LIKE ? OR
        LOWER(COALESCE(p.stake, '')) LIKE ? OR
        LOWER(COALESCE(p.ward, '')) LIKE ? OR
        LOWER(COALESCE(p.room_number, '')) LIKE ? OR
        LOWER(COALESCE(p.table_number, '')) LIKE ? OR
        LOWER(COALESCE(p.gender, '')) LIKE ? OR
        LOWER(COALESCE(p.status, '')) LIKE ? OR
        LOWER(COALESCE(p.registration_source, '')) LIKE ? OR
        LOWER(COALESCE(p.signed_by, '')) LIKE ? OR
        LOWER(COALESCE(p.tshirt_size, '')) LIKE ? OR
        LOWER(COALESCE(p.medical_info, '')) LIKE ? OR
        LOWER(COALESCE(p.note, '')) LIKE ? OR
        LOWER(COALESCE(p.birthday, '')) LIKE ? OR
        CAST(COALESCE(p.age, '') AS TEXT) LIKE ?)
      ''';
    }

    final conditions = <String>[];
    final params = <dynamic>[];

    if (searchWhere != null) {
      conditions.add(searchWhere);
      params.addAll(List.filled(14, searchTerm));
    }

    if (isVerified == true) {
      conditions.add('p.verified_at IS NOT NULL');
    } else if (isVerified == false) {
      conditions.add('p.verified_at IS NULL');
    }

    if (isFullyVerified == true) {
      conditions.add('p.printed_at IS NOT NULL');
    } else if (isFullyVerified == false) {
      conditions.add('p.verified_at IS NOT NULL AND p.printed_at IS NULL');
    }

    if (hasMedical == true) {
      conditions.add(
        "COALESCE(p.medical_info, '') != '' AND LOWER(COALESCE(p.medical_info, '')) NOT IN ('none', 'n/a', 'na')",
      );
    } else if (hasMedical == false) {
      conditions.add(
        "(COALESCE(p.medical_info, '') = '' OR LOWER(COALESCE(p.medical_info, '')) IN ('none', 'n/a', 'na'))",
      );
    }

    if (hasPendingPrintConfirmation == true) {
      if (pendingConfirmationParticipantIds.isEmpty) {
        conditions.add('1=0');
      } else {
        final placeholders =
            List.filled(pendingConfirmationParticipantIds.length, '?')
                .join(',');
        conditions.add('p.id IN ($placeholders)');
        params.addAll(pendingConfirmationParticipantIds);
      }
    }

    final whereClause =
        conditions.isNotEmpty ? 'WHERE ${conditions.join(' AND ')}' : '';

    final countSql =
        'SELECT COUNT(*) AS count FROM participants p $whereClause';
    final countResult = await _db.rawQuery(countSql, params);
    final totalCount = countResult.first['count'] as int? ?? 0;

    final dataSql = '''
      SELECT p.* FROM participants p
      $whereClause
      ORDER BY p.full_name ASC
      LIMIT ? OFFSET ?
    ''';
    final dataParams = [...params, limit, offset];
    final rows = await _db.rawQuery(dataSql, dataParams);

    return ParticipantQueryResult(
      participants: rows.map(Participant.fromDbRow).toList(),
      totalCount: totalCount,
    );
  }
}
