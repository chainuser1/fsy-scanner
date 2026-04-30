enum ParticipantVerificationStage { pending, partiallyVerified, fullyVerified }

class Participant {
  final String id;
  final String fullName;
  final String? stake;
  final String? ward;
  final String? gender;
  final String? roomNumber;
  final String? tableNumber;
  final String? tshirtSize;
  final String? medicalInfo;
  final String? note;
  final String? status;
  final int? age;
  final String? birthday;
  final int? verifiedAt;
  final int? printedAt;
  final String? registeredBy;
  final int sheetsRow;
  final String? rawJson;
  final int? updatedAt;

  Participant({
    required this.id,
    required this.fullName,
    this.stake,
    this.ward,
    this.gender,
    this.roomNumber,
    this.tableNumber,
    this.tshirtSize,
    this.medicalInfo,
    this.note,
    this.status,
    this.age,
    this.birthday,
    this.verifiedAt,
    this.printedAt,
    this.registeredBy,
    required this.sheetsRow,
    this.rawJson,
    this.updatedAt,
  });

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'full_name': fullName,
      'stake': stake,
      'ward': ward,
      'gender': gender,
      'room_number': roomNumber,
      'table_number': tableNumber,
      'tshirt_size': tshirtSize,
      'medical_info': medicalInfo,
      'note': note,
      'status': status,
      'age': age,
      'birthday': birthday,
      'verified_at': verifiedAt,
      'printed_at': printedAt,
      'registered_by': registeredBy,
      'sheets_row': sheetsRow,
      'raw_json': rawJson,
      'updated_at': updatedAt,
    };
  }

  factory Participant.fromJson(Map<String, dynamic> json) {
    return Participant(
      id: json['id'] as String? ?? '',
      fullName: json['full_name'] as String? ?? '',
      stake: json['stake'] as String?,
      ward: json['ward'] as String?,
      gender: json['gender'] as String?,
      roomNumber: json['room_number'] as String?,
      tableNumber: json['table_number'] as String?,
      tshirtSize: json['tshirt_size'] as String?,
      medicalInfo: json['medical_info'] as String?,
      note: json['note'] as String?,
      status: json['status'] as String?,
      age: _parseNullableInt(json['age']),
      birthday: json['birthday'] as String?,
      verifiedAt: _parseNullableInt(json['verified_at']),
      printedAt: _parseNullableInt(json['printed_at']),
      registeredBy: json['registered_by'] as String?,
      sheetsRow: _parseNullableInt(json['sheets_row']) ?? 0,
      rawJson: json['raw_json'] as String?,
      updatedAt: _parseNullableInt(json['updated_at']),
    );
  }

  factory Participant.fromDbRow(Map<String, Object?> row) {
    return Participant(
      id: row['id'] as String,
      fullName: row['full_name'] as String,
      stake: row['stake'] as String?,
      ward: row['ward'] as String?,
      gender: row['gender'] as String?,
      roomNumber: row['room_number'] as String?,
      tableNumber: row['table_number'] as String?,
      tshirtSize: row['tshirt_size'] as String?,
      medicalInfo: row['medical_info'] as String?,
      note: row['note'] as String?,
      status: row['status'] as String?,
      age: row['age'] as int?,
      birthday: row['birthday'] as String?,
      verifiedAt: row['verified_at'] as int?,
      printedAt: row['printed_at'] as int?,
      registeredBy: row['registered_by'] as String?,
      sheetsRow: row['sheets_row'] as int? ?? 0,
      rawJson: row['raw_json'] as String?,
      updatedAt: row['updated_at'] as int?,
    );
  }

  bool get isVerified => verifiedAt != null;

  bool get isPartiallyVerified => verifiedAt != null && printedAt == null;

  bool get isFullyVerified => verifiedAt != null && printedAt != null;

  ParticipantVerificationStage get verificationStage {
    if (!isVerified) {
      return ParticipantVerificationStage.pending;
    }
    if (isFullyVerified) {
      return ParticipantVerificationStage.fullyVerified;
    }
    return ParticipantVerificationStage.partiallyVerified;
  }

  String get verificationLabel {
    switch (verificationStage) {
      case ParticipantVerificationStage.pending:
        return 'Pending';
      case ParticipantVerificationStage.partiallyVerified:
        return 'Partially Verified';
      case ParticipantVerificationStage.fullyVerified:
        return 'Fully Verified';
    }
  }

  String get receiptStatusLabel {
    if (!isVerified) {
      return 'Not started';
    }
    if (isFullyVerified) {
      return 'Print confirmed';
    }
    return 'Print pending';
  }

  static int? _parseNullableInt(Object? value) {
    if (value == null) {
      return null;
    }
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    if (value is String) {
      return int.tryParse(value.trim());
    }
    return null;
  }
}
