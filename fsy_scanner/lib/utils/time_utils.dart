import 'package:intl/intl.dart';

// Returns current time as Unix milliseconds
int nowMs() => DateTime.now().millisecondsSinceEpoch;

// Formats Unix ms timestamp for display on receipt and UI
// Example output: "15 Jun 2026 09:42"
String formatDisplay(int ms) {
  final dt = DateTime.fromMillisecondsSinceEpoch(ms);
  return DateFormat('dd MMM yyyy HH:mm').format(dt);
}
