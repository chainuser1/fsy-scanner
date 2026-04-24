class Participant {
  final String id;
  final String regId;
  final int? regTime;
  final String fullName;
  final String? firstName;
  final String? lastName;
  final String? email;
  final String? phone;
  final String? stake;
  final String? ward;
  final String? gender;
  final String? roomNumber;
  final String? tableNumber;
  final String? tshirtSize;
  final String? medicalInfo;
  final String? note;
  final String? status;
  final bool registered;
  final int? verifiedAt;
  final int? printedAt;
  final String? checkInTime;
  final bool isCheckedIn;
  final bool needsPrint;
  final String? syncStatus;
  final String? registeredBy;
  final int sheetsRow;
  final String? rawJson;
  final int? updatedAt;
  final String? deviceId;

  Participant({
    required this.id,
    required this.regId,
    this.regTime,
    required this.fullName,
    this.firstName,
    this.lastName,
    this.email,
    this.phone,
    this.stake,
    this.ward,
    this.gender,
    this.roomNumber,
    this.tableNumber,
    this.tshirtSize,
    this.medicalInfo,
    this.note,
    this.status,
    this.registered = false,
    this.verifiedAt,
    this.printedAt,
    this.checkInTime,
    this.isCheckedIn = false,
    this.needsPrint = false,
    this.syncStatus,
    this.registeredBy,
    this.deviceId,
    required this.sheetsRow,
    this.rawJson,
    this.updatedAt,
  });

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'regId': regId,
      'regTime': regTime,
      'fullName': fullName,
      'firstName': firstName,
      'lastName': lastName,
      'email': email,
      'phone': phone,
      'stake': stake,
      'ward': ward,
      'gender': gender,
      'room_number': roomNumber,
      'table_number': tableNumber,
      'tshirt_size': tshirtSize,
      'medical_info': medicalInfo,
      'note': note,
      'status': status,
      'registered': registered ? 1 : 0,
      'verified_at': verifiedAt,
      'printed_at': printedAt,
      'checkInTime': checkInTime,
      'isCheckedIn': isCheckedIn ? 1 : 0,
      'needsPrint': needsPrint ? 1 : 0,
      'syncStatus': syncStatus,
      'registered_by': registeredBy,
      'device_id': deviceId,
      'sheets_row': sheetsRow,
      'raw_json': rawJson,
      'updated_at': updatedAt,
    };
  }

  factory Participant.fromJson(Map<String, dynamic> json) {
    return Participant(
      id: json['id'] ?? '',
      regId: json['regId'] ?? '',
      regTime: json['regTime'],
      fullName: json['fullName'] ?? '',
      firstName: json['firstName'],
      lastName: json['lastName'],
      email: json['email'],
      phone: json['phone'],
      stake: json['stake'],
      ward: json['ward'],
      gender: json['gender'],
      roomNumber: json['room_number'],
      tableNumber: json['table_number'],
      tshirtSize: json['tshirt_size'],
      medicalInfo: json['medical_info'],
      note: json['note'],
      status: json['status'],
      registered: (json['registered'] ?? 0) == 1,
      verifiedAt: json['verified_at'],
      printedAt: json['printed_at'],
      checkInTime: json['checkInTime'],
      isCheckedIn: (json['isCheckedIn'] ?? 0) == 1,
      needsPrint: (json['needsPrint'] ?? 0) == 1,
      syncStatus: json['syncStatus'],
      registeredBy: json['registered_by'],
      deviceId: json['device_id'],
      sheetsRow: json['sheets_row'] ?? 0,
      rawJson: json['raw_json'],
      updatedAt: json['updated_at'],
    );
  }

  factory Participant.fromSheetRow(List<dynamic> row) {
    // Assuming the row contains columns in a specific order
    // This is a simplified version - adjust according to actual spreadsheet structure
    return Participant(
      id: row.length > 0 ? row[0]?.toString() ?? '' : '',
      regId: row.length > 1 ? row[1]?.toString() ?? '' : '',
      fullName: row.length > 2 ? row[2]?.toString() ?? '' : '',
      firstName: row.length > 3 ? row[3]?.toString() : null,
      lastName: row.length > 4 ? row[4]?.toString() : null,
      email: row.length > 5 ? row[5]?.toString() : null,
      phone: row.length > 6 ? row[6]?.toString() : null,
      stake: row.length > 7 ? row[7]?.toString() : null,
      ward: row.length > 8 ? row[8]?.toString() : null,
      gender: row.length > 9 ? row[9]?.toString() : null,
      roomNumber: row.length > 10 ? row[10]?.toString() : null,
      tableNumber: row.length > 11 ? row[11]?.toString() : null,
      tshirtSize: row.length > 12 ? row[12]?.toString() : null,
      medicalInfo: row.length > 13 ? row[13]?.toString() : null,
      note: row.length > 14 ? row[14]?.toString() : null,
      status: row.length > 15 ? row[15]?.toString() : null,
      registered: row.length > 16 ? (row[16]?.toString() ?? '') == '1' : false,
      sheetsRow: 0, // The actual row number would be calculated separately
      regTime: DateTime.now().millisecondsSinceEpoch,
      checkInTime: null,
      isCheckedIn: false,
      needsPrint: true, // Default to true to trigger printing
      syncStatus: 'synced',
    );
  }
}
