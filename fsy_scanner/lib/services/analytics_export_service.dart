import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

class AnalyticsExportResult {
  final String filePath;
  final int byteCount;

  const AnalyticsExportResult({
    required this.filePath,
    required this.byteCount,
  });
}

class AnalyticsExportService {
  static Future<AnalyticsExportResult> exportTextReport({
    required String baseName,
    required String content,
  }) async {
    final directory = await getApplicationDocumentsDirectory();
    final exportDirectory = Directory(
      path.join(directory.path, 'analytics_exports'),
    );
    if (!await exportDirectory.exists()) {
      await exportDirectory.create(recursive: true);
    }

    final timestamp = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '')
        .replaceAll('.', '')
        .replaceAll('-', '');
    final safeBaseName = baseName
        .trim()
        .toLowerCase()
        .replaceAll(RegExp('[^a-z0-9]+'), '_')
        .replaceAll(RegExp('_+'), '_')
        .replaceAll(RegExp(r'^_|_$'), '');
    final file = File(
      path.join(
        exportDirectory.path,
        '${safeBaseName.isEmpty ? 'analytics_summary' : safeBaseName}_$timestamp.txt',
      ),
    );
    await file.writeAsString(content, flush: true);
    final length = await file.length();
    return AnalyticsExportResult(filePath: file.path, byteCount: length);
  }
}
