import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_thermal_printer/utils/printer.dart';
import 'package:provider/provider.dart';
import 'package:sqflite/sqflite.dart';

import '../app.dart';
import '../auth/google_auth.dart';
import '../db/database_helper.dart';
import '../models/participant.dart';
import '../print/printer_service.dart';
import '../providers/app_state.dart';
import '../sync/sheets_api.dart';
import '../sync/sync_engine.dart';
import '../utils/device_id.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late StreamSubscription<bool> _syncStatusSubscription;
  final _sheetIdController = TextEditingController();
  final _tabNameController = TextEditingController();
  final _eventNameController = TextEditingController();

  List<Printer> _discoveredPrinters = [];
  bool _isScanningPrinters = false;
  bool _isSyncing = false;
  String? _selectedPrinterAddress;

  @override
  void initState() {
    super.initState();
    _syncStatusSubscription = SyncEngine.syncStatusStream.listen((isSyncing) {
      if (mounted) {
        setState(() => _isSyncing = isSyncing);
      }
    });
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final db = await DatabaseHelper.database;
    final settings = await db.query('app_settings');

    for (final setting in settings) {
      final key = setting['key'] as String;
      final value = setting['value'] as String?;
      if (value == null) continue;

      if (key == 'sheets_id') _sheetIdController.text = value;
      if (key == 'sheets_tab') _tabNameController.text = value;
      if (key == 'event_name') _eventNameController.text = value;
      if (key == 'printer_address') _selectedPrinterAddress = value;
    }
    setState(() {});
  }

  Future<bool> _getSoundEnabled() async {
    final db = await DatabaseHelper.database;
    final result = await db.query('app_settings',
        where: 'key = ?', whereArgs: ['sound_enabled']);
    if (result.isEmpty) return true;
    return result.first['value'] != 'false';
  }

  Future<void> _setSoundEnabled(bool enabled) async {
    final db = await DatabaseHelper.database;
    await db.insert(
        'app_settings', {'key': 'sound_enabled', 'value': enabled.toString()},
        conflictAlgorithm: ConflictAlgorithm.replace);
    setState(() {});
  }

  String? _validateSheetId(String? value) {
    if (value == null || value.isEmpty) return 'Sheet ID cannot be empty';
    if (value.length < 20) return 'Sheet ID appears to be too short';
    if (!RegExp(r'^[-_A-Za-z0-9]+$').hasMatch(value)) {
      return 'Invalid Sheet ID format';
    }
    return null;
  }

  String? _validateTabName(String? value) {
    if (value == null || value.isEmpty) return 'Tab name cannot be empty';
    if (value.length > 100) return 'Tab name is too long';
    if (value.contains('/') ||
        value.contains(r'\') ||
        value.contains('*') ||
        value.contains('[') ||
        value.contains(']')) {
      return 'Tab name contains invalid characters';
    }
    return null;
  }

  String? _validateEventName(String? value) {
    if (value == null || value.isEmpty) return 'Event name cannot be empty';
    if (value.length > 100) return 'Event name is too long';
    return null;
  }

  Future<void> _saveSheetSettings() async {
    final sheetIdError = _validateSheetId(_sheetIdController.text);
    final tabNameError = _validateTabName(_tabNameController.text);
    final eventNameError = _validateEventName(_eventNameController.text);

    if (sheetIdError != null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(sheetIdError), backgroundColor: Colors.red));
      }
      return;
    }
    if (tabNameError != null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(tabNameError), backgroundColor: Colors.red));
      }
      return;
    }
    if (eventNameError != null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(eventNameError), backgroundColor: Colors.red));
      }
      return;
    }

    final db = await DatabaseHelper.database;
    await db.insert(
        'app_settings', {'key': 'sheets_id', 'value': _sheetIdController.text},
        conflictAlgorithm: ConflictAlgorithm.replace);
    await db.insert(
        'app_settings', {'key': 'sheets_tab', 'value': _tabNameController.text},
        conflictAlgorithm: ConflictAlgorithm.replace);
    await db.insert('app_settings',
        {'key': 'event_name', 'value': _eventNameController.text},
        conflictAlgorithm: ConflictAlgorithm.replace);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Settings saved'), backgroundColor: Colors.green));
    }

    try {
      final token = await GoogleAuth.getValidToken();
      if (token != null) {
        await SheetsApi.detectColMap(
            db, token, _sheetIdController.text, _tabNameController.text);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text('Columns detected successfully'),
              backgroundColor: Colors.green));
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Column detection failed: $e'),
            backgroundColor: Colors.red));
      }
    }
  }

  Future<void> _resetToDefaults() async {
    final db = await DatabaseHelper.database;
    await db.delete('app_settings', where: 'key = ?', whereArgs: ['sheets_id']);
    await db.delete('app_settings', where: 'key = ?', whereArgs: ['sheets_tab']);
    await db.delete('app_settings', where: 'key = ?', whereArgs: ['event_name']);

    final settingsToSeed = {
      'sheets_id': dotenv.env['SHEETS_ID'],
      'sheets_tab': dotenv.env['SHEETS_TAB'],
      'event_name': dotenv.env['EVENT_NAME'],
    };
    for (final entry in settingsToSeed.entries) {
      if (entry.value != null) {
        await db.insert(
          'app_settings',
          {'key': entry.key, 'value': entry.value},
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
      }
    }

    await _loadSettings();

    try {
      final token = await GoogleAuth.getValidToken();
      if (token != null && mounted) {
        await SheetsApi.detectColMap(
            db, token, _sheetIdController.text, _tabNameController.text);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text('Defaults restored and columns detected'),
              backgroundColor: Colors.green));
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Restored defaults but column detection failed: $e'),
            backgroundColor: Colors.red));
      }
    }
  }

  Future<void> _scanPrinters() async {
    setState(() => _isScanningPrinters = true);
    final printers = await PrinterService.scanPrinters();
    setState(() {
      _discoveredPrinters = printers;
      _isScanningPrinters = false;
    });
  }

  Future<void> _selectPrinter(Printer printer) async {
    final db = await DatabaseHelper.database;
    await db.insert(
        'app_settings', {'key': 'printer_address', 'value': printer.address},
        conflictAlgorithm: ConflictAlgorithm.replace);
    setState(() => _selectedPrinterAddress = printer.address);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Printer ${printer.name} selected')));
    }
  }

  Future<void> _testPrint() async {
    final deviceId = await DeviceId.get();
    final mockParticipant = Participant(
      id: 'TEST-001',
      fullName: 'Test Participant',
      sheetsRow: 0,
    );
    final success =
        await PrinterService.printReceipt(mockParticipant, deviceId);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(success ? 'Test print sent' : 'Test print failed'),
          backgroundColor: success ? Colors.green : Colors.red,
        ),
      );
    }
  }

  Future<void> _startFullSync() async {
    final appState = Provider.of<AppState>(context, listen: false);
    await SyncEngine.performFullSync(appState);
  }

  Future<void> _startPullOnlySync() async {
    final appState = Provider.of<AppState>(context, listen: false);
    await SyncEngine.performPullSync(appState);
  }

  Future<void> _clearAllData(BuildContext context, AppState appState) async {
    final confirmed = await _showConfirmationDialog(context);
    if (confirmed == true && mounted) {
      await appState.clearAllData();
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('All data cleared')));
      }
    }
  }

  Future<bool> _showConfirmationDialog(BuildContext context) async {
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Confirm'),
            content: const Text(
                'Are you sure you want to clear all participant data? This cannot be undone.'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Yes, Clear All'),
              ),
            ],
          ),
        ) ??
        false;
  }

  @override
  void dispose() {
    _syncStatusSubscription.cancel();
    _sheetIdController.dispose();
    _tabNameController.dispose();
    _eventNameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final appState = Provider.of<AppState>(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16.0),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Sheet Configuration',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _sheetIdController,
                    decoration: const InputDecoration(
                      labelText: 'Google Sheet ID',
                      hintText: 'Enter your Google Sheet ID',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _tabNameController,
                    decoration: const InputDecoration(
                      labelText: 'Tab Name',
                      hintText: 'Enter the tab name',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _eventNameController,
                    decoration: const InputDecoration(
                      labelText: 'Event Name',
                      hintText: 'Enter the event name',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: ElevatedButton(
                          onPressed: _saveSheetSettings,
                          child: const Text('Save & Detect Columns'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton.icon(
                        onPressed: _resetToDefaults,
                        icon: const Icon(Icons.restore),
                        label: const Text('Reset to defaults'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Printer Settings',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: ElevatedButton(
                          onPressed: _isScanningPrinters ? null : _scanPrinters,
                          child: Text(_isScanningPrinters
                              ? 'Scanning...'
                              : 'Scan for Printers'),
                        ),
                      ),
                      const SizedBox(width: 16),
                      ElevatedButton(
                        onPressed:
                            _selectedPrinterAddress != null ? _testPrint : null,
                        child: const Text('Test Print'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  if (_discoveredPrinters.isNotEmpty)
                    ListView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: _discoveredPrinters.length,
                      itemBuilder: (context, index) {
                        final printer = _discoveredPrinters[index];
                        final isSelected =
                            _selectedPrinterAddress == printer.address;
                        return ListTile(
                          title: Text(printer.name ?? 'Unknown Printer'),
                          subtitle: Text(printer.address ?? ''),
                          trailing: isSelected
                              ? const Icon(Icons.check_circle,
                                  color: Colors.green)
                              : null,
                          onTap: () => _selectPrinter(printer),
                        );
                      },
                    )
                  else if (!_isScanningPrinters)
                    const Text(
                        'No printers found. Make sure Bluetooth is on and printer is discoverable.'),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Device Info',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  FutureBuilder<String>(
                    future: DeviceId.get(),
                    builder: (context, snapshot) {
                      if (snapshot.hasData) {
                        return Text('ID: ${snapshot.data!}');
                      } else {
                        return const Text('Loading device ID...');
                      }
                    },
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Notification Sounds',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  FutureBuilder<bool>(
                    future: _getSoundEnabled(),
                    builder: (context, snapshot) {
                      final enabled = snapshot.data ?? true;
                      return Switch(
                        value: enabled,
                        onChanged: (value) => _setSoundEnabled(value),
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Sync Status',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  Text(_isSyncing ? 'Syncing...' : 'Ready'),
                  const SizedBox(height: 4),
                  Consumer<AppState>(
                    builder: (context, state, _) {
                      final last = state.lastSyncedAt;
                      if (last == null) return const Text('Never synced');
                      final secondsAgo = DateTime.now().difference(last).inSeconds;
                      final display = secondsAgo < 60
                          ? 'just now'
                          : secondsAgo < 120
                              ? '1 min ago'
                              : '${secondsAgo ~/ 60} mins ago';
                      return Text('Last sync: $display',
                          style: const TextStyle(color: Colors.grey));
                    },
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: ElevatedButton(
                          onPressed: _isSyncing ? null : _startFullSync,
                          child: const Text('Full Sync'),
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: ElevatedButton(
                          onPressed: _isSyncing ? null : _startPullOnlySync,
                          child: const Text('Pull Data'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Registration Data',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  Text('${appState.participantsCount} participants checked in'),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: ElevatedButton(
                          onPressed: () => _clearAllData(context, appState),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.red,
                            foregroundColor: Colors.white,
                          ),
                          child: const Text('Clear All Data'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}