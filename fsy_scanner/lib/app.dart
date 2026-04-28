import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'providers/app_state.dart';
import 'screens/scan_screen.dart';
import 'sync/sync_engine.dart';

class FSYScannerApp extends StatelessWidget {
  final AppState appState;
  
  const FSYScannerApp({super.key, required this.appState});

  @override
  Widget build(BuildContext context) {
    // Start sync engine after first frame to ensure context is ready
    WidgetsBinding.instance.addPostFrameCallback((_) {
      SyncEngine.startup(appState);
    });
    
    return MaterialApp(
      title: 'FSY Scanner',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const ScanScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}