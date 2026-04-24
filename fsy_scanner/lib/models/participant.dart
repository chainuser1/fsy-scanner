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
  final int registered; // 0 = not checked in, 1 = checked in
  final int? verifiedAt;
  final int? printedAt;
  final String? registeredBy;
  final int sheetsRow;
  final String? rawJson;
  final int? updatedAt;
  final String? regId; // Add regId field

  Participant({
    required this.id,
    required this.fullName,
    this.stake,
    this.regId, // Add regId parameter
    this.ward,
    this.gender,
    this.roomNumber,
    this.tableNumber,
    this.tshirtSize,
    this.medicalInfo,
    this.note,
    this.status,
    this.registered = 0,
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
      'registered': registered,
      'verified_at': verifiedAt,
      'printed_at': printedAt,
      'registered_by': registeredBy,
      'sheets_row': sheetsRow,
      'raw_json': rawJson,
      'updated_at': updatedAt,
      'reg_id': regId, // Add regId to JSON
    };
  }

  factory Participant.fromJson(Map<String, dynamic> json) {
    return Participant(
      id: json['id'] ?? '',
      fullName: json['full_name'] ?? '',
      stake: json['stake'],
      ward: json['ward'],
      gender: json['gender'],
      roomNumber: json['room_number'],
      tableNumber: json['table_number'],
      tshirtSize: json['tshirt_size'],
      medicalInfo: json['medical_info'],
      note: json['note'],
      status: json['status'],
      registered: json['registered'] ?? 0,
      verifiedAt: json['verified_at'],
      printedAt: json['printed_at'],
      registeredBy: json['registered_by'],
      sheetsRow: json['sheets_row'] ?? 0,
      rawJson: json['raw_json'],
      updatedAt: json['updated_at'],
      regId: json['reg_id'], // Add regId from JSON
    );
  }
}
