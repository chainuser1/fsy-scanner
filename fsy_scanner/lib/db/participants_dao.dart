import 'package:sqflite/sqflite.dart';
import '../models/participant.dart';

class ParticipantsDao {
  final Database db;

  ParticipantsDao(this.db);

  // Insert or update participant. NEVER overwrite registered=1 with registered=0.
  Future<void> upsertParticipant(Participant p) async {
    // First, try to update only if registered is 0 (to preserve registered status)
    final result = await db.rawUpdate('''
      UPDATE participants 
      SET full_name = ?, stake = ?, ward = ?, gender = ?, room_number = ?, 
          table_number = ?, tshirt_size = ?, medical_info = ?, note = ?, 
          status = ?, verified_at = ?, printed_at = ?, registered_by = ?, 
          sheets_row = ?, raw_json = ?, updated_at = ?, regId = ?, regTime = ?,
          firstName = ?, lastName = ?, email = ?, phone = ?, checkInTime = ?,
          isCheckedIn = ?, needsPrint = ?, syncStatus = ?, device_id = ?
      WHERE id = ? AND registered = 0
    ''', [
      p.fullName, p.stake, p.ward, p.gender, p.roomNumber, 
      p.tableNumber, p.tshirtSize, p.medicalInfo, p.note, 
      p.status, p.verifiedAt, p.printedAt, p.registeredBy, 
      p.sheetsRow, p.rawJson, p.updatedAt, p.regId, p.regTime,
      p.firstName, p.lastName, p.email, p.phone, p.checkInTime,
      p.isCheckedIn ? 1 : 0, p.needsPrint ? 1 : 0, p.syncStatus, p.deviceId, p.id
    ]);

    // If no rows were updated (either participant doesn't exist or registered=1), insert or ignore
    if (result == 0) {
      await db.insert(
        'participants',
        {
          'id': p.id,
          'regId': p.regId,
          'regTime': p.regTime,
          'full_name': p.fullName,
          'firstName': p.firstName,
          'lastName': p.lastName,
          'email': p.email,
          'phone': p.phone,
          'stake': p.stake,
          'ward': p.ward,
          'gender': p.gender,
          'room_number': p.roomNumber,
          'table_number': p.tableNumber,
          'tshirt_size': p.tshirtSize,
          'medical_info': p.medicalInfo,
          'note': p.note,
          'status': p.status,
          'registered': p.registered ? 1 : 0,
          'verified_at': p.verifiedAt,
          'printed_at': p.printedAt,
          'checkInTime': p.checkInTime,
          'isCheckedIn': p.isCheckedIn ? 1 : 0,
          'needsPrint': p.needsPrint ? 1 : 0,
          'syncStatus': p.syncStatus,
          'registered_by': p.registeredBy,
          'device_id': p.deviceId,
          'sheets_row': p.sheetsRow,
          'raw_json': p.rawJson,
          'updated_at': p.updatedAt,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }

  }

  // Look up participant by id. Returns null if not found.
  Future<Participant?> getParticipantById(String id) async {
    final maps = await db.query(
      'participants',
      where: 'id = ?',
      whereArgs: [id],
    );

    if (maps.isNotEmpty) {
      return Participant.fromJson(maps.first);
    }
    return null;
  }

  // Mark participant as registered locally.
  Future<void> markRegisteredLocally(String id, String deviceId) async {
    await db.rawUpdate('''
      UPDATE participants 
      SET registered = 1, verified_at = ?, registered_by = ? 
      WHERE id = ?
    ''', [DateTime.now().millisecondsSinceEpoch, deviceId, id]);
  }

  // Mark participant as printed locally.
  Future<void> markPrintedLocally(String id) async {
    await db.rawUpdate('''
      UPDATE participants 
      SET printed_at = ? 
      WHERE id = ?
    ''', [DateTime.now().millisecondsSinceEpoch, id]);
  }

  // Return all participants ordered by full_name ASC.
  Future<List<Participant>> getAllParticipants() async {
    final result = await db.query('participants', orderBy: 'full_name ASC');
    return result.map((e) => Participant.fromJson(e)).toList();
  }

  // Search participants by name (case-insensitive). Returns up to 50 results.
  Future<List<Participant>> searchParticipants(String query) async {
    final result = await db.query(
      'participants',
      where: 'full_name LIKE ?',
      whereArgs: ['%$query%'],
      orderBy: 'full_name ASC',
      limit: 50,
    );
    return result.map((e) => Participant.fromJson(e)).toList();
  }

  // Return count of registered participants.
  Future<int> getRegisteredCount() async {
    final result = await db.rawQuery('SELECT COUNT(*) AS count FROM participants WHERE registered = 1');
    return result.first['count'] as int;
  }

  // Replace all participants with the given list
  Future<void> replaceParticipants(List<Participant> participants) async {
    await db.transaction((txn) async {
      await txn.delete('participants');
      for (final p in participants) {
        await txn.insert('participants', p.toJson()..remove('regId')..remove('regTime'));
      }
    });
  }

  Future<void> clearParticipants() async {
    await db.delete('participants');
  }
}