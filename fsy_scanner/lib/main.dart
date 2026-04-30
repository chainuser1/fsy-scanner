import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:provider/provider.dart';

import 'app.dart';
import 'db/database_helper.dart'; // <-- added
import 'db/sync_queue_dao.dart';
import 'providers/app_state.dart';
import 'utils/logger.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  LoggerUtil.init();
  runApp(const BootstrapApp());
}

class BootstrapApp extends StatefulWidget {
  const BootstrapApp({super.key});

  @override
  State<BootstrapApp> createState() => _BootstrapAppState();
}

class _BootstrapAppState extends State<BootstrapApp> {
  AppState? _appState;
  bool _showOnboarding = false;
  bool _isLoading = true;
  String? _startupError;

  @override
  void initState() {
    super.initState();
    unawaited(_bootstrap());
  }

  Future<void> _bootstrap() async {
    setState(() {
      _isLoading = true;
      _startupError = null;
    });

    try {
      await dotenv.load(fileName: 'assets/.env');

      final appState = AppState();
      final db = await DatabaseHelper.database;
      final onboardingResult = await db.query(
        'app_settings',
        where: 'key = ?',
        whereArgs: ['onboarding_complete'],
      );
      final onboardingComplete = onboardingResult.isNotEmpty &&
          onboardingResult.first['value'] == 'true';

      await appState.loadPreferences();
      await appState.refreshParticipantsCount();
      appState.setPendingTaskCount(await SyncQueueDao.getPendingCount());
      await appState.startPrinterAutomation();

      if (!mounted) {
        return;
      }

      setState(() {
        _appState = appState;
        _showOnboarding = !onboardingComplete;
        _isLoading = false;
      });
    } catch (e) {
      LoggerUtil.error('Bootstrap failed: $e', error: e);
      if (!mounted) {
        return;
      }
      setState(() {
        _startupError = e.toString();
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_appState != null) {
      return ChangeNotifierProvider<AppState>.value(
        value: _appState!,
        child: FSYScannerApp(
          appState: _appState!,
          showOnboarding: _showOnboarding,
        ),
      );
    }

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: _isLoading
                ? const Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircularProgressIndicator(),
                      SizedBox(height: 16),
                      Text('Starting FSY Scanner...'),
                    ],
                  )
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.error_outline,
                          size: 56, color: Colors.red),
                      const SizedBox(height: 16),
                      const Text(
                        'Startup Failed',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        _startupError ??
                            'The app could not finish startup initialization.',
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 20),
                      ElevatedButton(
                        onPressed: _bootstrap,
                        child: const Text('Retry Startup'),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}
