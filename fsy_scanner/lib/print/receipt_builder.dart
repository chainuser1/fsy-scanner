import 'package:intl/intl.dart';
import '../models/participant.dart';

class ReceiptBuilder {
  static const int _receiptWidth = 32;

  static String build(
      Participant participant, String eventName, String deviceId) {
    final lines = buildLines(participant, eventName, deviceId);
    return lines.map((line) => line.text).join('\n');
  }

  static List<ReceiptLine> buildLines(
      Participant participant, String eventName, String deviceId) {
    final now = DateTime.now();
    final formatter = DateFormat('dd MMM yyyy HH:mm');
    final timestamp = formatter.format(now);
    final shortDeviceId =
        deviceId.length > 8 ? deviceId.substring(0, 8) : deviceId;

    final lines = <ReceiptLine>[
      ReceiptLine(_printerSafe('=' * _receiptWidth)),
      ReceiptLine(_printerSafe(eventName), size: 2, align: 1),
      const ReceiptLine('CHECK-IN RECEIPT', size: 1, align: 1),
      ReceiptLine(_printerSafe('=' * _receiptWidth)),
      ReceiptLine(_printerSafe('Name:  ${participant.fullName}')),
      ReceiptLine(
          _printerSafe('Room:  ${participant.roomNumber ?? '(not assigned)'}')),
      ReceiptLine(_printerSafe(
          'Table: ${participant.tableNumber ?? '(not assigned)'}')),
    ];

    if (participant.tshirtSize != null && participant.tshirtSize!.isNotEmpty) {
      lines.add(ReceiptLine(_printerSafe('Shirt: ${participant.tshirtSize}')));
    }

    lines.addAll([
      ReceiptLine(_printerSafe('=' * _receiptWidth)),
    ]);

    if (participant.medicalInfo != null &&
        participant.medicalInfo!.isNotEmpty) {
      lines.add(
        ReceiptLine(_printerSafe('MEDICAL: ${participant.medicalInfo}'),
            size: 1),
      );
      lines.add(ReceiptLine(_printerSafe('=' * _receiptWidth)));
    }

    lines.addAll([
      ReceiptLine(_printerSafe('Verified: $timestamp')),
      ReceiptLine(_printerSafe('Device: $shortDeviceId')),
      ReceiptLine(_printerSafe('=' * _receiptWidth)),
      ReceiptLine(_printerSafe('Welcome to $eventName!'), align: 1),
      ReceiptLine(_printerSafe('=' * _receiptWidth)),
      const ReceiptLine(''),
      const ReceiptLine(''),
      const ReceiptLine(''),
    ]);

    return lines;
  }

  static String _printerSafe(String value) {
    final buffer = StringBuffer();
    for (final rune in value.runes) {
      switch (rune) {
        case 0x2018:
        case 0x2019:
          buffer.write("'");
          break;
        case 0x201C:
        case 0x201D:
          buffer.write('"');
          break;
        case 0x2013:
        case 0x2014:
          buffer.write('-');
          break;
        case 0x2026:
          buffer.write('...');
          break;
        default:
          if (rune >= 32 && rune <= 126) {
            buffer.writeCharCode(rune);
          } else if (rune == 10 || rune == 13) {
            buffer.writeCharCode(rune);
          } else {
            buffer.write('?');
          }
      }
    }
    return buffer.toString();
  }
}

class ReceiptLine {
  final String text;
  final int size;
  final int align;

  const ReceiptLine(this.text, {this.size = 0, this.align = 0});
}
