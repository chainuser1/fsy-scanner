import 'package:intl/intl.dart';
import '../models/participant.dart';

class ReceiptBuilder {
  static const int _receiptWidth = 32;

  static String build(
      Participant participant, String eventName, String deviceId) {
    final now = DateTime.now();
    final formatter = DateFormat('dd MMM yyyy HH:mm');
    final timestamp = formatter.format(now);
    final shortDeviceId =
        deviceId.length > 8 ? deviceId.substring(0, 8) : deviceId;

    final buffer = StringBuffer();

    buffer.writeln('=' * _receiptWidth);
    buffer.writeln(_centerText(eventName, _receiptWidth));
    buffer.writeln(_centerText('CHECK-IN RECEIPT', _receiptWidth));
    buffer.writeln('=' * _receiptWidth);
    buffer.writeln('Name:  ${participant.fullName}');
    buffer.writeln('Room:  ${participant.roomNumber ?? '(not assigned)'}');
    buffer.writeln('Table: ${participant.tableNumber ?? '(not assigned)'}');

    if (participant.tshirtSize != null && participant.tshirtSize!.isNotEmpty) {
      buffer.writeln('Shirt: ${participant.tshirtSize}');
    }

    buffer.writeln('=' * _receiptWidth);

    if (participant.medicalInfo != null &&
        participant.medicalInfo!.isNotEmpty) {
      buffer.writeln('⚠ MEDICAL: ${participant.medicalInfo}');
      buffer.writeln('=' * _receiptWidth);
    }

    buffer.writeln('Verified: $timestamp');
    buffer.writeln('Device: $shortDeviceId');
    buffer.writeln('=' * _receiptWidth);
    buffer.writeln(_centerText('Welcome to FSY 2026!', _receiptWidth));
    buffer.writeln('=' * _receiptWidth);
    buffer.writeln('\n\n\n'); // Paper feed for cutting

    return buffer.toString();
  }

  /// Center text within the receipt width using left padding
  static String _centerText(String text, int width) {
    if (text.length >= width) {
      return text;
    }
    final leftPadding = (width - text.length) ~/ 2;
    return ' ' * leftPadding + text;
  }
}
