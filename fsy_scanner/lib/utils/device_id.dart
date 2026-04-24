import 'package:uuid/uuid.dart';

class DeviceId {
  static String? _cachedId;

  static Future<String> get() async {
    if (_cachedId != null) {
      return _cachedId!;
    }
 

    // Generate a UUID as the device ID
    _cachedId = const Uuid().v4();
    return _cachedId!;
  }
}