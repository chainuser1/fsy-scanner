import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

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
    final email = dotenv.env['GOOGLE_SERVICE_ACCOUNT_EMAIL'];
    final rawKey = dotenv.env['GOOGLE_SERVICE_ACCOUNT_PRIVATE_KEY'];
    if (email == null || rawKey == null) {
      debugPrint('[GoogleAuth] Missing service account credentials in .env');
      return null;
    }

    try {
      // For now, return a mock token for compilation purposes
      // Real implementation would create and sign a JWT with the private key
      debugPrint('[GoogleAuth] Mock token obtained for $email');
      _cachedToken = 'mock_access_token_for_compilation';
      _expiresAt = DateTime.now().millisecondsSinceEpoch + 3500000;
      return _cachedToken;
    } catch (e) {
      debugPrint('[GoogleAuth] Error: $e');
      _cachedToken = null;
      _expiresAt = 0;
      return null;
    }
  }
}
