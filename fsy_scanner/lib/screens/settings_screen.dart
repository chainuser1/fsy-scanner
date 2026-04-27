import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_thermal_printer/utils/printer.dart';
import 'package:provider/provider.dart';
import 'package:sqflite/sqflite.dart';

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
  late StreamSubscription _syncStatusSubscription;
  final _sheetIdController = TextEditingController();
  final _tabNameController = TextEditingController();
  final _eventNameController = TextEditingController();
  
  List<Printer> _discoveredPrinters = [];
  bool _isScanningPrinters = false;
  String? _selectedPrinterAddress;

  @override
  void initState() {
    super.initState();
    _syncStatusSubscription = SyncEngine.syncStatusStream.listen((status) {
      if (mounted) {
        setState(() {});
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

  Future<void> _saveSheetSettings() async {
    final db = await DatabaseHelper.database;
    await db.insert('app_settings', {'key': 'sheets_id', 'value': _sheetIdController.text}, conflictAlgorithm: ConflictAlgorithm.replace);
    await db.insert('app_settings', {'key': 'sheets_tab', 'value': _tabNameController.text}, conflictAlgorithm: ConflictAlgorithm.replace);
    await db.insert('app_settings', {'key': 'event_name', 'value': _eventNameController.text}, conflictAlgorithm: ConflictAlgorithm.replace);
    
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Settings saved')));
    
    // Trigger column detection
    try {
      final token = await GoogleAuth.getValidToken();
      if (token != null) {
        await SheetsApi.detectColMap(db, token, _sheetIdController.text, _tabNameController.text);
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Columns detected successfully'), backgroundColor: Colors.green));
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Column detection failed: $e'), backgroundColor: Colors.red));
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
    await db.insert('app_settings', {'key': 'printer_address', 'value': printer.address}, conflictAlgorithm: ConflictAlgorithm.replace);
    setState(() => _selectedPrinterAddress = printer.address);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Printer ${printer.name} selected')));
  }

  Future<void> _testPrint() async {
    final deviceId = await DeviceId.get();
    // Use a mock participant for test print
    final mockParticipant = Participant(
      id: 'TEST-001',
      fullName: 'Test Participant',
      sheetsRow: 0,
    );
    final success = await PrinterService.printReceipt(mockParticipant, deviceId);
    if (!success) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Test print failed'), backgroundColor: Colors.red));
    }
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
        backgroundColor: Colors.blue[600],
        foregroundColor: Colors.white,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16.0),
        children: [
          // Sheet Config Section
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Sheet Configuration', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 16),
                  TextField(controller: _sheetIdController, decoration: const InputDecoration(labelText: 'Google Sheet ID')),
                  TextField(controller: _tabNameController, decoration: const InputDecoration(labelText: 'Tab Name')),
                  TextField(controller: _eventNameController, decoration: const InputDecoration(labelText: 'Event Name')),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: _saveSheetSettings,
                      child: const Text('Save & Detect Columns'),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          
          // Printer Section
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Printer Settings', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: ElevatedButton(
                          onPressed: _isScanningPrinters ? null : _scanPrinters,
                          child: Text(_isScanningPrinters ? 'Scanning...' : 'Scan for Printers'),
                        ),
                      ),
                      const SizedBox(width: 16),
                      ElevatedButton(
                        onPressed: _selectedPrinterAddress != null ? _testPrint : null,
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
                        final isSelected = _selectedPrinterAddress == printer.address;
                        return ListTile(
                          title: Text(printer.name ?? 'Unknown Printer'),
                          subtitle: Text(printer.address ?? ''),
                          trailing: isSelected ? const Icon(Icons.check_circle, color: Colors.green) : null,
                          onTap: () => _selectPrinter(printer),
                        );
                      },
                    )
                  else if (!_isScanningPrinters)
                    const Text('No printers found. Make sure Bluetooth is on and printer is discoverable.'),
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
                  const Text(
                    'Device Info',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
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
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Sync Status',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  Text(SyncEngine.isSyncing ? 'Syncing...' : 'Ready'),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: ElevatedButton(
                          onPressed: SyncEngine.isSyncing ? null : _startFullSync,
                          child: const Text('Full Sync'),
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: ElevatedButton(
                          onPressed: SyncEngine.isSyncing ? null : _startPullOnlySync,
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
                  const Text(
                    'Registration Data',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  Text('${appState.participantsCount} participants registered'),
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

  Future<void> _startFullSync() async {
    await SyncEngine.performFullSync();
  }

  Future<void> _startPullOnlySync() async {
    await SyncEngine.performPullSync();
  }

  Future<void> _clearAllData(BuildContext context, AppState appState) async {
    final confirmed = await _showConfirmationDialog(context);
    if (confirmed) {
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
            content: const Text('Are you sure you want to clear all data? This cannot be undone.'),
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
}

class SyncStatusHelper {
  static const bool _isSyncing = false;

  static bool get isSyncing => _isSyncing;
}
