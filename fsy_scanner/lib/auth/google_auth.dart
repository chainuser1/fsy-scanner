import 'dart:convert';
import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;

class GoogleAuth {
  static String? _cachedToken;
  static int _expiresAt = 0;

  // Returns valid access token. Fetches new one if expired.
  // Returns null on failure — never throws to caller.
  static Future<String?> getValidToken() async {
    // 1. Return cached token if still valid (60s buffer)
    if (_cachedToken != null && DateTime.now().millisecondsSinceEpoch < _expiresAt - 60000) {
      return _cachedToken;
    }
 

    // 2. Read credentials from .env
    await dotenv.load(fileName: 'assets/.env');
    final email = dotenv.env['GOOGLE_SERVICE_ACCOUNT_EMAIL'];
    final rawKey = dotenv.env['GOOGLE_SERVICE_ACCOUNT_PRIVATE_KEY'];
    
    if (email == null || rawKey == null) {
      debugPrint('[GoogleAuth] Missing service account credentials in .env');
      return null;
    }

    // 3. Replace literal \n with real newlines
    final privateKey = rawKey.replaceAll(r'\n', '\n');

    try {
      // 4. Build and sign JWT using dart_jsonwebtoken RS256
      final jwt = JWT({
        'iss': email,
        'scope': 'https://www.googleapis.com/auth/spreadsheets',
        'aud': 'https://oauth2.googleapis.com/token',
        'exp': (DateTime.now().millisecondsSinceEpoch ~/ 1000) + 3600,
        'iat': DateTime.now().millisecondsSinceEpoch ~/ 1000,
      });
      
      final signedJwt = jwt.sign(RSAPrivateKey(privateKey), algorithm: JWTAlgorithm.RS256);

      // 5. Exchange JWT for access token
      final response = await http.post(
        Uri.parse('https://oauth2.googleapis.com/token'),
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: {
          'grant_type': 'urn:ietf:params:oauth:grant-type:jwt-bearer',
          'assertion': signedJwt,
        },
      );

      if (response.statusCode != 200) {
        debugPrint('[GoogleAuth] Token exchange failed ${response.statusCode}: ${response.body}');
        return null;
      }

      // 6. Cache and return token
      final Map<String, dynamic> data = jsonDecode(response.body) as Map<String, dynamic>;
      final String? accessToken = data['access_token'] as String?;
      if (accessToken == null) {
        debugPrint('[GoogleAuth] Access token not found in response');
        return null;
      }
      _cachedToken = accessToken;
      _expiresAt = DateTime.now().millisecondsSinceEpoch + 3500000; // ~58 minutes
      
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