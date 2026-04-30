import 'dart:async';

import 'package:blue_thermal_printer/blue_thermal_printer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:intl/intl.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'package:sqflite/sqflite.dart';

import '../app.dart';
import '../auth/google_auth.dart';
import '../db/database_helper.dart';
import '../db/sync_queue_dao.dart';
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
  StreamSubscription<PrinterServiceEvent>? _printerSubscription;
  final _sheetIdController = TextEditingController();
  final _tabNameController = TextEditingController();
  final _eventNameController = TextEditingController();
  final _organizationNameController = TextEditingController();

  List<BluetoothDevice> _discoveredPrinters = [];
  bool _isScanningPrinters = false;
  bool _isSyncing = false;
  String? _selectedPrinterAddress;
  String? _selectedPrinterName;
  String _printerStateLabel = 'Not checked';
  String _printerStatus = 'Printer status not loaded';
  int _failedPrintCount = 0;
  int _activePrintCount = 0;
  int? _lastPrintSuccessAt;
  int? _lastPrintFailureAt;
  String? _lastPrintFailureReason;
  List<PrinterQueuedJob> _queuedPrintJobs = [];
  List<PrinterQueuedJob> _recentPrintJobs = [];

  List<PrinterQueuedJob> get _pendingConfirmationJobs => _queuedPrintJobs
      .where((job) => job.status == 'awaiting_confirmation')
      .toList()
    ..sort((a, b) => a.queuedAt.compareTo(b.queuedAt));

  List<PrinterQueuedJob> get _retryablePrintJobs => _queuedPrintJobs
      .where((job) => job.status == 'queued')
      .toList()
    ..sort((a, b) => a.queuedAt.compareTo(b.queuedAt));

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
    _printerSubscription = PrinterService.events.listen((_) {
      unawaited(_handlePrinterStateChanged());
    });
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final db = await DatabaseHelper.database;
    final settings = await db.query('app_settings');

    // Reset fields to empty before loading
    _sheetIdController.text = '';
    _tabNameController.text = '';
    _eventNameController.text = '';
    _organizationNameController.text = '';
    _selectedPrinterAddress = null;

    for (final setting in settings) {
      final key = setting['key'] as String;
      final value = setting['value'] as String?;
      if (value == null) continue;

      if (key == 'sheets_id') _sheetIdController.text = value;
      if (key == 'sheets_tab') _tabNameController.text = value;
      if (key == 'event_name') _eventNameController.text = value;
      if (key == 'organization_name') _organizationNameController.text = value;
      if (key == 'printer_address') _selectedPrinterAddress = value;
    }

    // Fallback to .env if any field is still empty
    if (_sheetIdController.text.isEmpty) {
      _sheetIdController.text = dotenv.env['SHEETS_ID'] ?? '';
    }
    if (_tabNameController.text.isEmpty) {
      _tabNameController.text = dotenv.env['SHEETS_TAB'] ?? '';
    }
    if (_eventNameController.text.isEmpty) {
      _eventNameController.text = dotenv.env['EVENT_NAME'] ?? '';
    }
    if (_organizationNameController.text.isEmpty) {
      _organizationNameController.text = dotenv.env['ORGANIZATION_NAME'] ?? '';
    }

    if (!mounted) {
      return;
    }

    setState(() {});
    await _loadPairedPrintersSilently();
    await _refreshPrinterInfo();
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

  String? _validateOrganizationName(String? value) {
    if (value == null || value.isEmpty) {
      return 'Organization name cannot be empty';
    }
    if (value.length > 150) return 'Organization name is too long';
    return null;
  }

  Future<void> _saveSheetSettings() async {
    final sheetIdError = _validateSheetId(_sheetIdController.text);
    final tabNameError = _validateTabName(_tabNameController.text);
    final eventNameError = _validateEventName(_eventNameController.text);
    final organizationNameError = _validateOrganizationName(
      _organizationNameController.text,
    );

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
    if (organizationNameError != null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(organizationNameError),
            backgroundColor: Colors.red,
          ),
        );
      }
      return;
    }

    final db = await DatabaseHelper.database;

    await db.insert(
        'app_settings',
        {
          'key': 'sheets_id',
          'value': _sheetIdController.text,
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
    await db.insert(
        'app_settings',
        {
          'key': 'sheets_tab',
          'value': _tabNameController.text,
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
    await db.insert(
        'app_settings',
        {
          'key': 'event_name',
          'value': _eventNameController.text,
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
    await db.insert(
        'app_settings',
        {
          'key': 'organization_name',
          'value': _organizationNameController.text,
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
    await db.delete('app_settings', where: 'key = ?', whereArgs: ['col_map']);

    if (mounted) {
      await context.read<AppState>().loadPreferences();
    }

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
      } else {
        throw Exception('Google authentication unavailable');
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Settings saved, but column detection failed: $e. Sync will stay paused until column detection succeeds.',
            ),
            backgroundColor: Colors.orange,
          ),
        );
      }
    }
  }

  Future<void> _resetToDefaults() async {
    final db = await DatabaseHelper.database;
    await db.delete('app_settings', where: 'key = ?', whereArgs: ['sheets_id']);
    await db.delete(
      'app_settings',
      where: 'key = ?',
      whereArgs: ['sheets_tab'],
    );
    await db.delete(
      'app_settings',
      where: 'key = ?',
      whereArgs: ['event_name'],
    );
    await db.delete(
      'app_settings',
      where: 'key = ?',
      whereArgs: ['organization_name'],
    );

    final settingsToSeed = {
      'sheets_id': dotenv.env['SHEETS_ID'],
      'sheets_tab': dotenv.env['SHEETS_TAB'],
      'event_name': dotenv.env['EVENT_NAME'],
      'organization_name': dotenv.env['ORGANIZATION_NAME'],
    };
    for (final entry in settingsToSeed.entries) {
      if (entry.value != null) {
        await db.insert(
            'app_settings',
            {
              'key': entry.key,
              'value': entry.value,
            },
            conflictAlgorithm: ConflictAlgorithm.ignore);
      }
    }

    await _loadSettings();
    if (mounted) {
      await context.read<AppState>().loadPreferences();
    }

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

  void _showSnackBar(String message, {Color? backgroundColor}) {
    if (!mounted) {
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: backgroundColor),
    );
  }

  Future<bool> _ensureBluetoothPermissions() async {
    final granted = await PrinterService.ensureBluetoothPermissions();
    if (granted || !mounted) {
      return granted;
    }

    final openSettings = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Bluetooth Permission Required'),
            content: const Text(
              'Allow Bluetooth and location access so the app can load already paired printers and print receipts.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Open Settings'),
              ),
            ],
          ),
        ) ??
        false;

    if (openSettings) {
      await openAppSettings();
    }
    return false;
  }

  Future<bool> _hasPrinterPermissionsGranted() async {
    final statuses = await Future.wait<PermissionStatus>([
      Permission.bluetoothScan.status,
      Permission.bluetoothConnect.status,
      Permission.location.status,
    ]);
    return statuses.every((status) => status.isGranted);
  }

  Future<void> _loadPairedPrintersSilently() async {
    final granted = await _hasPrinterPermissionsGranted();
    if (!granted) {
      return;
    }

    final printers = await PrinterService.scanPrinters();
    if (!mounted) {
      return;
    }

    setState(() {
      _discoveredPrinters = printers;
    });
  }

  Future<void> _refreshPrinterInfo({bool revalidateConnection = false}) async {
    final status = await PrinterService.getSelectedPrinterStatus(
      revalidateConnection: revalidateConnection,
    );
    final queuedPrintJobs = await PrinterService.getQueuedJobs();
    final recentPrintJobs = await PrinterService.getRecentPrintJobs(limit: 8);
    if (!mounted) {
      return;
    }

    context.read<AppState>().applyPrinterSnapshot(status);

    setState(() {
      _selectedPrinterAddress = status.selectedAddress;
      _selectedPrinterName = status.selectedName;
      _printerStateLabel = status.stateLabel;
      _printerStatus = status.message;
      _failedPrintCount = status.queuedJobCount;
      _activePrintCount = status.activeJobCount;
      _lastPrintSuccessAt = status.lastPrintSuccessAt;
      _lastPrintFailureAt = status.lastPrintFailureAt;
      _lastPrintFailureReason = status.lastPrintFailureReason;
      _queuedPrintJobs = queuedPrintJobs;
      _recentPrintJobs = recentPrintJobs;
    });
  }

  Future<void> _handlePrinterStateChanged() async {
    if (!mounted) {
      return;
    }
    await _loadPairedPrintersSilently();
    await _refreshPrinterInfo();
  }

  // ─── Printer ────────────────────────────────────────────────
  Future<void> _scanPrinters() async {
    final granted = await _ensureBluetoothPermissions();
    if (!granted) {
      return;
    }

    setState(() => _isScanningPrinters = true);
    try {
      final printers = await PrinterService.scanPrinters();
      if (!mounted) {
        return;
      }

      setState(() {
        _discoveredPrinters = printers;
      });
      await _refreshPrinterInfo();

      if (printers.isEmpty) {
        _showSnackBar(
          'No paired printers found. Pair the printer in Android Bluetooth settings first.',
          backgroundColor: Colors.orange,
        );
      }
    } catch (e) {
      _showSnackBar(
        'Unable to load paired printers: $e',
        backgroundColor: Colors.red,
      );
    } finally {
      if (mounted) {
        setState(() => _isScanningPrinters = false);
      }
    }
  }

  Future<void> _selectPrinter(BluetoothDevice printer) async {
    await PrinterService.saveSelectedPrinter(printer);
    await _refreshPrinterInfo();
    _showSnackBar('Printer ${printer.name ?? 'Unknown'} selected');
  }

  Future<void> _connectToPrinter(BluetoothDevice device) async {
    final granted = await _ensureBluetoothPermissions();
    if (!granted) {
      return;
    }

    final result = await PrinterService.connect(
      device,
      rememberSelection: true,
    );
    await _refreshPrinterInfo();
    _showSnackBar(
      result.message,
      backgroundColor: result.success ? Colors.green : Colors.red,
    );
  }

  Future<void> _testPrint() async {
    final granted = await _ensureBluetoothPermissions();
    if (!granted) {
      return;
    }

    final result = await PrinterService.printDiagnosticProbe();
    await _refreshPrinterInfo();
    _showSnackBar(
      result.message,
      backgroundColor: result.success
          ? Colors.green
          : result.queuedForRetry
              ? Colors.orange
              : Colors.red,
    );
  }

  Future<void> _retryFailedPrints() async {
    final jobs = List<PrinterQueuedJob>.from(_retryablePrintJobs);
    if (jobs.isEmpty) {
      await _refreshPrinterInfo();
      _showSnackBar('No failed prints to retry');
      return;
    }

    var attempted = 0;
    var succeeded = 0;

    for (final job in jobs) {
      attempted++;
      var result = await PrinterService.retryQueuedJob(
        job.jobId,
        requireOperatorConfirmation: true,
      );
      if (result.requiresOperatorConfirmation &&
          result.confirmationJobId != null &&
          mounted) {
        result = await _confirmPrintedOutput(result.confirmationJobId!);
      }
      if (result.success) {
        succeeded++;
      }
      await _refreshPrinterInfo();
      if (!mounted) {
        return;
      }
    }

    await _refreshPrinterInfo();
    final remaining = _retryablePrintJobs.length;
    final allSucceeded = remaining == 0;
    _showSnackBar(
      'Retried $attempted jobs, $succeeded confirmed, $remaining remaining.',
      backgroundColor: allSucceeded ? Colors.green : Colors.orange,
    );
  }

  Future<void> _resolvePendingConfirmation(
    PrinterQueuedJob job,
    bool printed,
  ) async {
    final result = printed
        ? await PrinterService.confirmPrintDelivery(job.jobId)
        : await PrinterService.rejectPrintDelivery(job.jobId);
    await _refreshPrinterInfo();
    _showSnackBar(
      result.message,
      backgroundColor: result.success
          ? Colors.green
          : result.queuedForRetry
              ? Colors.orange
              : Colors.red,
    );
  }

  Future<void> _checkPrinterStatus() async {
    final granted = await _ensureBluetoothPermissions();
    if (!granted) {
      return;
    }

    await _refreshPrinterInfo(revalidateConnection: true);
    _showSnackBar(
      '$_printerStateLabel: $_printerStatus',
      backgroundColor: _isPrinterHealthy()
          ? Colors.green
          : _failedPrintCount > 0
              ? Colors.orange
              : Colors.red,
    );
  }

  Future<void> _setCutMode(String printerAddress, String mode) async {
    await PrinterService.setCutMode(printerAddress, mode);
    if (!mounted) {
      return;
    }

    setState(() {});
    final label = switch (mode) {
      PrinterService.cutModeOff => 'No Cut',
      PrinterService.cutModeSafe => 'Safe Tear',
      PrinterService.cutModeForce => 'Full Cut',
      _ => mode,
    };
    _showSnackBar('Paper finish mode set to $label');
  }

  Future<PrintReceiptResult> _confirmPrintedOutput(String jobId) async {
    final printed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Confirm Receipt Output'),
        content: const Text(
          'Did the receipt actually come out of the printer?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('No, Queue Retry'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Yes, Printed'),
          ),
        ],
      ),
    );

    if (printed == true) {
      return PrinterService.confirmPrintDelivery(jobId);
    }
    return PrinterService.rejectPrintDelivery(jobId);
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
    final pendingCount = await SyncQueueDao.getPendingCount();
    if (pendingCount > 0) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Clear All Data is blocked because $pendingCount local changes are still pending sync. Run Full Sync first.',
            ),
            backgroundColor: Colors.orange,
          ),
        );
      }
      return;
    }

    final confirmed = await _showConfirmationDialog(context);
    if (confirmed == true && mounted) {
      await appState.clearAllData();
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('All data cleared')));
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

  bool _isPrinterHealthy() {
    return _printerStateLabel == 'Connected' &&
        _failedPrintCount == 0 &&
        _activePrintCount == 0;
  }

  bool get _isPrinterUnhealthy =>
      _printerStateLabel == 'Printer Unhealthy' ||
      _printerStateLabel == 'Connected, Unhealthy';

  String _formatTimestamp(int? value) {
    if (value == null) {
      return 'Never';
    }
    return DateFormat(
      'dd MMM, h:mm a',
    ).format(DateTime.fromMillisecondsSinceEpoch(value));
  }

  @override
  void dispose() {
    _syncStatusSubscription.cancel();
    _printerSubscription?.cancel();
    _sheetIdController.dispose();
    _tabNameController.dispose();
    _eventNameController.dispose();
    _organizationNameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final appState = Provider.of<AppState>(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(16.0),
        children: [
          // Sheet Configuration
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Sheet Configuration',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
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
                  TextField(
                    controller: _organizationNameController,
                    decoration: const InputDecoration(
                      labelText: 'Organization Name',
                      hintText: 'Enter the hosting organization name',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: ElevatedButton(
                          onPressed: _saveSheetSettings,
                          child: const Text('Save'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton.icon(
                        onPressed: _resetToDefaults,
                        icon: const Icon(Icons.restore),
                        label: const Text('Reset'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // Printer Settings
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Printer Settings',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Only paired printers appear here. Pair the printer in Android Bluetooth settings first.',
                    style: TextStyle(color: Colors.grey),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: ElevatedButton(
                          onPressed: _isScanningPrinters ? null : _scanPrinters,
                          child: Text(
                            _isScanningPrinters
                                ? 'Scanning...'
                                : 'Load Paired Printers',
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton(
                          onPressed: _checkPrinterStatus,
                          child: const Text('Check Status'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: ElevatedButton(
                          onPressed: _selectedPrinterAddress != null
                              ? _testPrint
                              : null,
                          child: const Text('Test Print'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (_selectedPrinterAddress != null)
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Selected: ${_selectedPrinterName?.trim().isNotEmpty == true ? _selectedPrinterName : _selectedPrinterAddress}',
                          style: const TextStyle(color: Colors.grey),
                        ),
                        if (_selectedPrinterName != null &&
                            _selectedPrinterName!.trim().isNotEmpty)
                          Text(
                            _selectedPrinterAddress!,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                      ],
                    ),
                  if (_selectedPrinterAddress != null)
                    const SizedBox(height: 8),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: _isPrinterHealthy()
                          ? Colors.green.withValues(alpha: 0.08)
                          : _isPrinterUnhealthy
                              ? Colors.red.withValues(alpha: 0.12)
                          : _failedPrintCount > 0
                              ? Colors.orange.withValues(alpha: 0.08)
                              : Colors.red.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _printerStateLabel,
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 16,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _printerStatus,
                          style: const TextStyle(color: Colors.black87),
                        ),
                        if (_isPrinterUnhealthy) ...[
                          const SizedBox(height: 8),
                          const Text(
                            'Auto-retry is paused after repeated failures. Resolve pending confirmations, confirm printer readiness, then run a successful print to clear the unhealthy state.',
                            style: TextStyle(
                              color: Colors.redAccent,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 12,
                          runSpacing: 8,
                          children: [
                            Text('Failed queue: $_failedPrintCount'),
                            Text('Active jobs: $_activePrintCount'),
                            Text(
                              'Last success: ${_formatTimestamp(_lastPrintSuccessAt)}',
                            ),
                            Text(
                              'Last failure: ${_formatTimestamp(_lastPrintFailureAt)}',
                            ),
                          ],
                        ),
                        if ((_lastPrintFailureReason ?? '')
                            .trim()
                            .isNotEmpty) ...[
                          const SizedBox(height: 8),
                          Text(
                            'Last failure reason: $_lastPrintFailureReason',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (_selectedPrinterAddress != null)
                    FutureBuilder<String>(
                      future: PrinterService.getCutMode(
                        _selectedPrinterAddress!,
                      ),
                      builder: (context, snapshot) {
                        final currentMode =
                            snapshot.data ?? PrinterService.cutModeOff;
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Paper Finish',
                              style: TextStyle(fontWeight: FontWeight.bold),
                            ),
                            const SizedBox(height: 4),
                            const Text(
                              'Choose how the paper should end after printing on this printer.',
                              style: TextStyle(color: Colors.grey),
                            ),
                            const SizedBox(height: 8),
                            SegmentedButton<String>(
                              segments: const [
                                ButtonSegment<String>(
                                  value: PrinterService.cutModeOff,
                                  label: Text('No Cut'),
                                ),
                                ButtonSegment<String>(
                                  value: PrinterService.cutModeSafe,
                                  label: Text('Safe Tear'),
                                ),
                                ButtonSegment<String>(
                                  value: PrinterService.cutModeForce,
                                  label: Text('Full Cut'),
                                ),
                              ],
                              selected: {currentMode},
                              onSelectionChanged: (selection) {
                                final printerAddress = _selectedPrinterAddress;
                                if (printerAddress == null ||
                                    selection.isEmpty) {
                                  return;
                                }
                                _setCutMode(printerAddress, selection.first);
                              },
                            ),
                            const SizedBox(height: 6),
                            Text(
                                switch (currentMode) {
                                  PrinterService.cutModeSafe =>
                                    'Safe Tear sends a gentler cut command for printers that may support partial cutting.',
                                  PrinterService.cutModeForce =>
                                    'Full Cut sends the strongest cut command. Use this only on printers with an auto-cutter.',
                                  _ =>
                                    'No Cut is safest for portable printers like the PT-200 and leaves extra paper for manual tearing.',
                                },
                                style: Theme.of(context).textTheme.bodySmall),
                            const SizedBox(height: 8),
                          ],
                        );
                      },
                    ),
                  if (_discoveredPrinters.isNotEmpty)
                    ListView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: _discoveredPrinters.length,
                      itemBuilder: (context, index) {
                        final printer = _discoveredPrinters[index];
                        return ListTile(
                          title: Text(printer.name ?? 'Unknown Printer'),
                          subtitle: Text(printer.address ?? ''),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: const Icon(
                                  Icons.bluetooth_connected,
                                  size: 20,
                                ),
                                tooltip: 'Select and connect',
                                onPressed: () => _connectToPrinter(printer),
                              ),
                              if (_selectedPrinterAddress == printer.address)
                                const Icon(
                                  Icons.check_circle,
                                  color: Colors.green,
                                )
                              else
                                Container(width: 24),
                            ],
                          ),
                          onTap: () => _selectPrinter(printer),
                        );
                      },
                    ),
                  if (_pendingConfirmationJobs.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    const Text(
                      'Pending Print Confirmations',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'Resolve these before sending another print for the same participant.',
                      style: TextStyle(color: Colors.grey),
                    ),
                    const SizedBox(height: 8),
                    ..._pendingConfirmationJobs.take(5).map(
                          (job) => Card(
                            margin: const EdgeInsets.only(bottom: 8),
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    job.participantName,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    job.reason.isEmpty
                                        ? 'Waiting for an operator to confirm whether paper came out of the printer.'
                                        : job.reason,
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    '${job.isReprint ? 'Reprint' : 'Initial print'} • sent ${_formatTimestamp(job.lastAttemptAt ?? job.queuedAt)}',
                                    style:
                                        Theme.of(context).textTheme.bodySmall,
                                  ),
                                  const SizedBox(height: 8),
                                  Wrap(
                                    spacing: 8,
                                    runSpacing: 8,
                                    children: [
                                      FilledButton.icon(
                                        onPressed: () => _resolvePendingConfirmation(
                                          job,
                                          true,
                                        ),
                                        icon: const Icon(Icons.check_circle),
                                        label: const Text('Confirm Printed'),
                                      ),
                                      OutlinedButton.icon(
                                        onPressed: () => _resolvePendingConfirmation(
                                          job,
                                          false,
                                        ),
                                        icon: const Icon(Icons.replay),
                                        label: const Text('Queue Retry'),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                    if (_pendingConfirmationJobs.length > 5)
                      Text(
                        '${_pendingConfirmationJobs.length - 5} more pending confirmations not shown',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                  ],
                  if (_retryablePrintJobs.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    const Text(
                      'Queued Print Jobs',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),
                    ..._retryablePrintJobs.take(5).map(
                          (job) => ListTile(
                            contentPadding: EdgeInsets.zero,
                            dense: true,
                            leading: Icon(
                              job.isReprint ? Icons.receipt_long : Icons.print,
                              color: job.isReprint
                                  ? FSYScannerApp.primaryBlue
                                  : FSYScannerApp.accentGold,
                            ),
                            title: Text(job.participantName),
                            subtitle: Text(
                              '${job.reason} • attempts ${job.attemptCount} • next retry ${_formatTimestamp(job.nextRetryAt)}',
                            ),
                          ),
                        ),
                    if (_retryablePrintJobs.length > 5)
                      Text(
                        '${_retryablePrintJobs.length - 5} more queued jobs not shown',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                  ],
                  if (_recentPrintJobs.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    const Text(
                      'Recent Print Activity',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),
                    ..._recentPrintJobs.map(
                      (job) => ListTile(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        leading: Icon(
                          switch (job.status) {
                            'success' => Icons.check_circle,
                            'cancelled' => Icons.cancel,
                            _ => Icons.schedule,
                          },
                          color: switch (job.status) {
                            'success' => FSYScannerApp.accentGreen,
                            'cancelled' => Colors.redAccent,
                            _ => FSYScannerApp.accentGold,
                          },
                        ),
                        title: Text(job.participantName),
                        subtitle: Text(
                          '${job.isReprint ? 'Reprint' : 'Initial print'} • ${job.status} • attempts ${job.attemptCount}',
                        ),
                        trailing: Text(
                          _formatTimestamp(job.printedAt ?? job.lastAttemptAt),
                          textAlign: TextAlign.end,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  ElevatedButton.icon(
                    onPressed: _retryFailedPrints,
                    icon: const Icon(Icons.replay),
                    label: Text('Retry Failed (${_retryablePrintJobs.length})'),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // Device Info
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
                    builder: (context, snapshot) => snapshot.hasData
                        ? Text('ID: ${snapshot.data!}')
                        : const Text('Loading device ID...'),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // Feedback (Sound, Haptics, Voice)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Feedback',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
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
                    subtitle: const Text(
                      'Speak participant name after check‑in',
                    ),
                    value: appState.voiceEnabled,
                    onChanged: appState.setVoiceEnabled,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // Sync Status
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
                  Text(_isSyncing ? 'Syncing...' : 'Ready'),
                  const SizedBox(height: 4),
                  Consumer<AppState>(
                    builder: (context, state, _) {
                      final last = state.lastSyncedAt;
                      if (last == null) return const Text('Never synced');
                      final secondsAgo =
                          DateTime.now().difference(last).inSeconds;
                      final display = secondsAgo < 60
                          ? 'just now'
                          : secondsAgo < 120
                              ? '1 min ago'
                              : '${secondsAgo ~/ 60} mins ago';
                      return Text(
                        'Last sync: $display',
                        style: const TextStyle(color: Colors.grey),
                      );
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

          // Registration Data
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

          // App Info
          const Card(
            child: Padding(
              padding: EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'App Info',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
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
