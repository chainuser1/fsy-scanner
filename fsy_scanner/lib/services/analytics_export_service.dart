import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

class AnalyticsExportResult {
  final String filePath;
  final int byteCount;

  const AnalyticsExportResult({
    required this.filePath,
    required this.byteCount,
  });
}

class AnalyticsExportService {
  static Future<Directory> _exportDirectory() async {
    final directory = await getApplicationDocumentsDirectory();
    final exportDirectory = Directory(
      path.join(directory.path, 'analytics_exports'),
    );
    if (!await exportDirectory.exists()) {
      await exportDirectory.create(recursive: true);
    }
    return exportDirectory;
  }

  static String _timestamp() {
    return DateTime.now()
        .toIso8601String()
        .replaceAll(':', '')
        .replaceAll('.', '')
        .replaceAll('-', '');
  }

  static String _safeBaseName(String baseName) {
    return baseName
        .trim()
        .toLowerCase()
        .replaceAll(RegExp('[^a-z0-9]+'), '_')
        .replaceAll(RegExp('_+'), '_')
        .replaceAll(RegExp(r'^_|_$'), '');
  }

  static Future<AnalyticsExportResult> exportTextReport({
    required String baseName,
    required String content,
  }) async {
    final exportDirectory = await _exportDirectory();
    final timestamp = _timestamp();
    final safeBaseName = _safeBaseName(baseName);
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

  static Future<Uint8List> buildPdfReport({
    required String title,
    required String content,
  }) async {
    final document = pw.Document();
    final generatedAt = DateTime.now();
    final lines = content.split('\n');

    document.addPage(
      pw.MultiPage(
        pageTheme: pw.PageTheme(
          margin: const pw.EdgeInsets.all(28),
          theme: pw.ThemeData.withFont(
            base: await PdfGoogleFonts.nunitoRegular(),
            bold: await PdfGoogleFonts.nunitoBold(),
          ),
        ),
        build: (context) => [
          pw.Text(
            title,
            style: pw.TextStyle(
              fontSize: 20,
              fontWeight: pw.FontWeight.bold,
            ),
          ),
          pw.SizedBox(height: 6),
          pw.Text(
            'Generated ${generatedAt.toIso8601String()}',
            style: const pw.TextStyle(
              fontSize: 10,
              color: PdfColors.grey700,
            ),
          ),
          pw.SizedBox(height: 16),
          ...lines.map(
            (line) => pw.Padding(
              padding: const pw.EdgeInsets.only(bottom: 6),
              child: pw.Text(
                line.isEmpty ? ' ' : line,
                style: pw.TextStyle(
                  fontSize: line.startsWith('- ') ? 11 : 11.5,
                  fontWeight: line.endsWith(':') && !line.startsWith('- ')
                      ? pw.FontWeight.bold
                      : pw.FontWeight.normal,
                ),
              ),
            ),
          ),
        ],
      ),
    );

    return document.save();
  }

  static Future<AnalyticsExportResult> exportPdfReport({
    required String baseName,
    required String title,
    required String content,
  }) async {
    final exportDirectory = await _exportDirectory();
    final timestamp = _timestamp();
    final safeBaseName = _safeBaseName(baseName);
    final bytes = await buildPdfReport(title: title, content: content);
    final file = File(
      path.join(
        exportDirectory.path,
        '${safeBaseName.isEmpty ? 'analytics_summary' : safeBaseName}_$timestamp.pdf',
      ),
    );
    await file.writeAsBytes(bytes, flush: true);
    return AnalyticsExportResult(filePath: file.path, byteCount: bytes.length);
  }

  static Future<void> sharePdfReport({
    required String title,
    required String content,
  }) async {
    final bytes = await buildPdfReport(title: title, content: content);
    await Printing.sharePdf(bytes: bytes, filename: '$title.pdf');
  }

  static Future<AnalyticsExportResult?> savePdfReportAs({
    required String suggestedBaseName,
    required String title,
    required String content,
  }) async {
    final safeBaseName = _safeBaseName(suggestedBaseName);
    final suggestedName =
        '${safeBaseName.isEmpty ? 'analytics_summary' : safeBaseName}.pdf';
    final location = await getSaveLocation(
      suggestedName: suggestedName,
      acceptedTypeGroups: const [
        XTypeGroup(label: 'PDF document', extensions: ['pdf']),
      ],
    );
    if (location == null) {
      return null;
    }

    final bytes = await buildPdfReport(title: title, content: content);
    final file = File(location.path);
    await file.writeAsBytes(bytes, flush: true);
    return AnalyticsExportResult(filePath: file.path, byteCount: bytes.length);
  }
}
