import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'providers/app_state.dart';
import 'screens/scan_screen.dart';
import 'sync/sync_engine.dart';

class FSYScannerApp extends StatelessWidget {
  const FSYScannerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (context) => AppState()
        ..startup(), // Initialize the app state and kick off sync engine
      child: MaterialApp(
        title: 'FSY Scanner',
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
          useMaterial3: true,
        ),
        home: const ScanScreen(), // Main screen is the scanner
        debugShowCheckedModeBanner: false,
      ),
    );
  }
}

extension AppStateExtension on AppState {
  void startup() {
    // Start the sync engine with this instance of AppState
    SyncEngine.startup(this);
  }
}