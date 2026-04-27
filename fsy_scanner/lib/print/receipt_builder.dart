import 'package:intl/intl.dart';
import '../models/participant.dart';

class ReceiptBuilder {
  static String build(Participant participant, String eventName, String deviceId) {
    final now = DateTime.now();
    final formatter = DateFormat('dd MMM yyyy HH:mm');
    final timestamp = formatter.format(now);
    final shortDeviceId = deviceId.length > 8 ? deviceId.substring(0, 8) : deviceId;

    final buffer = StringBuffer();
    
    buffer.writeln('================================');
    buffer.writeln(eventName.padLeft((32 + eventName.length) ~/ 2));
    buffer.writeln('       CHECK-IN RECEIPT         ');
    buffer.writeln('================================');
    buffer.writeln('Name:  ${participant.fullName}');
    buffer.writeln('Room:  ${participant.roomNumber ?? '(not assigned)'}');
    buffer.writeln('Table: ${participant.tableNumber ?? '(not assigned)'}');
    
    if (participant.tshirtSize != null && participant.tshirtSize!.isNotEmpty) {
      buffer.writeln('Shirt: ${participant.tshirtSize}');
    }
    
    buffer.writeln('================================');
    
    if (participant.medicalInfo != null && participant.medicalInfo!.isNotEmpty) {
      buffer.writeln('⚠ MEDICAL: ${participant.medicalInfo}');
      buffer.writeln('================================');
    }
    
    buffer.writeln('Verified: $timestamp');
    buffer.writeln('Device: $shortDeviceId');
    buffer.writeln('================================');
    buffer.writeln('    Welcome to FSY 2026!        ');
    buffer.writeln('================================');
    buffer.writeln('\n\n\n'); // Feed for cutting
    
    return buffer.toString();
  }
}


