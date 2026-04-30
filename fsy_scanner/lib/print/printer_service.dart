import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:blue_thermal_printer/blue_thermal_printer.dart';
import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:sqflite/sqflite.dart';

import '../db/database_helper.dart';
import '../db/participants_dao.dart';
import '../db/sync_queue_dao.dart';
import '../models/participant.dart';
import 'receipt_builder.dart';

class PrinterService {
  static const String _eventNameKey = 'event_name';
  static const String _organizationNameKey = 'organization_name';
  static const String _printerAddressKey = 'printer_address';
  static const String _failedPrintJobsKey = 'failed_print_jobs';

  static const String cutModeOff = 'off';
  static const String cutModeSafe = 'safe';
  static const String cutModeForce = 'force';

  static const String _failureNoPrinter = 'no_printer_selected';
  static const String _failurePermissionRequired =
      'bluetooth_permission_required';
  static const String _failureNotPaired = 'printer_not_paired';
  static const String _failureConnectFailed = 'connect_failed';
  static const String _failureWriteFailed = 'write_failed';
  static const Duration _monitorInterval = Duration(seconds: 8);

  static final BlueThermalPrinter _printer = BlueThermalPrinter.instance;
  static final StreamController<PrinterServiceEvent> _eventController =
      StreamController<PrinterServiceEvent>.broadcast();

  static BluetoothDevice? _connectedDevice;
  static bool _isConnecting = false;
  static bool _failedJobsLoaded = false;
  static bool _automationStarted = false;
  static bool _automationCycleRunning = false;
  static bool _isQueueDraining = false;
  static final Map<String, bool> _pendingPrints = <String, bool>{};
  static final Set<String> _cancelledPrints = <String>{};
  static final List<_FailedPrintJob> _failedJobs = <_FailedPrintJob>[];
  static Timer? _monitorTimer;

  static Stream<PrinterServiceEvent> get events => _eventController.stream;

  static Future<void> startAutomation() async {
    await _loadFailedJobs();
    if (!_automationStarted) {
      _automationStarted = true;
      _monitorTimer?.cancel();
      _monitorTimer = Timer.periodic(_monitorInterval, (_) {
        unawaited(_runAutomationCycle());
      });
    }
    await _runAutomationCycle();
  }

  static Future<void> stopAutomation() async {
    _monitorTimer?.cancel();
    _monitorTimer = null;
    _automationStarted = false;
  }

  static Future<bool> ensureBluetoothPermissions() async {
    return _checkBluetoothPermissions(requestIfMissing: true);
  }

  static Future<bool> hasBluetoothPermissionsGranted() async {
    return _checkBluetoothPermissions(requestIfMissing: false);
  }

  static Future<void> saveSelectedPrinter(BluetoothDevice device) async {
    final address = device.address;
    if (address == null || address.isEmpty) {
      return;
    }

    final db = await DatabaseHelper.database;
    await db.insert(
      'app_settings',
      {'key': _printerAddressKey, 'value': address},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    await _emitStateChanged();
  }

  static Future<String?> getSelectedPrinterAddress() async {
    final db = await DatabaseHelper.database;
    final result = await db.query(
      'app_settings',
      where: 'key = ?',
      whereArgs: [_printerAddressKey],
      limit: 1,
    );

    if (result.isEmpty) {
      return null;
    }

    final value = result.first['value'] as String?;
    if (value == null || value.isEmpty) {
      return null;
    }
    return value;
  }

  static String _cutModeKey(String printerAddress) {
    final safeAddress = printerAddress.replaceAll(':', '_');
    return 'printer_cut_mode_$safeAddress';
  }

  static Future<String> getCutMode(String printerAddress) async {
    final db = await DatabaseHelper.database;
    final result = await db.query(
      'app_settings',
      where: 'key = ?',
      whereArgs: [_cutModeKey(printerAddress)],
      limit: 1,
    );
    if (result.isEmpty) {
      return cutModeOff;
    }

    final value = result.first['value'] as String?;
    if (value == cutModeSafe || value == cutModeForce) {
      return value!;
    }
    return cutModeOff;
  }

  static Future<void> setCutMode(String printerAddress, String mode) async {
    if (mode != cutModeOff && mode != cutModeSafe && mode != cutModeForce) {
      throw ArgumentError.value(mode, 'mode', 'Unsupported cut mode');
    }

    final db = await DatabaseHelper.database;
    await db.insert(
      'app_settings',
      {'key': _cutModeKey(printerAddress), 'value': mode},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    debugPrint('[PrinterService] Cut mode for $printerAddress set to $mode');
  }

  static Future<List<BluetoothDevice>> _getBondedDevicesUnsafe() async {
    final devices = await _printer.getBondedDevices();
    final filtered =
        devices.where((device) => (device.address ?? '').isNotEmpty).toList()
          ..sort((a, b) {
            final left = '${a.name ?? ''}${a.address ?? ''}'.toLowerCase();
            final right = '${b.name ?? ''}${b.address ?? ''}'.toLowerCase();
            return left.compareTo(right);
          });
    return filtered;
  }

  static BluetoothDevice? _findDeviceByAddress(
      List<BluetoothDevice> devices, String address) {
    for (final device in devices) {
      if (device.address == address) {
        return device;
      }
    }
    return null;
  }

  static Future<List<BluetoothDevice>> scanPrinters() async {
    final granted = await ensureBluetoothPermissions();
    if (!granted) {
      debugPrint('[PrinterService] Bluetooth permission not granted');
      return <BluetoothDevice>[];
    }
    return _scanPrintersWithoutPrompt();
  }

  static Future<List<BluetoothDevice>> _scanPrintersWithoutPrompt() async {
    try {
      final devices = await _getBondedDevicesUnsafe();
      debugPrint('[PrinterService] Found ${devices.length} bonded devices');
      return devices;
    } catch (e) {
      debugPrint('[PrinterService] Scan error: $e');
      return <BluetoothDevice>[];
    }
  }

  static Future<PrinterConnectionResult> connect(
    BluetoothDevice device, {
    bool rememberSelection = false,
    bool requestPermissions = true,
  }) async {
    final address = device.address;
    if (address == null || address.isEmpty) {
      return const PrinterConnectionResult(
        success: false,
        message:
            'The selected printer does not expose a valid Bluetooth address.',
      );
    }

    final granted = await _checkBluetoothPermissions(
      requestIfMissing: requestPermissions,
    );
    if (!granted) {
      return const PrinterConnectionResult(
        success: false,
        message:
            'Bluetooth permission is required before connecting to a printer.',
      );
    }

    if (rememberSelection) {
      await saveSelectedPrinter(device);
    }

    _isConnecting = true;
    try {
      if (_connectedDevice != null) {
        try {
          await _printer.disconnect();
        } catch (_) {}
        _connectedDevice = null;
      }

      final connected = await _printer.connect(device);
      if (connected) {
        _connectedDevice = device;
        debugPrint('[PrinterService] Connected to ${device.name}');
        await _emitStateChanged();
        unawaited(_drainQueuedJobs());
        return PrinterConnectionResult(
          success: true,
          message: rememberSelection
              ? 'Connected to ${device.name ?? 'the selected printer'}'
              : 'Connected to ${device.name ?? 'the printer'}',
          device: device,
        );
      }

      await _emitStateChanged();
      return PrinterConnectionResult(
        success: false,
        message: 'Could not connect to ${device.name ?? 'the printer'}.',
        device: device,
      );
    } catch (e) {
      debugPrint('[PrinterService] Connection error: $e');
      await _emitStateChanged();
      return PrinterConnectionResult(
        success: false,
        message: 'Connection failed: $e',
        device: device,
      );
    } finally {
      _isConnecting = false;
    }
  }

  static Future<bool> get isConnected async {
    try {
      return (await _printer.isConnected) == true;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> _ensureConnected(
    String address, {
    bool requestPermissions = true,
  }) async {
    if (_connectedDevice?.address == address) {
      try {
        final connected = await _printer.isConnected;
        if (connected == true) {
          return true;
        }
      } catch (_) {}
    }

    if (_isConnecting) {
      for (int i = 0; i < 5; i++) {
        await Future.delayed(const Duration(milliseconds: 200));
        if (_connectedDevice?.address == address) {
          try {
            if ((await _printer.isConnected) == true) {
              return true;
            }
          } catch (_) {}
        }
      }
      return false;
    }

    final granted = await _checkBluetoothPermissions(
      requestIfMissing: requestPermissions,
    );
    if (!granted) {
      return false;
    }

    _isConnecting = true;
    try {
      if (_connectedDevice != null) {
        try {
          await _printer.disconnect();
        } catch (_) {}
        _connectedDevice = null;
      }

      final devices = await _getBondedDevicesUnsafe();
      final device = _findDeviceByAddress(devices, address);
      if (device == null) {
        debugPrint(
            '[PrinterService] Printer $address not found in bonded devices');
        return false;
      }

      final result = await connect(
        device,
        requestPermissions: requestPermissions,
      );
      return result.success;
    } catch (e) {
      debugPrint('[PrinterService] Auto-connect error: $e');
      return false;
    } finally {
      _isConnecting = false;
    }
  }

  static Future<PrinterStatusSnapshot> getSelectedPrinterStatus({
    bool requestPermissions = true,
  }) async {
    final address = await getSelectedPrinterAddress();
    if (address == null) {
      return const PrinterStatusSnapshot(
        hasSelection: false,
        permissionsGranted: true,
        isPaired: false,
        isConnected: false,
        message: 'No printer selected',
      );
    }

    final granted = await _checkBluetoothPermissions(
      requestIfMissing: requestPermissions,
    );
    if (!granted) {
      return PrinterStatusSnapshot(
        hasSelection: true,
        selectedAddress: address,
        permissionsGranted: false,
        isPaired: false,
        isConnected: false,
        message: 'Bluetooth permission required',
      );
    }

    try {
      final devices = await _getBondedDevicesUnsafe();
      final device = _findDeviceByAddress(devices, address);
      if (device == null) {
        return PrinterStatusSnapshot(
          hasSelection: true,
          selectedAddress: address,
          permissionsGranted: true,
          isPaired: false,
          isConnected: false,
          message: 'Selected printer is not paired in Android settings',
        );
      }

      final connected =
          _connectedDevice?.address == address && await isConnected;
      return PrinterStatusSnapshot(
        hasSelection: true,
        selectedAddress: address,
        permissionsGranted: true,
        isPaired: true,
        isConnected: connected,
        device: device,
        message: connected ? 'Connected' : 'Paired and ready',
      );
    } catch (e) {
      return PrinterStatusSnapshot(
        hasSelection: true,
        selectedAddress: address,
        permissionsGranted: true,
        isPaired: false,
        isConnected: false,
        message: 'Unable to check printer status: $e',
      );
    }
  }

  static Future<PrintReceiptResult> printReceipt(
    Participant participant,
    String deviceId, {
    bool isReprint = false,
  }) async {
    return _attemptPrint(
      participant,
      deviceId,
      isReprint: isReprint,
    );
  }

  static Future<PrintReceiptResult> _attemptPrint(
    Participant participant,
    String deviceId, {
    required bool isReprint,
    _FailedPrintJob? retryJob,
  }) async {
    await _loadFailedJobs();
    _cancelledPrints.remove(participant.id);
    _pendingPrints[participant.id] = false;

    try {
      debugPrint('[PrinterService] Starting print for ${participant.fullName}');

      final eventDetails = await _loadEventDetails();
      final printerAddress = await getSelectedPrinterAddress();
      if (printerAddress == null) {
        return _queueAndReturnFailure(
          participant,
          deviceId,
          isReprint: isReprint,
          retryJob: retryJob,
          failure: const _QueuedFailure(
            code: _failureNoPrinter,
            reason: 'No printer selected',
            userMessage:
                'No printer selected. The receipt was queued for retry.',
          ),
        );
      }

      final status = await getSelectedPrinterStatus();
      if (!status.permissionsGranted) {
        return _queueAndReturnFailure(
          participant,
          deviceId,
          isReprint: isReprint,
          retryJob: retryJob,
          failure: const _QueuedFailure(
            code: _failurePermissionRequired,
            reason: 'Bluetooth permission required',
            userMessage:
                'Bluetooth permission is required before printing. The receipt was queued for retry.',
          ),
        );
      }

      if (!status.isPaired) {
        return _queueAndReturnFailure(
          participant,
          deviceId,
          isReprint: isReprint,
          retryJob: retryJob,
          failure: const _QueuedFailure(
            code: _failureNotPaired,
            reason: 'Selected printer is not paired',
            userMessage:
                'The selected printer is not paired in Android settings. The receipt was queued for retry.',
          ),
        );
      }

      if (_wasPrintCancelled(participant.id)) {
        return const PrintReceiptResult(
          success: false,
          queuedForRetry: false,
          message:
              'Print cancelled because the participant was de-verified before printing started.',
        );
      }

      final connected = await _ensureConnected(printerAddress);
      if (!connected) {
        return _queueAndReturnFailure(
          participant,
          deviceId,
          isReprint: isReprint,
          retryJob: retryJob,
          failure: const _QueuedFailure(
            code: _failureConnectFailed,
            reason: 'Could not connect to the selected printer',
            userMessage:
                'Could not connect to the selected printer. The receipt was queued for retry.',
          ),
        );
      }

      if (_wasPrintCancelled(participant.id)) {
        return const PrintReceiptResult(
          success: false,
          queuedForRetry: false,
          message:
              'Print cancelled because the participant was de-verified before printing started.',
        );
      }

      _pendingPrints[participant.id] = true;
      final receiptLines = ReceiptBuilder.buildLines(
        participant,
        eventDetails.eventName,
        eventDetails.organizationName,
        deviceId,
      );
      await _printReceiptLines(receiptLines, printerAddress);

      final now = DateTime.now().millisecondsSinceEpoch;
      final recorded = await _onPrintSuccess(participant, now);
      if (retryJob != null) {
        await _removeQueuedJob(retryJob.jobId);
      }

      debugPrint('[PrinterService] Print successful');
      if (!recorded) {
        await _emitStateChanged();
        return const PrintReceiptResult(
          success: true,
          queuedForRetry: false,
          message:
              'Receipt printed, but the local print state could not be updated.',
        );
      }

      await _emitStateChanged();
      return const PrintReceiptResult(
        success: true,
        queuedForRetry: false,
        message: 'Receipt printed successfully.',
      );
    } catch (e) {
      debugPrint('[PrinterService] Print failed: $e');
      return _queueAndReturnFailure(
        participant,
        deviceId,
        isReprint: isReprint,
        retryJob: retryJob,
        failure: _failureFromException(e),
      );
    } finally {
      _pendingPrints.remove(participant.id);
      _cancelledPrints.remove(participant.id);
    }
  }

  static void cancelPendingPrint(String participantId) {
    final hasStarted = _pendingPrints[participantId] ?? false;
    if (!hasStarted) {
      _cancelledPrints.add(participantId);
    }
  }

  static bool _wasPrintCancelled(String participantId) {
    return _cancelledPrints.contains(participantId);
  }

  static Future<void> _loadFailedJobs() async {
    if (_failedJobsLoaded) {
      return;
    }

    final db = await DatabaseHelper.database;
    final result = await db.query(
      'app_settings',
      where: 'key = ?',
      whereArgs: [_failedPrintJobsKey],
      limit: 1,
    );

    _failedJobs
      ..clear()
      ..addAll(() {
        if (result.isEmpty) {
          return const <_FailedPrintJob>[];
        }

        final raw = result.first['value'] as String?;
        if (raw == null || raw.isEmpty) {
          return const <_FailedPrintJob>[];
        }

        try {
          final decoded = jsonDecode(raw) as List<dynamic>;
          return decoded
              .whereType<Map<String, dynamic>>()
              .map(_FailedPrintJob.fromJson)
              .toList();
        } catch (_) {
          return const <_FailedPrintJob>[];
        }
      }());

    _failedJobsLoaded = true;
  }

  static Future<void> _saveFailedJobs() async {
    final db = await DatabaseHelper.database;
    await db.insert(
      'app_settings',
      {
        'key': _failedPrintJobsKey,
        'value': jsonEncode(_failedJobs.map((job) => job.toJson()).toList()),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  static Future<void> _queueFailedJob(
    Participant participant,
    String deviceId,
    _QueuedFailure failure, {
    required bool isReprint,
    _FailedPrintJob? retryJob,
  }) async {
    await _loadFailedJobs();
    final now = DateTime.now().millisecondsSinceEpoch;
    final existingIndex = _failedJobs.indexWhere((job) =>
        job.matchesParticipant(participant.id, isReprint: isReprint) ||
        job.jobId == retryJob?.jobId);

    final previous =
        existingIndex == -1 ? retryJob : _failedJobs[existingIndex];
    final attemptCount = (previous?.attemptCount ?? 0) + 1;
    final queuedJob =
        (previous ?? _FailedPrintJob.newJob(participant, deviceId)).copyWith(
      participant: participant,
      deviceId: deviceId,
      failureCode: failure.code,
      reason: failure.reason,
      isReprint: isReprint,
      lastAttemptAt: now,
      attemptCount: attemptCount,
      nextRetryAt: now + _retryDelayForAttempt(attemptCount).inMilliseconds,
    );

    if (existingIndex == -1) {
      _failedJobs.add(queuedJob);
    } else {
      _failedJobs[existingIndex] = queuedJob;
    }

    await _saveFailedJobs();
    await _emitStateChanged();
  }

  static Future<void> _removeQueuedJob(String jobId) async {
    await _loadFailedJobs();
    _failedJobs.removeWhere((job) => job.jobId == jobId);
    await _saveFailedJobs();
    await _emitStateChanged();
  }

  static Future<PrinterRetrySummary> retryFailedPrints() async {
    return _drainQueuedJobs(ignoreBackoff: true);
  }

  static Future<PrinterRetrySummary> _drainQueuedJobs({
    bool ignoreBackoff = false,
  }) async {
    await _loadFailedJobs();
    if (_isQueueDraining || _failedJobs.isEmpty) {
      return PrinterRetrySummary(
        attempted: 0,
        succeeded: 0,
        remaining: _failedJobs.length,
      );
    }

    _isQueueDraining = true;
    int attempted = 0;
    int succeeded = 0;

    try {
      final now = DateTime.now().millisecondsSinceEpoch;
      final jobs = List<_FailedPrintJob>.from(_failedJobs)
          .where((job) => ignoreBackoff || job.isReady(now))
          .toList()
        ..sort((a, b) => a.queuedAt.compareTo(b.queuedAt));

      for (final job in jobs) {
        attempted++;
        final retryParticipant =
            await _resolveRetryParticipant(job.participant.id, job.isReprint);
        if (retryParticipant == null) {
          await _removeQueuedJob(job.jobId);
          continue;
        }

        final result = await _attemptPrint(
          retryParticipant,
          job.deviceId,
          isReprint: job.isReprint,
          retryJob: job,
        );
        if (result.success) {
          succeeded++;
        }
      }
    } finally {
      _isQueueDraining = false;
      await _emitStateChanged();
    }

    return PrinterRetrySummary(
      attempted: attempted,
      succeeded: succeeded,
      remaining: _failedJobs.length,
    );
  }

  static Future<int> getFailedJobCount() async {
    await _loadFailedJobs();
    return _failedJobs.length;
  }

  static Future<bool> _onPrintSuccess(
      Participant participant, int printedAt) async {
    try {
      final db = await DatabaseHelper.database;
      final dao = ParticipantsDao(db);
      final currentParticipant = await dao.getParticipantById(participant.id);
      if (currentParticipant == null || currentParticipant.verifiedAt == null) {
        debugPrint(
            '[PrinterService] Skipping print-state update for ${participant.id} because the participant is no longer verified');
        return true;
      }

      await dao.markPrintedLocally(participant.id, printedAt);

      await SyncQueueDao.enqueueTask(
        SyncQueueDao.typeMarkPrinted,
        {
          'participantId': participant.id,
          'sheetsRow': participant.sheetsRow,
          'printedAt': printedAt,
        },
      );
      return true;
    } catch (e) {
      debugPrint('[PrinterService] Error recording print: $e');
      return false;
    }
  }

  static Future<PrintReceiptResult> printDiagnosticProbe() async {
    try {
      final printerAddress = await getSelectedPrinterAddress();
      if (printerAddress == null) {
        return const PrintReceiptResult(
          success: false,
          queuedForRetry: false,
          message: 'No printer selected for the diagnostic test.',
        );
      }

      final status = await getSelectedPrinterStatus();
      if (!status.permissionsGranted) {
        return const PrintReceiptResult(
          success: false,
          queuedForRetry: false,
          message:
              'Bluetooth permission is required before the diagnostic test.',
        );
      }

      if (!status.isPaired) {
        return const PrintReceiptResult(
          success: false,
          queuedForRetry: false,
          message: 'The selected printer is not paired in Android settings.',
        );
      }

      final connected = await _ensureConnected(printerAddress);
      if (!connected) {
        return const PrintReceiptResult(
          success: false,
          queuedForRetry: false,
          message: 'Could not connect to the selected printer.',
        );
      }

      await _printer.writeBytes(
        Uint8List.fromList(<int>[
          0x1B,
          0x40,
          0x1B,
          0x61,
          0x01,
          ...ascii.encode('DIAGNOSTIC TEST'),
          0x0D,
          0x0A,
          0x1B,
          0x61,
          0x00,
          ...ascii.encode('TEST'),
          0x0D,
          0x0A,
          ...ascii.encode('1234567890'),
          0x0D,
          0x0A,
          ...ascii.encode('ABCDEFGHIJKLMNOPQRSTUVWXYZ'),
          0x0D,
          0x0A,
          ...ascii.encode('abcdefghijklmnopqrstuvwxyz'),
          0x0D,
          0x0A,
          ...ascii.encode('--------------------------------'),
          0x0D,
          0x0A,
          0x0A,
          0x0A,
          0x0A,
        ]),
      );

      return const PrintReceiptResult(
        success: true,
        queuedForRetry: false,
        message:
            'Diagnostic print sent. If the paper is still blank, the issue is likely paper orientation/type or printer hardware.',
      );
    } catch (e) {
      debugPrint('[PrinterService] Diagnostic print failed: $e');
      return PrintReceiptResult(
        success: false,
        queuedForRetry: false,
        message: 'Diagnostic print failed: $e',
      );
    }
  }

  static Future<void> _applyCutMode(String printerAddress) async {
    final cutMode = await getCutMode(printerAddress);
    try {
      switch (cutMode) {
        case cutModeForce:
          await _printer.writeBytes(
            Uint8List.fromList(<int>[0x1D, 0x56, 0x00]),
          );
          break;
        case cutModeSafe:
          await _printer.writeBytes(
            Uint8List.fromList(<int>[0x1D, 0x56, 0x01]),
          );
          break;
        case cutModeOff:
        default:
          break;
      }
    } catch (e) {
      debugPrint(
          '[PrinterService] Cut command failed, falling back to feed: $e');
      await _printer.writeBytes(
        Uint8List.fromList(<int>[0x0A]),
      );
    }
  }

  static Future<void> _printReceiptLines(
    List<ReceiptLine> lines,
    String printerAddress,
  ) async {
    await _printer.writeBytes(
      Uint8List.fromList(<int>[
        0x1B,
        0x40,
        0x1B,
        0x61,
        0x00,
      ]),
    );

    for (final line in lines) {
      final bytes = <int>[
        0x1B,
        0x61,
        line.align.clamp(0, 2),
        ...ascii.encode(line.text),
        0x0D,
        0x0A,
      ];
      await _printer.writeBytes(Uint8List.fromList(bytes));
    }

    await _printer.writeBytes(
      Uint8List.fromList(<int>[
        0x1D,
        0x21,
        0x00,
        0x1B,
        0x61,
        0x00,
        0x0A,
      ]),
    );
    await _applyCutMode(printerAddress);
  }

  static Future<_EventDetails> _loadEventDetails() async {
    final db = await DatabaseHelper.database;
    final eventResult = await db.query(
      'app_settings',
      where: 'key = ?',
      whereArgs: [_eventNameKey],
      limit: 1,
    );
    final organizationResult = await db.query(
      'app_settings',
      where: 'key = ?',
      whereArgs: [_organizationNameKey],
      limit: 1,
    );

    return _EventDetails(
      eventName: eventResult.isNotEmpty
          ? eventResult.first['value'] as String
          : 'FSY Event',
      organizationName: organizationResult.isNotEmpty
          ? organizationResult.first['value'] as String? ?? ''
          : '',
    );
  }

  static Future<bool> _checkBluetoothPermissions({
    required bool requestIfMissing,
  }) async {
    if (!Platform.isAndroid) {
      return true;
    }

    final permissions = <Permission>[
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.location,
    ];

    if (requestIfMissing) {
      final statuses = await permissions.request();
      return statuses.values.every((status) => status.isGranted);
    }

    final statuses = await Future.wait(
      permissions.map((permission) => permission.status),
    );
    return statuses.every((status) => status.isGranted);
  }

  static Future<void> _runAutomationCycle() async {
    if (_automationCycleRunning) {
      return;
    }

    _automationCycleRunning = true;
    try {
      await _loadFailedJobs();
      final permissionsGranted = await hasBluetoothPermissionsGranted();
      if (!permissionsGranted) {
        return;
      }

      await _autoSelectPrinterIfNeeded();
      final status = await getSelectedPrinterStatus(requestPermissions: false);
      if (status.hasSelection && status.isPaired && !status.isConnected) {
        await _ensureConnected(
          status.selectedAddress!,
          requestPermissions: false,
        );
      }

      final refreshedStatus =
          await getSelectedPrinterStatus(requestPermissions: false);
      if (refreshedStatus.isConnected) {
        await _drainQueuedJobs();
      }
    } finally {
      _automationCycleRunning = false;
      await _emitStateChanged();
    }
  }

  static Future<void> _autoSelectPrinterIfNeeded() async {
    final selectedAddress = await getSelectedPrinterAddress();
    if (selectedAddress != null) {
      return;
    }

    final printers = await _scanPrintersWithoutPrompt();
    if (printers.length != 1) {
      return;
    }

    await saveSelectedPrinter(printers.first);
    await _ensureConnected(
      printers.first.address!,
      requestPermissions: false,
    );
  }

  static Duration _retryDelayForAttempt(int attemptCount) {
    var seconds = 15;
    for (int i = 1; i < attemptCount; i++) {
      seconds *= 2;
      if (seconds >= 900) {
        seconds = 900;
        break;
      }
    }
    return Duration(seconds: seconds);
  }

  static _QueuedFailure _failureFromException(Object error) {
    final message = error.toString();
    return _QueuedFailure(
      code: _failureWriteFailed,
      reason: message,
      userMessage: 'Print failed: $message. The receipt was queued for retry.',
    );
  }

  static Future<Participant?> _resolveRetryParticipant(
    String participantId,
    bool isReprint,
  ) async {
    final db = await DatabaseHelper.database;
    final dao = ParticipantsDao(db);
    final currentParticipant = await dao.getParticipantById(participantId);
    if (currentParticipant == null) {
      return null;
    }
    if (currentParticipant.verifiedAt == null) {
      return null;
    }
    if (!isReprint && currentParticipant.printedAt != null) {
      return null;
    }
    return currentParticipant;
  }

  static Future<PrintReceiptResult> _queueAndReturnFailure(
    Participant participant,
    String deviceId, {
    required bool isReprint,
    required _QueuedFailure failure,
    _FailedPrintJob? retryJob,
  }) async {
    await _queueFailedJob(
      participant,
      deviceId,
      failure,
      isReprint: isReprint,
      retryJob: retryJob,
    );
    return PrintReceiptResult(
      success: false,
      queuedForRetry: true,
      message: failure.userMessage,
    );
  }

  static Future<void> _emitStateChanged() async {
    await _loadFailedJobs();
    final status = await getSelectedPrinterStatus(requestPermissions: false);
    _eventController.add(
      PrinterServiceEvent(
        selectedAddress: status.selectedAddress,
        isConnected: status.isConnected,
        failedJobCount: _failedJobs.length,
        statusMessage: status.message,
      ),
    );
  }
}

class PrinterConnectionResult {
  final bool success;
  final String message;
  final BluetoothDevice? device;

  const PrinterConnectionResult({
    required this.success,
    required this.message,
    this.device,
  });
}

class PrinterStatusSnapshot {
  final bool hasSelection;
  final String? selectedAddress;
  final bool permissionsGranted;
  final bool isPaired;
  final bool isConnected;
  final BluetoothDevice? device;
  final String message;

  const PrinterStatusSnapshot({
    required this.hasSelection,
    this.selectedAddress,
    required this.permissionsGranted,
    required this.isPaired,
    required this.isConnected,
    this.device,
    required this.message,
  });
}

class PrinterServiceEvent {
  final String? selectedAddress;
  final bool isConnected;
  final int failedJobCount;
  final String statusMessage;

  const PrinterServiceEvent({
    required this.selectedAddress,
    required this.isConnected,
    required this.failedJobCount,
    required this.statusMessage,
  });
}

class PrintReceiptResult {
  final bool success;
  final bool queuedForRetry;
  final String message;

  const PrintReceiptResult({
    required this.success,
    required this.queuedForRetry,
    required this.message,
  });
}

class PrinterRetrySummary {
  final int attempted;
  final int succeeded;
  final int remaining;

  const PrinterRetrySummary({
    required this.attempted,
    required this.succeeded,
    required this.remaining,
  });
}

class _EventDetails {
  final String eventName;
  final String organizationName;

  const _EventDetails({
    required this.eventName,
    required this.organizationName,
  });
}

class _QueuedFailure {
  final String code;
  final String reason;
  final String userMessage;

  const _QueuedFailure({
    required this.code,
    required this.reason,
    required this.userMessage,
  });
}

class _FailedPrintJob {
  final String jobId;
  final Participant participant;
  final String deviceId;
  final String failureCode;
  final String reason;
  final int queuedAt;
  final int attemptCount;
  final int? lastAttemptAt;
  final int nextRetryAt;
  final bool isReprint;

  const _FailedPrintJob({
    required this.jobId,
    required this.participant,
    required this.deviceId,
    required this.failureCode,
    required this.reason,
    required this.queuedAt,
    required this.attemptCount,
    required this.lastAttemptAt,
    required this.nextRetryAt,
    required this.isReprint,
  });

  factory _FailedPrintJob.newJob(Participant participant, String deviceId) {
    final now = DateTime.now().millisecondsSinceEpoch;
    return _FailedPrintJob(
      jobId: '${DateTime.now().microsecondsSinceEpoch}-${participant.id}',
      participant: participant,
      deviceId: deviceId,
      failureCode: '',
      reason: '',
      queuedAt: now,
      attemptCount: 0,
      lastAttemptAt: null,
      nextRetryAt: now,
      isReprint: false,
    );
  }

  bool matchesParticipant(String participantId, {required bool isReprint}) {
    return participant.id == participantId && this.isReprint == isReprint;
  }

  bool isReady(int now) => nextRetryAt <= now;

  _FailedPrintJob copyWith({
    Participant? participant,
    String? deviceId,
    String? failureCode,
    String? reason,
    int? attemptCount,
    int? lastAttemptAt,
    int? nextRetryAt,
    bool? isReprint,
  }) {
    return _FailedPrintJob(
      jobId: jobId,
      participant: participant ?? this.participant,
      deviceId: deviceId ?? this.deviceId,
      failureCode: failureCode ?? this.failureCode,
      reason: reason ?? this.reason,
      queuedAt: queuedAt,
      attemptCount: attemptCount ?? this.attemptCount,
      lastAttemptAt: lastAttemptAt ?? this.lastAttemptAt,
      nextRetryAt: nextRetryAt ?? this.nextRetryAt,
      isReprint: isReprint ?? this.isReprint,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'job_id': jobId,
      'participant': participant.toJson(),
      'device_id': deviceId,
      'failure_code': failureCode,
      'reason': reason,
      'queued_at': queuedAt,
      'attempt_count': attemptCount,
      'last_attempt_at': lastAttemptAt,
      'next_retry_at': nextRetryAt,
      'is_reprint': isReprint,
    };
  }

  factory _FailedPrintJob.fromJson(Map<String, dynamic> json) {
    final queuedAt = json['queued_at'] as int? ?? 0;
    final attemptCount = json['attempt_count'] as int? ?? 0;
    final nextRetryAt = json['next_retry_at'] as int? ?? queuedAt;
    return _FailedPrintJob(
      jobId: json['job_id'] as String? ?? '',
      participant: Participant.fromJson(
        Map<String, dynamic>.from(json['participant'] as Map<dynamic, dynamic>),
      ),
      deviceId: json['device_id'] as String? ?? '',
      failureCode: json['failure_code'] as String? ?? '',
      reason: json['reason'] as String? ?? '',
      queuedAt: queuedAt,
      attemptCount: attemptCount,
      lastAttemptAt: json['last_attempt_at'] as int?,
      nextRetryAt: nextRetryAt,
      isReprint: json['is_reprint'] as bool? ?? false,
    );
  }
}
