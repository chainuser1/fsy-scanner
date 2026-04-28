import 'dart:convert';
import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;

class GoogleAuth {
  static String? _cachedToken;
  static int _expiresAt = 0;

  // Returns a valid Google API access token.
  // Fetches a new one via JWT exchange if expired.
  // Returns null on failure — never throws to caller.
  static Future<String?> getValidToken() async {
    // Return cached token if still valid (60s buffer before expiry)
    if (_cachedToken != null &&
        DateTime.now().millisecondsSinceEpoch < _expiresAt - 60000) {
      return _cachedToken;
    }

    // Read credentials from .env
    final email = dotenv.env['GOOGLE_SERVICE_ACCOUNT_EMAIL'];
    final rawKey = dotenv.env['GOOGLE_SERVICE_ACCOUNT_PRIVATE_KEY'];

    if (email == null || rawKey == null) {
      debugPrint('[GoogleAuth] Missing credentials in .env');
      return null;
    }

    // Replace literal \n with real newlines from .env format
    final privateKey = rawKey.replaceAll(r'\n', '\n');

    try {
      // Build JWT claims for Google token endpoint
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final jwt = JWT({
        'iss': email,
        'scope': 'https://www.googleapis.com/auth/spreadsheets',
        'aud': 'https://oauth2.googleapis.com/token',
        'iat': now,
        'exp': now + 3600,
      });

      // Sign JWT with RS256 using RSA private key (PKCS#8 format)
      final signedJwt = jwt.sign(
        RSAPrivateKey(privateKey),
        algorithm: JWTAlgorithm.RS256,
      );

      // Exchange signed JWT for a Google access token
      final response = await http.post(
        Uri.parse('https://oauth2.googleapis.com/token'),
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: {
          'grant_type': 'urn:ietf:params:oauth:grant-type:jwt-bearer',
          'assertion': signedJwt,
        },
      );

      if (response.statusCode != 200) {
        debugPrint('[GoogleAuth] Token exchange failed '
            '${response.statusCode}: ${response.body}');
        return null;
      }

      // Parse and cache the access token
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final accessToken = data['access_token'] as String?;
      final expiresIn = (data['expires_in'] as num?)?.toInt() ?? 3600;

      if (accessToken == null) {
        debugPrint('[GoogleAuth] Response missing access_token');
        return null;
      }

      _cachedToken = accessToken;
      _expiresAt = DateTime.now().millisecondsSinceEpoch + (expiresIn * 1000);
      debugPrint('[GoogleAuth] Token obtained for $email');
      return _cachedToken;
    } catch (e) {
      debugPrint('[GoogleAuth] Error: $e');
      _cachedToken = null;
      _expiresAt = 0;
      return null;
    }
  }
}