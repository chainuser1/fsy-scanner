import 'package:flutter/material.dart';

import 'providers/app_state.dart';
import 'screens/onboarding_screen.dart';
import 'screens/scan_screen.dart';
import 'sync/sync_engine.dart';

class FSYScannerApp extends StatelessWidget {
  final AppState appState;
  final bool showOnboarding;
  // static const String appName = 'FSY 2026 Tacloban & Tolosa';

  const FSYScannerApp({
    super.key,
    required this.appState,
    this.showOnboarding = false,
  });

  static const Color primaryBlue = Color(0xFF045782);
  static const Color accentGreen = Color(0xFFA3C997);
  static const Color accentGold = Color(0xFFF7B550);

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      SyncEngine.startup(appState);
    });

    return MaterialApp(
      title: 'FSY Scanner',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: primaryBlue,
          primary: primaryBlue,
          secondary: accentGreen,
          tertiary: accentGold,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: primaryBlue,
          foregroundColor: Colors.white,
          elevation: 2,
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: primaryBlue,
            foregroundColor: Colors.white,
          ),
        ),
        useMaterial3: true,
      ),
      home: showOnboarding ? const OnboardingScreen() : const ScanScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}
