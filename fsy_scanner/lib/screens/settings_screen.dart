import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_thermal_printer/utils/printer.dart';
import 'package:provider/provider.dart';
import 'package:sqflite/sqflite.dart';

import '../auth/google_auth.dart';
import '../db/database_helper.dart';
import '../db/participants_dao.dart';
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
  late StreamSubscription<Map<String, dynamic>> _syncStatusSubscription;
  final _sheetIdController = TextEditingController();
  final _tabNameController = TextEditingController();
  final _eventNameController = TextEditingController();
  final _profileNameController = TextEditingController();

  List<Printer> _discoveredPrinters = [];
  bool _isScanningPrinters = false;
  bool _isSyncing = false;
  String? _selectedPrinterAddress;
  String _printerStatus = 'Unknown';

  @override
  void initState() {
    super.initState();
    _syncStatusSubscription = SyncEngine.syncStatusStream.listen((data) {
      if (mounted) {
        setState(() {
          _isSyncing = data['syncing'] as bool? ?? false;
        });
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
      if (value == null) {
        continue;
      }

      if (key == 'sheets_id') {
        _sheetIdController.text = value;
      }
      if (key == 'sheets_tab') {
        _tabNameController.text = value;
      }
      if (key == 'event_name') {
        _eventNameController.text = value;
      }
      if (key == 'printer_address') {
        _selectedPrinterAddress = value;
      }
    }
    setState(() {});
  }

  // ─── Profiles ──────────────────────────────────────────────
  Future<void> _saveCurrentAsProfile() async {
    final name = _profileNameController.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a profile name')),
      );
      return;
    }
    final appState = context.read<AppState>();
    await appState.saveProfile(
      name,
      _sheetIdController.text,
      _tabNameController.text,
      _eventNameController.text,
    );
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Profile "$name" saved')),
    );
    _profileNameController.clear();
    setState(() {});
  }

  Future<void> _loadProfile(int id) async {
    final appState = context.read<AppState>();
    await appState.loadProfile(id);
    await _loadSettings();
    try {
      final token = await GoogleAuth.getValidToken();
      if (token != null) {
        final db = await DatabaseHelper.database;
        await SheetsApi.detectColMap(
          db,
          token,
          _sheetIdController.text,
          _tabNameController.text,
        );
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Profile loaded and columns detected'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Column detection failed: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  // ─── Printer Diagnostics ───────────────────────────────────
  Future<void> _checkPrinterStatus() async {
    try {
      final db = await DatabaseHelper.database;
      final result = await db.query(
        'app_settings',
        where: 'key = ?',
        whereArgs: ['printer_address'],
      );
      if (result.isEmpty) {
        setState(() => _printerStatus = 'No printer selected');
        return;
      }
      final address = result.first['value'] as String;
      setState(() => _printerStatus = 'Address: $address');
      await PrinterService.scanPrinters();
      setState(() => _printerStatus =
          'Scanned. If your printer is on and in range, it should appear.');
    } catch (e) {
      setState(() => _printerStatus = 'Error: $e');
    }
  }

  // ─── Data Export ───────────────────────────────────────────
  Future<void> _exportCSV() async {
    try {
      final db = await DatabaseHelper.database;
      final dao = ParticipantsDao(db);
      final participants = await dao.getAllParticipants();
      final buffer = StringBuffer();
      buffer.writeln(
        'ID,Name,Stake,Ward,Room,Table,Shirt,Medical,Note,Verified At,Printed At,Device ID',
      );
      for (final p in participants) {
        buffer.writeln(
          '${p.id},"${p.fullName}","${p.stake ?? ''}","${p.ward ?? ''}","${p.roomNumber ?? ''}","${p.tableNumber ?? ''}","${p.tshirtSize ?? ''}","${p.medicalInfo ?? ''}","${p.note ?? ''}",${p.verifiedAt ?? ''},${p.printedAt ?? ''},${p.registeredBy ?? ''}',
        );
      }
      final dir = Directory('/storage/emulated/0/Download');
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      final file = File('${dir.path}/fsy_participants.csv');
      await file.writeAsString(buffer.toString());
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Exported to ${file.path}')),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Export failed: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  // ─── Validation ────────────────────────────────────────────
  String? _validateSheetId(String? value) {
    if (value == null || value.isEmpty) {
      return 'Sheet ID cannot be empty';
    }
    if (value.length < 20) {
      return 'Sheet ID appears to be too short';
    }
    if (!RegExp(r'^[-_A-Za-z0-9]+$').hasMatch(value)) {
      return 'Invalid Sheet ID format';
    }
    return null;
  }

  String? _validateTabName(String? value) {
    if (value == null || value.isEmpty) {
      return 'Tab name cannot be empty';
    }
    if (value.length > 100) {
      return 'Tab name is too long';
    }
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
    if (value == null || value.isEmpty) {
      return 'Event name cannot be empty';
    }
    if (value.length > 100) {
      return 'Event name is too long';
    }
    return null;
  }

  Future<void> _saveSheetSettings() async {
    final sheetIdError = _validateSheetId(_sheetIdController.text);
    final tabNameError = _validateTabName(_tabNameController.text);
    final eventNameError = _validateEventName(_eventNameController.text);

    if (sheetIdError != null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(sheetIdError), backgroundColor: Colors.red),
        );
      }
      return;
    }
    if (tabNameError != null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tabNameError), backgroundColor: Colors.red),
        );
      }
      return;
    }
    if (eventNameError != null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(eventNameError), backgroundColor: Colors.red),
        );
      }
      return;
    }

    final db = await DatabaseHelper.database;
    await db.insert(
      'app_settings',
      {'key': 'sheets_id', 'value': _sheetIdController.text},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    await db.insert(
      'app_settings',
      {'key': 'sheets_tab', 'value': _tabNameController.text},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    await db.insert(
      'app_settings',
      {'key': 'event_name', 'value': _eventNameController.text},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Settings saved'),
          backgroundColor: Colors.green,
        ),
      );
    }

    try {
      final token = await GoogleAuth.getValidToken();
      if (token != null) {
        await SheetsApi.detectColMap(
          db,
          token,
          _sheetIdController.text,
          _tabNameController.text,
        );
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Columns detected successfully'),
              backgroundColor: Colors.green,
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Column detection failed: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _resetToDefaults() async {
    final db = await DatabaseHelper.database;
    await db.delete('app_settings', where: 'key = ?', whereArgs: ['sheets_id']);
    await db
        .delete('app_settings', where: 'key = ?', whereArgs: ['sheets_tab']);
    await db
        .delete('app_settings', where: 'key = ?', whereArgs: ['event_name']);

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
          db,
          token,
          _sheetIdController.text,
          _tabNameController.text,
        );
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Defaults restored and columns detected'),
              backgroundColor: Colors.green,
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Restored defaults but column detection failed: $e'),
            backgroundColor: Colors.red,
          ),
        );
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
      'app_settings',
      {'key': 'printer_address', 'value': printer.address},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    setState(() => _selectedPrinterAddress = printer.address);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Printer ${printer.name} selected')),
      );
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

  Future<void> _retryFailedPrints() async {
    final count = PrinterService.failedJobCount;
    if (count == 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No failed prints to retry')),
      );
      return;
    }
    final success = await PrinterService.retryFailedPrints();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Retried $count jobs, $success succeeded')),
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
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('All data cleared')),
        );
      }
    }
  }

  Future<bool> _showConfirmationDialog(BuildContext context) async {
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Confirm'),
            content: const Text(
              'Are you sure you want to clear all participant data? This cannot be undone.',
            ),
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
    _profileNameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final appState = Provider.of<AppState>(context);
    final profilesFuture = appState.getProfiles();

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(16.0),
        children: [
          // ── Event Profiles ──────────────────────
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Event Profiles',
                      style:
                          TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  FutureBuilder<List<Map<String, dynamic>>>(
                    future: profilesFuture,
                    builder: (context, snapshot) {
                      if (!snapshot.hasData) {
                        return const CircularProgressIndicator();
                      }
                      final profiles = snapshot.data!;
                      return Column(
                        children: [
                          for (final p in profiles)
                            ListTile(
                              title: Text(p['name'] as String),
                              subtitle: Text('${p['event_name'] ?? ''}'),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    icon: const Icon(Icons.check,
                                        color: Colors.green),
                                    tooltip: 'Load',
                                    onPressed: () =>
                                        _loadProfile(p['id'] as int),
                                  ),
                                  IconButton(
                                    icon: const Icon(Icons.delete,
                                        color: Colors.red),
                                    onPressed: () =>
                                        appState.deleteProfile(p['id'] as int),
                                  ),
                                ],
                              ),
                            ),
                          const SizedBox(height: 8),
                          TextField(
                            controller: _profileNameController,
                            decoration: const InputDecoration(
                              labelText: 'Profile name',
                              border: OutlineInputBorder(),
                            ),
                          ),
                          const SizedBox(height: 8),
                          ElevatedButton.icon(
                            onPressed: _saveCurrentAsProfile,
                            icon: const Icon(Icons.save),
                            label: const Text('Save Current as Profile'),
                          ),
                        ],
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // ── Sheet Configuration ─────────────────
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Sheet Configuration',
                      style:
                          TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
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
                        label: const Text('Reset to default'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // ── Printer Settings + Diagnostics ───────
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Printer Settings',
                      style:
                          TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
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
                  const SizedBox(height: 8),
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
                    ),
                  const SizedBox(height: 8),
                  Text('Status: $_printerStatus'),
                  const SizedBox(height: 8),
                  ElevatedButton(
                    onPressed: _checkPrinterStatus,
                    child: const Text('Check Printer Status'),
                  ),
                  const SizedBox(height: 8),
                  ElevatedButton.icon(
                    onPressed: _retryFailedPrints,
                    icon: const Icon(Icons.replay),
                    label: Text(
                        'Retry Failed Prints (${PrinterService.failedJobCount})'),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // ── Data Export ─────────────────────────
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Data Export',
                      style:
                          TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  ElevatedButton.icon(
                    onPressed: _exportCSV,
                    icon: const Icon(Icons.download),
                    label: const Text('Export Participants CSV'),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // ── Device Info ─────────────────────────
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Device Info',
                      style:
                          TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  FutureBuilder<String>(
                    future: DeviceId.get(),
                    builder: (context, snapshot) => snapshot.hasData
                        ? Text('ID: ${snapshot.data!}')
                        : const Text('Loading device ID...'),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // ── Sound, Haptics & Voice ──────────────
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Feedback',
                      style:
                          TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  SwitchListTile(
                    title: const Text('Notification Sounds'),
                    value: appState.soundEnabled,
                    onChanged: appState.setSoundEnabled,
                  ),
                  SwitchListTile(
                    title: const Text('Vibration Feedback'),
                    value: appState.hapticEnabled,
                    onChanged: appState.setHapticEnabled,
                  ),
                  SwitchListTile(
                    title: const Text('Voice Feedback (TTS)'),
                    subtitle:
                        const Text('Speak participant name after check‑in'),
                    value: appState.voiceEnabled,
                    onChanged: appState.setVoiceEnabled,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // ── Sync Status ─────────────────────────
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Sync Status',
                      style:
                          TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  Text(_isSyncing ? 'Syncing...' : 'Ready'),
                  const SizedBox(height: 4),
                  Consumer<AppState>(
                    builder: (context, state, _) {
                      final last = state.lastSyncedAt;
                      if (last == null) {
                        return const Text('Never synced');
                      }
                      final secondsAgo =
                          DateTime.now().difference(last).inSeconds;
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

          // ── Registration Data ───────────────────
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Registration Data',
                      style:
                          TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
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
          const SizedBox(height: 16),

          // ── App Info ────────────────────────────
          const Card(
            child: Padding(
              padding: EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('App Info',
                      style:
                          TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  SizedBox(height: 8),
                  Text('Version: 2.0.0', style: TextStyle(color: Colors.grey)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
