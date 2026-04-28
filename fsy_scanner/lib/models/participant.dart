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
      verifiedAt: json['verified_at'] as int?,
      printedAt: json['printed_at'] as int?,
      registeredBy: json['registered_by'] as String?,
      sheetsRow: json['sheets_row'] as int? ?? 0,
      rawJson: json['raw_json'] as String?,
      updatedAt: json['updated_at'] as int?,
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
      verifiedAt: row['verified_at'] as int?,
      printedAt: row['printed_at'] as int?,
      registeredBy: row['registered_by'] as String?,
      sheetsRow: row['sheets_row'] as int? ?? 0,
      rawJson: row['raw_json'] as String?,
      updatedAt: row['updated_at'] as int?,
    );
  }
}
