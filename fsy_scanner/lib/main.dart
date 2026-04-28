import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:provider/provider.dart';

import 'app.dart';
import 'providers/app_state.dart';
import 'screens/onboarding_screen.dart';
import 'utils/logger.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  LoggerUtil.init();
  await dotenv.load(fileName: 'assets/.env');

  final appState = AppState();
  // Check if onboarding has been completed
  final db = await DatabaseHelper.database;
  final onboardingResult = await db.query('app_settings',
      where: 'key = ?', whereArgs: ['onboarding_complete']);
  final onboardingComplete =
      onboardingResult.isNotEmpty && onboardingResult.first['value'] == 'true';

  runApp(
    ChangeNotifierProvider<AppState>.value(
      value: appState,
      child: FSYScannerApp(
          appState: appState, showOnboarding: !onboardingComplete),
    ),
  );
}
