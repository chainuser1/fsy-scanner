import 'package:intl/intl.dart';
import '../models/participant.dart';

class ReceiptBuilder {
  static const int _receiptWidth = 32;

  static String build(
    Participant participant,
    String eventName,
    String organizationName,
    String deviceId,
  ) {
    final lines = buildLines(
      participant,
      eventName,
      organizationName,
      deviceId,
    );
    return lines.map((line) => line.text).join('\n');
  }

  static List<ReceiptLine> buildLines(
    Participant participant,
    String eventName,
    String organizationName,
    String deviceId,
  ) {
    final now = DateTime.now();
    final formatter = DateFormat('dd MMM yyyy HH:mm');
    final timestamp = formatter.format(now);
    // final shortDeviceId =
        // deviceId.length > 8 ? deviceId.substring(0, 8) : deviceId;
    // final event = _cleanValue(eventName);
    // final organization = _toReceiptUpper(_cleanValue(organizationName));
    final fullName = _toReceiptUpper(_cleanValue(participant.fullName)) ?? '-';

    final lines = <ReceiptLine>[
      ReceiptLine(_printerSafe('=' * _receiptWidth)),
      const ReceiptLine('CHECK-IN RECEIPT', size: 1, align: 1),
      ReceiptLine(_printerSafe('=' * _receiptWidth)),
    ];

    lines.addAll(_wrappedLines(fullName, width: _receiptWidth, align: 1));
    lines.add(const ReceiptLine(''));
    lines.addAll(
      _labeledLines('Room', participant.roomNumber ?? '(not assigned)'),
    );
    lines.addAll(
      _labeledLines('Group', participant.tableNumber ?? '(not assigned)'),
    );

    final ward = _cleanValue(participant.ward);
    if (ward != null) {
      lines.addAll(_labeledLines('Ward', ward));
    }

    final shirt = _cleanValue(participant.tshirtSize);
    if (shirt != null) {
      lines.addAll(_labeledLines('Shirt', shirt));
    }

    lines.add(ReceiptLine(_printerSafe('=' * _receiptWidth)));
    lines.add(ReceiptLine(_printerSafe('Verified: $timestamp')));
    // lines.add(ReceiptLine(_printerSafe('Device: $shortDeviceId')));
    lines.add(ReceiptLine(_printerSafe('=' * _receiptWidth)));

    // if (organization != null) {
    //   lines.add(const ReceiptLine('Hosted by', align: 1));
    //   lines.addAll(_wrappedLines(organization, width: _receiptWidth, align: 1));
    // }

    // lines.add(const ReceiptLine(''));

    // lines.add(const ReceiptLine('Welcome to', align: 1));
    // lines.addAll(
    //   _wrappedLines(event ?? 'FSY Event', width: _receiptWidth, align: 1),
    // );
    // lines.add(ReceiptLine(_printerSafe('=' * _receiptWidth)));

    return lines;
  }

  static List<ReceiptLine> _labeledLines(String label, String value) {
    final safeValue = _cleanValue(value) ?? '-';
    final prefix = '$label: ';
    final indent = ' ' * prefix.length;
    final wrapped = _wrapText(safeValue, _receiptWidth - prefix.length);

    final lines = <ReceiptLine>[];
    for (var i = 0; i < wrapped.length; i++) {
      final text = i == 0 ? '$prefix${wrapped[i]}' : '$indent${wrapped[i]}';
      lines.add(ReceiptLine(_printerSafe(text)));
    }
    return lines;
  }

  static List<ReceiptLine> _wrappedLines(
    String value, {
    required int width,
    int align = 0,
    int size = 0,
  }) {
    return _wrapText(value, width)
        .map(
          (line) => ReceiptLine(_printerSafe(line), align: align, size: size),
        )
        .toList();
  }

  static String? _toReceiptUpper(String? value) {
    if (value == null) {
      return null;
    }
    return value.toUpperCase();
  }

  static String? _cleanValue(String? value) {
    if (value == null) {
      return null;
    }

    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      return null;
    }

    final lower = trimmed.toLowerCase();
    if (lower == 'none' || lower == 'n/a' || lower == 'na' || lower == 'null') {
      return null;
    }

    return trimmed;
  }

  static List<String> _wrapText(String value, int width) {
    final normalized = _printerSafe(
      value,
    ).replaceAll(RegExp(r'\s+'), ' ').trim();
    if (normalized.isEmpty) {
      return const <String>[];
    }

    final words = normalized.split(' ');
    final lines = <String>[];
    var current = '';

    for (final word in words) {
      if (word.length > width) {
        if (current.isNotEmpty) {
          lines.add(current);
          current = '';
        }

        for (var i = 0; i < word.length; i += width) {
          final end = (i + width < word.length) ? i + width : word.length;
          lines.add(word.substring(i, end));
        }
        continue;
      }

      final candidate = current.isEmpty ? word : '$current $word';
      if (candidate.length <= width) {
        current = candidate;
      } else {
        lines.add(current);
        current = word;
      }
    }

    if (current.isNotEmpty) {
      lines.add(current);
    }

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
