import 'dart:convert';

import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;

import '../db/database_helper.dart';
import '../utils/logger.dart';

class GoogleAuth {
  static String? _cachedToken;
  static DateTime? _tokenExpiry;

  /// Get a valid OAuth2 access token.
  /// Credentials are resolved in this order:
  /// 1. From the [app_settings] DB table (user-configured in Advanced Settings)
  /// 2. From the `.env` file (build-time default)
  static Future<String?> getValidToken() async {
    // Check if we have a valid cached token (with 60-second buffer)
    if (_cachedToken != null && _tokenExpiry != null) {
      if (DateTime.now().isBefore(_tokenExpiry!)) {
        return _cachedToken;
      }
    }

    // Resolve credentials: DB first, then .env fallback
    final credentials = await _resolveCredentials();

    if (credentials == null) {
      LoggerUtil.error(
        '[GoogleAuth] Missing service account credentials. '
        'Set them in Settings → Advanced Settings → Google Service Account, '
        'or provide them in the .env file at build time.',
      );
      return null;
    }

    return _exchangeToken(credentials.$1, credentials.$2);
  }

  /// Exchange credentials for a token (exposed for "Test Connection" use).
  static Future<GoogleAuthTestResult> testCredentials({
    required String email,
    required String privateKey,
  }) async {
    try {
      final token = await _exchangeToken(email, privateKey);
      if (token != null) {
        return GoogleAuthTestResult(
          success: true,
          message: 'Connection successful! Token obtained.',
        );
      }
      return GoogleAuthTestResult(
        success: false,
        message:
            'Token exchange failed. Check that the email and private key are correct and the service account has been granted access to the sheet.',
      );
    } catch (e) {
      return GoogleAuthTestResult(
        success: false,
        message: 'Error: $e',
      );
    }
  }

  /// Resolve credentials: DB app_settings first, then .env fallback.
  static Future<(String email, String privateKey)?>
      _resolveCredentials() async {
    try {
      final db = await DatabaseHelper.database;

      final emailResult = await db.query(
        'app_settings',
        where: 'key = ?',
        whereArgs: ['google_service_account_email'],
      );
      final keyResult = await db.query(
        'app_settings',
        where: 'key = ?',
        whereArgs: ['google_service_account_private_key'],
      );

      final dbEmail =
          emailResult.isNotEmpty ? emailResult.first['value'] as String? : null;
      final dbKey =
          keyResult.isNotEmpty ? keyResult.first['value'] as String? : null;

      if (dbEmail != null &&
          dbEmail.isNotEmpty &&
          dbKey != null &&
          dbKey.isNotEmpty) {
        LoggerUtil.debug(
          '[GoogleAuth] Using DB-stored credentials for $dbEmail',
        );
        return (dbEmail, dbKey);
      }
    } catch (e) {
      LoggerUtil.warn(
        '[GoogleAuth] Could not read credentials from DB: $e',
      );
    }

    // Fallback to .env
    final envEmail = dotenv.env['GOOGLE_SERVICE_ACCOUNT_EMAIL'];
    final envKey = dotenv.env['GOOGLE_SERVICE_ACCOUNT_PRIVATE_KEY'];

    if (envEmail != null &&
        envEmail.isNotEmpty &&
        envKey != null &&
        envKey.isNotEmpty) {
      LoggerUtil.debug('[GoogleAuth] Using .env credentials for $envEmail');
      return (envEmail, envKey);
    }

    return null;
  }

  /// Core token exchange logic (used by both getValidToken and testCredentials).
  static Future<String?> _exchangeToken(
    String email,
    String rawKey,
  ) async {
    try {
      LoggerUtil.debug('[GoogleAuth] Creating JWT for $email');

      // Replace literal \n with real newlines in private key
      final privateKeyPem = rawKey.replaceAll(r'\n', '\n');

      // Create JWT payload
      final now = DateTime.now();
      final jwt = JWT({
        'iss': email,
        'sub': email,
        'scope': 'https://www.googleapis.com/auth/spreadsheets',
        'aud': 'https://oauth2.googleapis.com/token',
        'iat': now.millisecondsSinceEpoch ~/ 1000,
        'exp': now.add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000,
      });

      // Sign with RS256
      final signedToken = jwt.sign(
        RSAPrivateKey(privateKeyPem),
        algorithm: JWTAlgorithm.RS256,
      );

      // Exchange JWT for OAuth2 access token
      final response = await http.post(
        Uri.https('oauth2.googleapis.com', '/token'),
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: {
          'grant_type': 'urn:ietf:params:oauth:grant-type:jwt-bearer',
          'assertion': signedToken,
        },
      );

      if (response.statusCode != 200) {
        LoggerUtil.error(
          '[GoogleAuth] Token exchange failed: ${response.statusCode}',
        );
        debugPrint('[GoogleAuth] Response: ${response.body}');
        return null;
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final accessToken = data['access_token'] as String?;
      final expiresIn = data['expires_in'] as int?;

      if (accessToken == null || expiresIn == null) {
        LoggerUtil.error('[GoogleAuth] Invalid response from token endpoint');
        return null;
      }

      // Cache token with 60-second early expiry
      _cachedToken = accessToken;
      _tokenExpiry = DateTime.now().add(Duration(seconds: expiresIn - 60));

      LoggerUtil.info('[GoogleAuth] Successfully obtained access token');
      return accessToken;
    } catch (e) {
      LoggerUtil.error(
        '[GoogleAuth] Error obtaining access token: $e',
        error: e,
      );
      _cachedToken = null;
      _tokenExpiry = null;
      return null;
    }
  }

  /// Invalidate cached token (e.g. after credential change).
  static void invalidateCache() {
    _cachedToken = null;
    _tokenExpiry = null;
  }
}

/// Result of a test-credentials attempt.
class GoogleAuthTestResult {
  final bool success;
  final String message;
  GoogleAuthTestResult({required this.success, required this.message});
}
