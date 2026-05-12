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
  int _pendingPrintConfirmationCount = 0;
  int _activePrintCount = 0;
  int? _lastPrintSuccessAt;
  int? _lastPrintFailureAt;
  String? _lastPrintFailureReason;
  bool _automaticRetryFailedPrintsEnabled = false;
  List<PrinterQueuedJob> _queuedPrintJobs = [];
  List<PrinterQueuedJob> _recentPrintJobs = [];

  List<PrinterQueuedJob> get _pendingConfirmationJobs => _queuedPrintJobs
      .where((job) => job.status == 'awaiting_confirmation')
      .toList()
    ..sort((a, b) => a.queuedAt.compareTo(b.queuedAt));

  List<PrinterQueuedJob> get _retryablePrintJobs =>
      _queuedPrintJobs.where((job) => job.status == 'queued').toList()
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
    // Read from AppState — already populated from DB + .env at startup via
    // AppState.loadPreferences().  No need for a duplicate DB query.
    final appState = context.read<AppState>();

    _sheetIdController.text = appState.sheetsId;
    _tabNameController.text = appState.sheetsTab;
    _eventNameController.text = appState.eventName;
    _organizationNameController.text = appState.organizationName;
    _selectedPrinterAddress = appState.printerAddress;

    if (!mounted) return;
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

    // Guard: don't nuke the column map while a sync is reading it
    if (!await _confirmSaveDuringSync()) return;

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
      SyncEngine.signalConfigChanged();
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Settings saved — a full re-sync will follow'),
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
    // Guard: don't nuke settings while a sync is reading them
    if (!await _confirmSaveDuringSync()) return;

    final db = await DatabaseHelper.database;

    // Reset sheet and event settings
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
    // Reset advanced settings
    await db.delete(
      'app_settings',
      where: 'key = ?',
      whereArgs: ['google_service_account_email'],
    );
    await db.delete(
      'app_settings',
      where: 'key = ?',
      whereArgs: ['google_service_account_private_key'],
    );
    await db.delete(
      'app_settings',
      where: 'key = ?',
      whereArgs: ['column_header_overrides'],
    );
    await db.delete(
      'app_settings',
      where: 'key = ?',
      whereArgs: ['col_map'],
    );
    await db.delete(
      'app_settings',
      where: 'key = ?',
      whereArgs: ['active_profile_id'],
    );

    final settingsToSeed = {
      'sheets_id': dotenv.env['SHEETS_ID'],
      'sheets_tab': dotenv.env['SHEETS_TAB'],
      'event_name': dotenv.env['EVENT_NAME'],
      'organization_name': dotenv.env['ORGANIZATION_NAME'],
      'google_service_account_email':
          dotenv.env['GOOGLE_SERVICE_ACCOUNT_EMAIL'],
      'google_service_account_private_key':
          dotenv.env['GOOGLE_SERVICE_ACCOUNT_PRIVATE_KEY'],
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
      final appState = context.read<AppState>();
      GoogleAuth.invalidateCache();
      await appState.loadPreferences();
      SyncEngine.signalConfigChanged();
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
    final automaticRetryFailedPrintsEnabled =
        await PrinterService.getAutomaticRetryFailedPrintsEnabled();
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
      _pendingPrintConfirmationCount = status.pendingConfirmationCount;
      _activePrintCount = status.activeJobCount;
      _lastPrintSuccessAt = status.lastPrintSuccessAt;
      _lastPrintFailureAt = status.lastPrintFailureAt;
      _lastPrintFailureReason = status.lastPrintFailureReason;
      _automaticRetryFailedPrintsEnabled = automaticRetryFailedPrintsEnabled;
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
    var awaitingConfirmation = 0;

    for (final job in jobs) {
      attempted++;
      var result = await PrinterService.retryQueuedJob(
        job.jobId,
        manualRetry: true,
      );
      if (result.requiresOperatorConfirmation &&
          result.confirmationJobId != null &&
          mounted) {
        result = await _confirmPrintedOutput(result.confirmationJobId!);
      }
      if (result.awaitingOperatorConfirmation) {
        awaitingConfirmation++;
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
      awaitingConfirmation > 0
          ? 'Retried $attempted jobs, $succeeded confirmed, $awaitingConfirmation awaiting confirmation, $remaining remaining.'
          : 'Retried $attempted jobs, $succeeded confirmed, $remaining remaining.',
      backgroundColor: allSucceeded && awaitingConfirmation == 0
          ? Colors.green
          : Colors.orange,
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
    final previousMode = await PrinterService.getCutMode(printerAddress);
    await PrinterService.setCutMode(printerAddress, mode);
    await _refreshPrinterInfo();
    if (!mounted) {
      return;
    }

    final label = switch (mode) {
      PrinterService.cutModeOff => 'No Cut',
      PrinterService.cutModeSafe => 'Safe Tear',
      PrinterService.cutModeForce => 'Full Cut',
      _ => mode,
    };
    if (mode == PrinterService.cutModeForce &&
        previousMode != PrinterService.cutModeForce) {
      _showSnackBar(
        'Paper finish mode set to $label. Use Full Cut only if this printer truly supports automatic full cutting.',
        backgroundColor: Colors.orange,
      );
      return;
    }
    if (previousMode == PrinterService.cutModeForce &&
        mode != PrinterService.cutModeForce) {
      _showSnackBar(
        'Paper finish mode set to $label. Automatic retry for failed prints was turned off because manual paper handling is now required.',
        backgroundColor: Colors.orange,
      );
      return;
    }
    _showSnackBar('Paper finish mode set to $label');
  }

  Future<void> _setAutomaticRetryFailedPrintsEnabled(bool enabled) async {
    if (enabled) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Enable Automatic Retry?'),
          content: const Text(
            'Automatic retry for failed prints is only safe when this printer truly supports Full Cut. The app will send a full-cut command after each failed-job retry. If the printer cannot fully cut, repeated receipts may stack or jam. Enable automatic retry only if you are sure this printer has a working full cutter.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Enable'),
            ),
          ],
        ),
      );
      if (confirmed != true) {
        return;
      }
    }

    try {
      await PrinterService.setAutomaticRetryFailedPrintsEnabled(enabled);
      await _refreshPrinterInfo();
      if (!mounted) {
        return;
      }
      _showSnackBar(
        enabled
            ? 'Automatic retry for failed prints enabled. Reconnected printers will prioritize queued failed jobs first.'
            : 'Automatic retry for failed prints disabled.',
        backgroundColor: enabled ? Colors.orange : Colors.green,
      );
    } catch (error) {
      await _refreshPrinterInfo();
      if (!mounted) {
        return;
      }
      _showSnackBar(
        error.toString().replaceFirst('Bad state: ', ''),
        backgroundColor: Colors.red,
      );
    }
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

  /// If a sync is in progress, shows a dialog and returns true only if the
  /// user chooses to save anyway.
  Future<bool> _confirmSaveDuringSync() async {
    if (!SyncEngine.isSyncing) return true;
    final proceed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Sync in Progress'),
        content: const Text(
          'A sync is currently running. Saving now will let the current '
          'sync finish with the old settings, then a full re-sync with '
          'the new configuration will start automatically.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Save Anyway'),
          ),
        ],
      ),
    );
    return proceed ?? false;
  }

  bool _isPrinterHealthy() {
    return _printerStateLabel == 'Connected' &&
        _failedPrintCount == 0 &&
        _pendingPrintConfirmationCount == 0 &&
        _activePrintCount == 0;
  }

  bool get _isPrinterUnhealthy =>
      _printerStateLabel == 'Printer Unhealthy' ||
      _printerStateLabel == 'Connected, Unhealthy';

  String _receiptConfirmationPolicyLabel(String policy) {
    switch (policy) {
      case PrinterService.receiptConfirmationAlwaysAsk:
        return 'Always Ask';
      case PrinterService.receiptConfirmationAskOnRisk:
        return 'Ask Only On Risk';
      case PrinterService.receiptConfirmationNeverAsk:
        return 'Never Ask (Unsafe)';
      case PrinterService.receiptConfirmationFastQueue:
      default:
        return 'Fast Queue Confirm';
    }
  }

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
                  DropdownButtonFormField<String>(
                    initialValue: appState.receiptConfirmationPolicy,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Receipt Confirmation Policy',
                      border: OutlineInputBorder(),
                      helperText:
                          'Choose how the app confirms physical receipt output.',
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: PrinterService.receiptConfirmationFastQueue,
                        child: Text(
                          'Fast Queue Confirm',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      DropdownMenuItem(
                        value: PrinterService.receiptConfirmationAlwaysAsk,
                        child: Text(
                          'Always Ask',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      DropdownMenuItem(
                        value: PrinterService.receiptConfirmationAskOnRisk,
                        child: Text(
                          'Ask Only On Risk',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      DropdownMenuItem(
                        value: PrinterService.receiptConfirmationNeverAsk,
                        child: Text(
                          'Never Ask (Unsafe)',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                    selectedItemBuilder: (context) => const [
                      Text(
                        'Fast Queue Confirm',
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        'Always Ask',
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        'Ask Only On Risk',
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        'Never Ask (Unsafe)',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                    onChanged: (selection) async {
                      if (selection == null) {
                        return;
                      }
                      await appState.setReceiptConfirmationPolicy(selection);
                      if (!mounted) {
                        return;
                      }
                      await _refreshPrinterInfo();
                      _showSnackBar(
                        'Receipt confirmation policy set to ${_receiptConfirmationPolicyLabel(selection)}.',
                        backgroundColor: selection ==
                                PrinterService.receiptConfirmationNeverAsk
                            ? Colors.orange
                            : Colors.green,
                      );
                    },
                  ),
                  const SizedBox(height: 12),
                  if (appState.receiptConfirmationPolicy ==
                      PrinterService.receiptConfirmationFastQueue)
                    const Text(
                      'Fast Queue Confirm keeps scanning fast. Prints stay truthful by remaining partially verified until the operator confirms them from the pending confirmations queue.',
                      style: TextStyle(color: Colors.black87),
                    )
                  else if (appState.receiptConfirmationPolicy ==
                      PrinterService.receiptConfirmationAskOnRisk)
                    const Text(
                      'Ask Only On Risk shows a blocking confirmation only after failures, reconnects, unresolved print work, or reprints.',
                      style: TextStyle(color: Colors.black87),
                    )
                  else if (appState.receiptConfirmationPolicy ==
                      PrinterService.receiptConfirmationNeverAsk)
                    const Text(
                      'Unsafe mode treats transport success as success and can reintroduce false printed receipts. Use only if your operation explicitly accepts that risk.',
                      style: TextStyle(color: Colors.orange),
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
                      Flexible(
                        child: OutlinedButton.icon(
                          onPressed: _resetToDefaults,
                          icon: const Icon(Icons.restore),
                          label: const Text('Reset'),
                        ),
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
                        if (_pendingPrintConfirmationCount > 0) ...[
                          const SizedBox(height: 8),
                          Text(
                            '$_pendingPrintConfirmationCount print${_pendingPrintConfirmationCount == 1 ? '' : 's'} still awaiting operator confirmation.',
                            style: const TextStyle(
                              color: Colors.deepOrange,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
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
                            SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              child: SegmentedButton<String>(
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
                                  final printerAddress =
                                      _selectedPrinterAddress;
                                  if (printerAddress == null ||
                                      selection.isEmpty) {
                                    return;
                                  }
                                  _setCutMode(printerAddress, selection.first);
                                },
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                                switch (currentMode) {
                                  PrinterService.cutModeSafe =>
                                    'Safe Tear sends a gentler cut command for printers that may support partial cutting. Failed-job auto retry stays off and manual retry will pause for confirmation after every print.',
                                  PrinterService.cutModeForce =>
                                    'Full Cut sends the strongest cut command. Use this only on printers with a true auto-cutter. Failed-job auto retry can be enabled only in this mode.',
                                  _ =>
                                    'No Cut is safest for portable printers like the PT-200 and leaves extra paper for manual tearing. Failed-job auto retry stays off and manual retry will pause for confirmation after every print.',
                                },
                                style: Theme.of(context).textTheme.bodySmall),
                            const SizedBox(height: 8),
                            SwitchListTile.adaptive(
                              contentPadding: EdgeInsets.zero,
                              value: currentMode == PrinterService.cutModeForce
                                  ? _automaticRetryFailedPrintsEnabled
                                  : false,
                              onChanged:
                                  currentMode == PrinterService.cutModeForce
                                      ? _setAutomaticRetryFailedPrintsEnabled
                                      : null,
                              title: const Text(
                                'Automatic Retry Failed Prints',
                              ),
                              subtitle: Text(
                                currentMode == PrinterService.cutModeForce
                                    ? 'Off by default. When enabled, reconnected printers will drain older failed jobs first and send a full-cut command after each retry.'
                                    : 'Unavailable for No Cut and Safe Tear. These modes require manual paper handling, so failed-job retry must be manual and pause for confirmation after every print.',
                              ),
                            ),
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
                                        onPressed: () =>
                                            _resolvePendingConfirmation(
                                          job,
                                          true,
                                        ),
                                        icon: const Icon(Icons.check_circle),
                                        label: const Text('Confirm Printed'),
                                      ),
                                      OutlinedButton.icon(
                                        onPressed: () =>
                                            _resolvePendingConfirmation(
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
                    ElevatedButton.icon(
                      onPressed: _retryFailedPrints,
                      icon: const Icon(Icons.replay),
                      label: Text(
                        'Retry Failed (${_retryablePrintJobs.length})',
                      ),
                    ),
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
          const SizedBox(height: 16),

          // ── Advanced Settings (collapsible) ──────────────────────
          _AdvancedSettingsSection(appState: appState),
        ],
      ),
    );
  }
}

/// Separate widget for the collapsible Advanced Settings section to keep
/// the main build method readable.
class _AdvancedSettingsSection extends StatefulWidget {
  final AppState appState;
  const _AdvancedSettingsSection({required this.appState});

  @override
  State<_AdvancedSettingsSection> createState() =>
      _AdvancedSettingsSectionState();
}

class _AdvancedSettingsSectionState extends State<_AdvancedSettingsSection> {
  bool _expanded = false;
  bool _isTestingCredentials = false;
  bool _isLoadingHeaders = false;
  bool _isSavingProfile = false;

  // Google credentials
  final _googleEmailController = TextEditingController();
  final _googlePrivateKeyController = TextEditingController();

  // Column mapping
  List<String> _detectedHeaders = [];
  final Map<String, String> _workingOverrides = {};

  // Event profiles
  int? _selectedProfileId;
  final _profileNameController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _googleEmailController.text = widget.appState.googleServiceAccountEmail;
    _googlePrivateKeyController.text =
        widget.appState.googleServiceAccountPrivateKey;
    _workingOverrides.addAll(widget.appState.columnHeaderOverrides);
    _selectedProfileId = widget.appState.activeProfileId;
  }

  @override
  void didUpdateWidget(covariant _AdvancedSettingsSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Sync controllers if appState values changed externally (e.g. after reset
    // or profile switch). Only update if the field isn't being actively edited.
    if (_googleEmailController.text !=
        widget.appState.googleServiceAccountEmail) {
      _googleEmailController.text = widget.appState.googleServiceAccountEmail;
    }
    if (_googlePrivateKeyController.text !=
        widget.appState.googleServiceAccountPrivateKey) {
      _googlePrivateKeyController.text =
          widget.appState.googleServiceAccountPrivateKey;
    }
    if (widget.appState.activeProfileId != _selectedProfileId) {
      _selectedProfileId = widget.appState.activeProfileId;
    }
    // If the settings were refreshed externally (reset, profile switch, etc.),
    // clear stale cached headers so the user must reload.
    if (oldWidget.appState.preferencesVersion !=
        widget.appState.preferencesVersion) {
      _detectedHeaders = [];
      _workingOverrides.clear();
      _workingOverrides.addAll(widget.appState.columnHeaderOverrides);
    }
  }

  @override
  void dispose() {
    _googleEmailController.dispose();
    _googlePrivateKeyController.dispose();
    _profileNameController.dispose();
    super.dispose();
  }

  // ── Google Credentials ────────────────────────────────────────

  Future<void> _testGoogleCredentials() async {
    final email = _googleEmailController.text.trim();
    final key = _googlePrivateKeyController.text.trim();
    if (email.isEmpty || key.isEmpty) {
      _showSnackBar('Please fill in both email and private key first.',
          backgroundColor: Colors.orange);
      return;
    }
    setState(() => _isTestingCredentials = true);
    try {
      final result = await GoogleAuth.testCredentials(
        email: email,
        privateKey: key,
      );
      if (!mounted) return;
      _showSnackBar(
        result.message,
        backgroundColor: result.success ? Colors.green : Colors.red,
      );
    } catch (e) {
      if (!mounted) return;
      _showSnackBar('Connection test failed: $e', backgroundColor: Colors.red);
    } finally {
      if (mounted) setState(() => _isTestingCredentials = false);
    }
  }

  Future<void> _saveGoogleCredentials() async {
    final email = _googleEmailController.text.trim();
    final key = _googlePrivateKeyController.text.trim();
    if (email.isEmpty || key.isEmpty) {
      _showSnackBar('Email and private key cannot be empty.',
          backgroundColor: Colors.orange);
      return;
    }
    // Need the parent state's sync guard — use a simple check
    if (SyncEngine.isSyncing) {
      final proceed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Sync in Progress'),
          content: const Text(
            'A sync is running. Save credentials now? The old token will '
            'remain valid until cache expiry, then the new credentials will be used.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Save Anyway'),
            ),
          ],
        ),
      );
      if (proceed != true) return;
    }

    await widget.appState.setGoogleServiceAccountCredentials(
      email: email,
      privateKey: key,
    );
    SyncEngine.signalConfigChanged();
    if (!mounted) return;
    _showSnackBar('Google credentials saved. A full re-sync will follow.',
        backgroundColor: Colors.green);
  }

  // ── Column Mapping ────────────────────────────────────────────

  Future<void> _loadColumnHeaders() async {
    final db = await DatabaseHelper.database;
    final sheetIdResult = await db.query(
      'app_settings',
      where: 'key = ?',
      whereArgs: ['sheets_id'],
    );
    final sheetTabResult = await db.query(
      'app_settings',
      where: 'key = ?',
      whereArgs: ['sheets_tab'],
    );
    if (sheetIdResult.isEmpty || sheetTabResult.isEmpty) {
      _showSnackBar(
        'Save the Sheet ID and Tab Name first.',
        backgroundColor: Colors.orange,
      );
      return;
    }

    final token = await GoogleAuth.getValidToken();
    if (token == null) {
      _showSnackBar(
        'Google authentication failed. Configure credentials first.',
        backgroundColor: Colors.red,
      );
      return;
    }

    setState(() => _isLoadingHeaders = true);
    try {
      final headers = await SheetsApi.fetchHeaderRow(
        token,
        sheetIdResult.first['value'] as String,
        sheetTabResult.first['value'] as String,
      );
      if (!mounted) return;
      if (headers == null || headers.isEmpty) {
        _showSnackBar('Could not fetch headers from the sheet.',
            backgroundColor: Colors.red);
        return;
      }
      setState(() {
        _detectedHeaders = headers;
        // Pre-fill overrides using current column map
        if (_workingOverrides.isEmpty) {
          for (final field in SheetColumnsFields.all) {
            if (headers.contains(field.defaultHeader)) {
              _workingOverrides[field.key] = field.defaultHeader;
            }
          }
        }
      });
      _showSnackBar(
        'Detected ${headers.length} columns. Map fields below.',
        backgroundColor: Colors.green,
      );
    } catch (e) {
      if (!mounted) return;
      _showSnackBar('Error: $e', backgroundColor: Colors.red);
    } finally {
      if (mounted) setState(() => _isLoadingHeaders = false);
    }
  }

  Future<void> _saveColumnOverrides() async {
    // Guard: don't overwrite col_map while a sync is reading it
    if (SyncEngine.isSyncing) {
      final proceed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Sync in Progress'),
          content: const Text(
            'A sync is running. Save column mapping now? The current '
            'sync will finish with the old mapping, then a full re-sync '
            'with the new mapping will start.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Save Anyway'),
            ),
          ],
        ),
      );
      if (proceed != true) return;
    }

    // Remove entries where the override matches the default (no customization)
    final cleaned = Map<String, String>.from(_workingOverrides);
    await widget.appState.setColumnHeaderOverrides(cleaned);
    SyncEngine.signalConfigChanged();

    // Re-detect column map with overrides
    final db = await DatabaseHelper.database;
    final token = await GoogleAuth.getValidToken();
    if (token != null) {
      final sheetIdResult = await db.query(
        'app_settings',
        where: 'key = ?',
        whereArgs: ['sheets_id'],
      );
      final sheetTabResult = await db.query(
        'app_settings',
        where: 'key = ?',
        whereArgs: ['sheets_tab'],
      );
      if (sheetIdResult.isNotEmpty && sheetTabResult.isNotEmpty) {
        try {
          await SheetsApi.detectColMap(
            db,
            token,
            sheetIdResult.first['value'] as String,
            sheetTabResult.first['value'] as String,
            headerOverrides: cleaned,
          );
          if (!mounted) return;
          _showSnackBar(
            'Column mapping saved. Existing col_map updated.',
            backgroundColor: Colors.green,
          );
          return;
        } catch (_) {}
      }
    }
    if (!mounted) return;
    _showSnackBar(
      'Column mapping saved. Run a sync to apply changes.',
      backgroundColor: Colors.green,
    );
  }

  // ── Event Profiles ────────────────────────────────────────────

  Future<void> _createNewProfile() async {
    final name = _profileNameController.text.trim();
    if (name.isEmpty) {
      _showSnackBar('Enter a profile name.', backgroundColor: Colors.orange);
      return;
    }

    final db = await DatabaseHelper.database;
    final sheetIdResult = await db.query(
      'app_settings',
      where: 'key = ?',
      whereArgs: ['sheets_id'],
    );
    final sheetTabResult = await db.query(
      'app_settings',
      where: 'key = ?',
      whereArgs: ['sheets_tab'],
    );

    // Capture the current column mapping to store with the profile
    final dbForProfile = await DatabaseHelper.database;
    final colMapResult = await dbForProfile.query(
      'app_settings',
      where: 'key = ?',
      whereArgs: ['col_map'],
    );
    final currentColMap =
        colMapResult.isNotEmpty ? colMapResult.first['value'] as String? : null;

    setState(() => _isSavingProfile = true);
    try {
      await widget.appState.createEventProfile(
        name: name,
        sheetsId: sheetIdResult.isNotEmpty
            ? sheetIdResult.first['value'] as String? ?? ''
            : '',
        sheetsTab: sheetTabResult.isNotEmpty
            ? sheetTabResult.first['value'] as String? ?? ''
            : '',
        eventName: widget.appState.eventName,
        organizationName: widget.appState.organizationName,
        colMapOverride: currentColMap,
        googleEmail: _googleEmailController.text.trim(),
        googlePrivateKey: _googlePrivateKeyController.text.trim(),
      );
      _profileNameController.clear();
      if (!mounted) return;
      _showSnackBar('Profile "$name" created.', backgroundColor: Colors.green);
    } catch (e) {
      if (!mounted) return;
      _showSnackBar('Failed to create profile: $e',
          backgroundColor: Colors.red);
    } finally {
      if (mounted) setState(() => _isSavingProfile = false);
    }
  }

  Future<void> _activateProfile(int profileId) async {
    await widget.appState.activateEventProfile(profileId);
    if (!mounted) return;
    setState(() {
      _selectedProfileId = profileId;
      _detectedHeaders = []; // Stale after profile switch
    });
    // Reload the credential fields
    _googleEmailController.text = widget.appState.googleServiceAccountEmail;
    _googlePrivateKeyController.text =
        widget.appState.googleServiceAccountPrivateKey;
    _workingOverrides.clear();
    _workingOverrides.addAll(widget.appState.columnHeaderOverrides);
    _showSnackBar('Profile activated. Re-syncing...',
        backgroundColor: Colors.green);
    // Trigger a full sync
    SyncEngine.performFullSync(widget.appState);
  }

  Future<void> _deleteProfile(int profileId) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Profile?'),
        content: const Text('This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await widget.appState.deleteEventProfile(profileId);
      if (!mounted) return;
      setState(() => _selectedProfileId = widget.appState.activeProfileId);
      _showSnackBar('Profile deleted.', backgroundColor: Colors.green);
    }
  }

  void _showSnackBar(String message, {Color? backgroundColor}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: backgroundColor),
    );
  }

  @override
  Widget build(BuildContext context) {
    final appState = widget.appState;
    final effectiveHeaders = _detectedHeaders.toList();

    return Card(
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        title: const Text(
          'Advanced Settings',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        subtitle: const Text(
          'Google credentials, column mapping, event profiles',
          style: TextStyle(color: Colors.grey),
        ),
        initiallyExpanded: _expanded,
        onExpansionChanged: (val) => setState(() => _expanded = val),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ══════ Google Service Account ══════
                const Divider(),
                const Text(
                  'Google Service Account',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.blue.withValues(alpha: 0.06),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: Colors.blue.withValues(alpha: 0.2),
                    ),
                  ),
                  child: const Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'How to enter credentials:',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      SizedBox(height: 4),
                      Text(
                        '1. Service Account Email — paste the full email '
                        '(e.g., scanner-bot@project.iam.gserviceaccount.com)',
                        style: TextStyle(fontSize: 13),
                      ),
                      SizedBox(height: 2),
                      Text(
                        '2. Private Key — paste the full key including '
                        '-----BEGIN PRIVATE KEY----- and -----END PRIVATE KEY-----\n'
                        r'Keep the \n escapes as-is from Google Cloud Console. '
                        'The app handles them automatically.',
                        style: TextStyle(fontSize: 13),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _googleEmailController,
                  decoration: InputDecoration(
                    labelText: 'Service Account Email',
                    hintText: 'name@project.iam.gserviceaccount.com',
                    border: const OutlineInputBorder(),
                    helperText: _googleEmailController.text.isEmpty &&
                            dotenv.env['GOOGLE_SERVICE_ACCOUNT_EMAIL'] == null
                        ? 'Not set. Your .env file is also empty — configure this to use Google Sheets.'
                        : null,
                  ),
                  keyboardType: TextInputType.emailAddress,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _googlePrivateKeyController,
                  decoration: const InputDecoration(
                    labelText: 'Private Key',
                    hintText:
                        '-----BEGIN PRIVATE KEY-----\nMIIEv...\\n-----END PRIVATE KEY-----',
                    border: OutlineInputBorder(),
                  ),
                  maxLines: 4,
                  minLines: 3,
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: _isTestingCredentials
                            ? null
                            : _testGoogleCredentials,
                        icon: _isTestingCredentials
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.wifi_tethering),
                        label: Text(
                          _isTestingCredentials
                              ? 'Testing...'
                              : 'Test Connection',
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: _saveGoogleCredentials,
                        icon: const Icon(Icons.save),
                        label: const Text('Save Credentials'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),

                // ══════ Column Mapping ══════
                const Divider(),
                const Text(
                  'Column Mapping',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  'If your sheet uses different column headers (e.g. '
                  '"Full Name" instead of "Name"), map them here.',
                  style: TextStyle(color: Colors.grey, fontSize: 13),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed:
                            _isLoadingHeaders ? null : _loadColumnHeaders,
                        icon: _isLoadingHeaders
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.table_chart),
                        label: Text(
                          _isLoadingHeaders
                              ? 'Loading...'
                              : 'Load Headers from Sheet',
                        ),
                      ),
                    ),
                  ],
                ),
                if (_detectedHeaders.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  ...SheetColumnsFields.all.map((field) {
                    final currentValue =
                        _workingOverrides[field.key] ?? field.defaultHeader;
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: DropdownButtonFormField<String>(
                        key: ValueKey('colmap_${field.key}_$currentValue'),
                        initialValue: effectiveHeaders.contains(currentValue)
                            ? currentValue
                            : null,
                        isExpanded: true,
                        decoration: InputDecoration(
                          labelText: field.label,
                          border: const OutlineInputBorder(),
                          helperText: 'Sheets header for "${field.key}"',
                        ),
                        items: [
                          const DropdownMenuItem(
                            child: Text('(not mapped)'),
                          ),
                          ...effectiveHeaders.map(
                            (h) => DropdownMenuItem(
                              value: h,
                              child: Text(
                                h,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),
                        ],
                        onChanged: (val) {
                          setState(() {
                            if (val != null) {
                              _workingOverrides[field.key] = val;
                            } else {
                              _workingOverrides.remove(field.key);
                            }
                          });
                        },
                      ),
                    );
                  }),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: _saveColumnOverrides,
                          icon: const Icon(Icons.save),
                          label: const Text('Save Column Mapping'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Flexible(
                        child: OutlinedButton.icon(
                          onPressed: () async {
                            await widget.appState.clearColumnHeaderOverrides();
                            if (!mounted) return;
                            setState(_workingOverrides.clear);
                            _showSnackBar(
                              'Column overrides cleared. Next sync will use raw headers.',
                              backgroundColor: Colors.orange,
                            );
                          },
                          icon: const Icon(Icons.clear),
                          label: const Text('Clear'),
                        ),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 16),

                // ══════ Event Profiles ══════
                const Divider(),
                const Text(
                  'Event Profiles',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Save the current configuration as a reusable profile. '
                  'Switch between profiles to change events without rebuilding the app.',
                  style: TextStyle(color: Colors.grey, fontSize: 13),
                ),
                const SizedBox(height: 12),
                // Profile selector
                if (appState.eventProfiles.isNotEmpty) ...[
                  DropdownButtonFormField<int>(
                    key: ValueKey('profile_$_selectedProfileId'),
                    initialValue: _selectedProfileId != null &&
                            appState.eventProfiles
                                .any((p) => p['id'] == _selectedProfileId)
                        ? _selectedProfileId
                        : null,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Active Profile',
                      border: OutlineInputBorder(),
                    ),
                    items: [
                      const DropdownMenuItem(
                        child: Text('(none)'),
                      ),
                      ...appState.eventProfiles.map(
                        (p) => DropdownMenuItem(
                          value: p['id'] as int,
                          child: Text(
                            (p['name'] as String?) ?? 'Unnamed',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                    ],
                    onChanged: (val) {
                      if (val != null) {
                        _activateProfile(val);
                      }
                    },
                  ),
                  const SizedBox(height: 8),
                  if (_selectedProfileId != null)
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton.icon(
                        onPressed: () => _deleteProfile(_selectedProfileId!),
                        icon: const Icon(Icons.delete_forever,
                            color: Colors.redAccent),
                        label: const Text(
                          'Delete Active Profile',
                          style: TextStyle(color: Colors.redAccent),
                        ),
                      ),
                    ),
                  const SizedBox(height: 8),
                ],
                // Create new profile
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _profileNameController,
                        decoration: const InputDecoration(
                          labelText: 'New Profile Name',
                          hintText: 'e.g. FSY 2027 Cebu',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: ElevatedButton.icon(
                        onPressed: _isSavingProfile ? null : _createNewProfile,
                        icon: _isSavingProfile
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.add),
                        label: Text(
                            _isSavingProfile ? 'Saving...' : 'Save as Profile'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Describes a single field that can be mapped to a sheet column.
class SheetColumnField {
  final String key;
  final String label;
  final String defaultHeader;
  const SheetColumnField({
    required this.key,
    required this.label,
    required this.defaultHeader,
  });
}

/// All fields that can be remapped in the column mapping editor.
class SheetColumnsFields {
  static const all = <SheetColumnField>[
    SheetColumnField(
      key: 'ID',
      label: 'Participant ID',
      defaultHeader: 'ID',
    ),
    SheetColumnField(
      key: 'QR Code',
      label: 'QR Code',
      defaultHeader: 'QR Code',
    ),
    SheetColumnField(
      key: 'Stake',
      label: 'Stake',
      defaultHeader: 'Stake',
    ),
    SheetColumnField(
      key: 'Ward',
      label: 'Ward',
      defaultHeader: 'Ward',
    ),
    SheetColumnField(
      key: 'Name',
      label: 'Name',
      defaultHeader: 'Name',
    ),
    SheetColumnField(
      key: 'Gender',
      label: 'Gender',
      defaultHeader: 'Gender',
    ),
    SheetColumnField(
      key: 'Registered',
      label: 'Registered',
      defaultHeader: 'Registered',
    ),
    SheetColumnField(
      key: 'Signed by',
      label: 'Signed by',
      defaultHeader: 'Signed by',
    ),
    SheetColumnField(
      key: 'Status',
      label: 'Status',
      defaultHeader: 'Status',
    ),
    SheetColumnField(
      key: 'Medical/Food Info',
      label: 'Medical/Food Info',
      defaultHeader: 'Medical/Food Info',
    ),
    SheetColumnField(
      key: 'Note',
      label: 'Note',
      defaultHeader: 'Note',
    ),
    SheetColumnField(
      key: 'T-Shirt Size',
      label: 'T-Shirt Size',
      defaultHeader: 'T-Shirt Size',
    ),
    SheetColumnField(
      key: 'Age',
      label: 'Age',
      defaultHeader: 'Age',
    ),
    SheetColumnField(
      key: 'Birthday',
      label: 'Birthday',
      defaultHeader: 'Birthday',
    ),
    SheetColumnField(
      key: 'Group Number',
      label: 'Group/Table Number',
      defaultHeader: 'Group Number',
    ),
    SheetColumnField(
      key: 'Hotel Room Number',
      label: 'Hotel Room Number',
      defaultHeader: 'Hotel Room Number',
    ),
    SheetColumnField(
      key: 'Verified At',
      label: 'Verified At',
      defaultHeader: 'Verified At',
    ),
    SheetColumnField(
      key: 'Printed At',
      label: 'Printed At',
      defaultHeader: 'Printed At',
    ),
    SheetColumnField(
      key: 'Device ID',
      label: 'Device ID',
      defaultHeader: 'Device ID',
    ),
  ];
}
