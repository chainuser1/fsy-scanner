import 'dart:convert';

import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;

import '../utils/logger.dart';

class GoogleAuth {
  static String? _cachedToken;
  static DateTime? _tokenExpiry;

  static Future<String?> getValidToken() async {
    if (_cachedToken != null && _tokenExpiry != null) {
      if (DateTime.now().isBefore(_tokenExpiry!)) {
        return _cachedToken;
      }
    }

    final email = dotenv.env['GOOGLE_SERVICE_ACCOUNT_EMAIL'];
    final rawKey = dotenv.env['GOOGLE_SERVICE_ACCOUNT_PRIVATE_KEY'];

    if (email == null || rawKey == null) {
      LoggerUtil.error('[GoogleAuth] Missing service account credentials in .env');
      return null;
    }

    try {
      LoggerUtil.debug('[GoogleAuth] Creating JWT for $email');

      final privateKeyPem = rawKey.replaceAll(r'\n', '\n');

      // Build JWT with the v3 API
      final now = DateTime.now();
      final claims = JsonWebTokenClaims.fromJson({
        'iss': email,
        'sub': email,
        'scope': 'https://www.googleapis.com/auth/spreadsheets',
        'aud': 'https://oauth2.googleapis.com/token',
        'iat': now.millisecondsSinceEpoch ~/ 1000,
        'exp': now.add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000,
      });

      final token = JsonWebTokenHandler()
          .createToken(claims)
          .sign(RsaPrivateKey(privateKeyPem), algorithm: JWTAlgorithm.RS256);

      // Exchange JWT for access token
      final response = await http.post(
        Uri.https('oauth2.googleapis.com', '/token'),
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: {
          'grant_type': 'urn:ietf:params:oauth:grant-type:jwt-bearer',
          'assertion': token,
        },
      );

      if (response.statusCode != 200) {
        LoggerUtil.error('[GoogleAuth] Token exchange failed: ${response.statusCode}');
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

      _cachedToken = accessToken;
      _tokenExpiry = DateTime.now().add(Duration(seconds: expiresIn - 60));

      LoggerUtil.info('[GoogleAuth] Successfully obtained access token');
      return accessToken;
    } catch (e) {
      LoggerUtil.error('[GoogleAuth] Error obtaining access token: $e', error: e);
      _cachedToken = null;
      _tokenExpiry = null;
      return null;
    }
  }
}