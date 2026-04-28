import 'dart:developer' as developer;
import 'package:logging/logging.dart';

/// Production-safe logging utility that works both in debug and release builds
class LoggerUtil {
  static final Logger _logger = Logger('FSYScanner');

  /// Initialize the logging system
  static void init() {
    Logger.root.level = Level.ALL;

    Logger.root.onRecord.listen((record) {
      developer.log(
        record.message,
        name: record.loggerName,
        error: record.error,
        stackTrace: record.stackTrace,
        level: _convertLevel(record.level),
      );
    });
  }

  /// Convert logging.Level to dart:developer log level
  static int _convertLevel(Level level) {
    if (level <= Level.FINEST) return 200;
    if (level <= Level.FINER) return 250;
    if (level <= Level.FINE) return 300;
    if (level <= Level.CONFIG) return 400;
    if (level <= Level.INFO) return 500;
    if (level <= Level.WARNING) return 600;
    if (level <= Level.SEVERE) return 700;
    return 800;
  }

  static void verbose(String message, {Object? error, StackTrace? stackTrace}) {
    _logger.fine(message, error, stackTrace);
  }

  static void debug(String message, {Object? error, StackTrace? stackTrace}) {
    _logger.info(message, error, stackTrace);
  }

  static void info(String message, {Object? error, StackTrace? stackTrace}) {
    _logger.info(message, error, stackTrace);
  }

  static void warn(String message, {Object? error, StackTrace? stackTrace}) {
    _logger.warning(message, error, stackTrace);
  }

  static void error(String message, {Object? error, StackTrace? stackTrace}) {
    _logger.severe(message, error, stackTrace);
  }

  static void networkRequest(String method, String url, {int? statusCode, Object? error}) {
    final status = statusCode != null ? ' ($statusCode)' : '';
    final errorMsg = error != null ? ' Error: $error' : '';
    _logger.info('Network: $method $url$status$errorMsg');
  }
}