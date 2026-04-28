import 'package:flutter/material.dart';

import 'providers/app_state.dart';
import 'screens/scan_screen.dart';
import 'sync/sync_engine.dart';

class FSYScannerApp extends StatelessWidget {
  final AppState appState;

  const FSYScannerApp({super.key, required this.appState});

  // Version
  static const String appVersion = '2.0.0';

  // FSY logo brand colors
  static const Color primaryBlue = Color(0xFF045782);
  static const Color accentGreen = Color(0xFFA3C997);
  static const Color accentGold = Color(0xFFF7B550);

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      SyncEngine.startup(appState);
    });

    return MaterialApp(
      title: 'FSY Scanner 2026 v2.0.0',
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
      home: const ScanScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}
