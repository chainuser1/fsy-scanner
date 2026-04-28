import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:provider/provider.dart';

import 'app.dart';
import 'providers/app_state.dart';
import 'utils/logger.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize logging system
  LoggerUtil.init();

  // Load environment variables
  await dotenv.load(fileName: 'assets/.env');

  // Create single AppState instance
  final appState = AppState();

  runApp(
    ChangeNotifierProvider<AppState>.value(
      value: appState,
      child: FSYScannerApp(appState: appState),
    ),
  );
}
