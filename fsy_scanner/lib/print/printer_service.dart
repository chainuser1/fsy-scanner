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
  static const String _lastPrintSuccessAtKey = 'printer_last_print_success_at';
  static const String _lastPrintFailureAtKey = 'printer_last_print_failure_at';
  static const String _lastPrintFailureReasonKey =
      'printer_last_print_failure_reason';
  static const String _lastPrintFailureCodeKey =
      'printer_last_print_failure_code';
  static const String _lastConnectionVerifiedAtKey =
      'printer_last_connection_verified_at';
  static const String _printFailureStreakKey = 'printer_failure_streak';

  static const String cutModeOff = 'off';
  static const String cutModeSafe = 'safe';
  static const String cutModeForce = 'force';

  static const String _failureNoPrinter = 'no_printer_selected';
  static const String _failurePermissionRequired =
      'bluetooth_permission_required';
  static const String _failureNotPaired = 'printer_not_paired';
  static const String _failureConnectFailed = 'connect_failed';
  static const String _failureWriteFailed = 'write_failed';
  static const String _jobStatusQueued = 'queued';
  static const String _jobStatusPrinting = 'printing';
  static const String _jobStatusAwaitingConfirmation = 'awaiting_confirmation';
  static const String _jobStatusSuccess = 'success';
  static const String _jobStatusCancelled = 'cancelled';
  static const String _recoveredPrintingReason =
      'The app restarted before print outcome was confirmed. Confirm only if the paper actually came out; otherwise queue a retry.';
  static const String _attemptOutcomeSuccess = 'success';
  static const String _attemptOutcomeFailed = 'failed';
  static const String _attemptOutcomeCancelled = 'cancelled';
  static const int _unhealthyFailureThreshold = 3;
  static const Duration _monitorInterval = Duration(seconds: 8);
  static const Duration _connectionVerificationFreshness = Duration(
    seconds: 10,
  );

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
    await _reconcileInterruptedJobs();
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
        {
          'key': _printerAddressKey,
          'value': address,
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
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
        {
          'key': _cutModeKey(printerAddress),
          'value': mode,
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
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
    List<BluetoothDevice> devices,
    String address,
  ) {
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
          '[PrinterService] Printer $address not found in bonded devices',
        );
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
    bool revalidateConnection = false,
  }) async {
    await _loadFailedJobs();
    final address = await getSelectedPrinterAddress();
    final lastPrintSuccessAt = await _readIntSetting(_lastPrintSuccessAtKey);
    final lastPrintFailureAt = await _readIntSetting(_lastPrintFailureAtKey);
    final lastPrintFailureReason = await _readStringSetting(
      _lastPrintFailureReasonKey,
    );
    final lastConnectionVerifiedAt = await _readIntSetting(
      _lastConnectionVerifiedAtKey,
    );
    final failureStreak = await _readFailureStreak();
    final unhealthy = failureStreak >= _unhealthyFailureThreshold;
    final queuedJobCount = _failedJobs.length;
    final activeJobCount = _pendingPrints.length;

    if (address == null) {
      return PrinterStatusSnapshot(
        hasSelection: false,
        stateLabel: 'No Printer Selected',
        permissionsGranted: true,
        isPaired: false,
        isConnected: false,
        isConnecting: _isConnecting,
        queuedJobCount: queuedJobCount,
        activeJobCount: activeJobCount,
        lastPrintSuccessAt: lastPrintSuccessAt,
        lastPrintFailureAt: lastPrintFailureAt,
        lastPrintFailureReason: lastPrintFailureReason,
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
        stateLabel: 'Bluetooth Permission Required',
        permissionsGranted: false,
        isPaired: false,
        isConnected: false,
        isConnecting: _isConnecting,
        queuedJobCount: queuedJobCount,
        activeJobCount: activeJobCount,
        lastPrintSuccessAt: lastPrintSuccessAt,
        lastPrintFailureAt: lastPrintFailureAt,
        lastPrintFailureReason: lastPrintFailureReason,
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
          stateLabel: 'Paired Device Missing',
          permissionsGranted: true,
          isPaired: false,
          isConnected: false,
          isConnecting: _isConnecting,
          queuedJobCount: queuedJobCount,
          activeJobCount: activeJobCount,
          lastPrintSuccessAt: lastPrintSuccessAt,
          lastPrintFailureAt: lastPrintFailureAt,
          lastPrintFailureReason: lastPrintFailureReason,
          message: 'Selected printer is not paired in Android settings',
        );
      }

      var connected = _connectedDevice?.address == address && await isConnected;
      var recentlyVerified =
          connected && _isConnectionVerificationFresh(lastConnectionVerifiedAt);
      if (revalidateConnection) {
        connected = await _revalidateConnection(
          address,
          requestPermissions: false,
        );
        recentlyVerified = connected;
      }
      final baseStateLabel = _isConnecting
          ? 'Connecting'
          : connected
              ? recentlyVerified
                  ? 'Connected'
                  : 'Connection Unverified'
              : 'Paired, Not Connected';
      final stateLabel = unhealthy
          ? connected
              ? 'Connected, Unhealthy'
              : 'Printer Unhealthy'
          : baseStateLabel;
      final baseMessage = connected
          ? recentlyVerified
              ? 'Connected after a fresh revalidation. Final readiness is still only confirmed when a print succeeds.'
              : 'A stale Bluetooth link may still exist, but the printer has not been freshly revalidated. Use Check Status or print to confirm reachability.'
          : _isConnecting
              ? 'Connecting to the selected printer'
              : 'Paired, but not currently connected';
      final unhealthyMessage =
          'Printer marked unhealthy after $failureStreak consecutive failures. Resolve pending confirmations or retries, then complete a successful print to clear.';
      return PrinterStatusSnapshot(
        hasSelection: true,
        selectedAddress: address,
        selectedName: device.name,
        stateLabel: stateLabel,
        permissionsGranted: true,
        isPaired: true,
        isConnected: connected,
        isConnecting: _isConnecting,
        queuedJobCount: queuedJobCount,
        activeJobCount: activeJobCount,
        lastPrintSuccessAt: lastPrintSuccessAt,
        lastPrintFailureAt: lastPrintFailureAt,
        lastPrintFailureReason: lastPrintFailureReason,
        device: device,
        message: unhealthy ? '$unhealthyMessage $baseMessage' : baseMessage,
      );
    } catch (e) {
      return PrinterStatusSnapshot(
        hasSelection: true,
        selectedAddress: address,
        stateLabel: 'Status Check Failed',
        permissionsGranted: true,
        isPaired: false,
        isConnected: false,
        isConnecting: _isConnecting,
        queuedJobCount: queuedJobCount,
        activeJobCount: activeJobCount,
        lastPrintSuccessAt: lastPrintSuccessAt,
        lastPrintFailureAt: lastPrintFailureAt,
        lastPrintFailureReason: lastPrintFailureReason,
        message: 'Unable to check printer status: $e',
      );
    }
  }

  static Future<PrintReceiptResult> printReceipt(
    Participant participant,
    String deviceId, {
    bool isReprint = false,
    bool requireOperatorConfirmation = false,
  }) async {
    return _attemptPrint(
      participant,
      deviceId,
      isReprint: isReprint,
      requireOperatorConfirmation: requireOperatorConfirmation,
    );
  }

  static Future<PrintReceiptResult> _attemptPrint(
    Participant participant,
    String deviceId, {
    required bool isReprint,
    required bool requireOperatorConfirmation,
    _FailedPrintJob? retryJob,
  }) async {
    await _loadFailedJobs();
    _cancelledPrints.remove(participant.id);
    _pendingPrints[participant.id] = false;
    final printJob = await _beginPrintAttempt(
      participant,
      deviceId,
      isReprint: isReprint,
      retryJob: retryJob,
    );

    try {
      debugPrint('[PrinterService] Starting print for ${participant.fullName}');

      final eventDetails = await _loadEventDetails();
      final printerAddress = await getSelectedPrinterAddress();
      if (printerAddress == null) {
        return _queueAndReturnFailure(
          participant,
          deviceId,
          isReprint: isReprint,
          retryJob: printJob,
          failure: const _QueuedFailure(
            code: _failureNoPrinter,
            reason: 'No printer selected',
            userMessage:
                'No printer selected. The receipt was queued for retry.',
          ),
        );
      }

      final status = await getSelectedPrinterStatus(revalidateConnection: true);
      if (!status.permissionsGranted) {
        return _queueAndReturnFailure(
          participant,
          deviceId,
          isReprint: isReprint,
          retryJob: printJob,
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
          retryJob: printJob,
          failure: const _QueuedFailure(
            code: _failureNotPaired,
            reason: 'Selected printer is not paired',
            userMessage:
                'The selected printer is not paired in Android settings. The receipt was queued for retry.',
          ),
        );
      }

      if (_wasPrintCancelled(participant.id)) {
        await _cancelQueuedJob(
          printJob,
          reason:
              'Cancelled before printing because the participant was de-verified.',
        );
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
          retryJob: printJob.copyWith(printerAddress: printerAddress),
          failure: const _QueuedFailure(
            code: _failureConnectFailed,
            reason: 'Could not connect to the selected printer',
            userMessage:
                'Could not connect to the selected printer. The receipt was queued for retry.',
          ),
        );
      }

      if (_wasPrintCancelled(participant.id)) {
        await _cancelQueuedJob(
          printJob,
          reason:
              'Cancelled before printing because the participant was de-verified.',
        );
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

      if (requireOperatorConfirmation && !isReprint) {
        await _markJobAwaitingConfirmation(printJob.jobId);
        await _emitStateChanged();
        return PrintReceiptResult(
          success: true,
          queuedForRetry: false,
          message:
              'Print command sent. Confirm whether the receipt actually came out before the participant is marked fully verified.',
          requiresOperatorConfirmation: true,
          confirmationJobId: printJob.jobId,
        );
      }

      final now = DateTime.now().millisecondsSinceEpoch;
      final recorded = await _onPrintSuccess(
        participant,
        now,
        job: printJob,
        isReprint: isReprint,
      );

      debugPrint('[PrinterService] Print successful');
      if (!recorded.success) {
        await _emitStateChanged();
        return PrintReceiptResult(
          success: false,
          queuedForRetry: false,
          message: recorded.message,
        );
      }

      await _emitStateChanged();
      return PrintReceiptResult(
        success: true,
        queuedForRetry: false,
        message: recorded.message,
      );
    } catch (e) {
      debugPrint('[PrinterService] Print failed: $e');
      return _queueAndReturnFailure(
        participant,
        deviceId,
        isReprint: isReprint,
        retryJob: printJob,
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

    await _migrateLegacyFailedJobsToTable();
    await _refreshQueuedJobsCache();
    _failedJobsLoaded = true;
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
    final previous = retryJob ?? _findOpenJob(participant.id, isReprint);
    final queuedJob =
        (previous ?? _FailedPrintJob.newJob(participant, deviceId)).copyWith(
      participant: participant,
      deviceId: deviceId,
      failureCode: failure.code,
      reason: failure.reason,
      isReprint: isReprint,
      status: PrinterService._jobStatusQueued,
      lastAttemptAt: previous?.lastAttemptAt ?? now,
      attemptCount: previous?.attemptCount ?? 1,
      nextRetryAt: now +
          _retryDelayForAttempt(previous?.attemptCount ?? 1).inMilliseconds,
      updatedAt: now,
    );

    await _upsertPrintJob(queuedJob);
    await _recordAttemptOutcome(
      queuedJob,
      outcome: _attemptOutcomeFailed,
      finishedAt: now,
    );
    await _replaceQueuedJob(queuedJob);
    await _recordPrintFailure(failure);
    await _emitStateChanged();
  }

  static Future<void> _removeQueuedJob(String jobId) async {
    await _loadFailedJobs();
    _failedJobs.removeWhere((job) => job.jobId == jobId);
    await _emitStateChanged();
  }

  static Future<PrinterRetrySummary> retryFailedPrints() async {
    return _drainQueuedJobs(ignoreBackoff: true);
  }

  static Future<PrintReceiptResult> retryQueuedJob(
    String jobId, {
    bool requireOperatorConfirmation = false,
  }) async {
    await _loadFailedJobs();
    final job = _firstMatchingJob((entry) => entry.jobId == jobId);
    if (job == null) {
      return const PrintReceiptResult(
        success: false,
        queuedForRetry: false,
        message: 'The queued print job could not be found.',
      );
    }

    if (job.status == _jobStatusAwaitingConfirmation) {
      return const PrintReceiptResult(
        success: false,
        queuedForRetry: false,
        message:
            'This print is still awaiting operator confirmation. Confirm it or queue a retry explicitly instead of sending a second print blindly.',
      );
    }

    final retryParticipant = await _resolveRetryParticipant(
      job.participant.id,
      job.isReprint,
    );
    if (retryParticipant == null) {
      await _removeQueuedJob(job.jobId);
      return const PrintReceiptResult(
        success: false,
        queuedForRetry: false,
        message:
            'The participant record for this queued print could not be found.',
      );
    }

    return _attemptPrint(
      retryParticipant,
      job.deviceId,
      isReprint: job.isReprint,
      requireOperatorConfirmation: requireOperatorConfirmation,
      retryJob: job,
    );
  }

  static Future<PrinterRetrySummary> _drainQueuedJobs({
    bool ignoreBackoff = false,
  }) async {
    await _loadFailedJobs();
    if (!ignoreBackoff && await _isCircuitBreakerOpen()) {
      return PrinterRetrySummary(
        attempted: 0,
        succeeded: 0,
        remaining: _failedJobs.length,
      );
    }
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
      final jobs = List<_FailedPrintJob>.from(
        _failedJobs,
      ).where((job) {
        if (job.status != _jobStatusQueued) {
          return false;
        }
        return ignoreBackoff || job.isReady(now);
      }).toList()
        ..sort((a, b) => a.queuedAt.compareTo(b.queuedAt));

      for (final job in jobs) {
        attempted++;
        final retryParticipant = await _resolveRetryParticipant(
          job.participant.id,
          job.isReprint,
        );
        if (retryParticipant == null) {
          await _removeQueuedJob(job.jobId);
          continue;
        }

        final result = await _attemptPrint(
          retryParticipant,
          job.deviceId,
          isReprint: job.isReprint,
          requireOperatorConfirmation: false,
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

  static Future<List<PrinterQueuedJob>> getQueuedJobs() async {
    await _loadFailedJobs();
    final jobs = [..._failedJobs]
      ..sort((a, b) => a.queuedAt.compareTo(b.queuedAt));
    return jobs
        .map(
          (job) => PrinterQueuedJob(
            jobId: job.jobId,
            participantId: job.participant.id,
            participantName: job.participant.fullName,
            isReprint: job.isReprint,
            status: job.status,
            failureCode: job.failureCode,
            reason: job.reason,
            queuedAt: job.queuedAt,
            lastAttemptAt: job.lastAttemptAt,
            nextRetryAt: job.nextRetryAt,
            attemptCount: job.attemptCount,
            printedAt: job.printedAt,
          ),
        )
        .toList();
  }

  static Future<List<PrinterQueuedJob>> getPendingConfirmationJobs() async {
    final jobs = await getQueuedJobs();
    return jobs
        .where((job) => job.status == _jobStatusAwaitingConfirmation)
        .toList();
  }

  static Future<PrinterQueuedJob?> getPendingConfirmationJobForParticipant(
    String participantId,
  ) async {
    final jobs = await getPendingConfirmationJobs();
    for (final job in jobs) {
      if (job.participantId == participantId) {
        return job;
      }
    }
    return null;
  }

  static Future<List<PrinterQueuedJob>> getRecentPrintJobs({
    int limit = 20,
  }) async {
    final db = await DatabaseHelper.database;
    final rows = await db.query(
      'print_jobs',
      orderBy: 'updated_at DESC',
      limit: limit,
    );
    return rows
        .map(_FailedPrintJob.fromDbRow)
        .map(
          (job) => PrinterQueuedJob(
            jobId: job.jobId,
            participantId: job.participant.id,
            participantName: job.participant.fullName,
            isReprint: job.isReprint,
            failureCode: job.failureCode,
            reason: job.reason,
            queuedAt: job.queuedAt,
            lastAttemptAt: job.lastAttemptAt,
            nextRetryAt: job.nextRetryAt,
            attemptCount: job.attemptCount,
            status: job.status,
            printedAt: job.printedAt,
          ),
        )
        .toList();
  }

  static Future<List<PrinterJobAttempt>> getRecentPrintAttempts({
    int limit = 100,
  }) async {
    final db = await DatabaseHelper.database;
    final rows = await db.query(
      'print_job_attempts',
      orderBy: 'finished_at DESC, attempt_id DESC',
      limit: limit,
    );
    return rows.map(PrinterJobAttempt.fromDbRow).toList();
  }

  static Future<PrintReceiptResult> confirmPrintDelivery(String jobId) async {
    final job = await _getPrintJobById(jobId);
    if (job == null) {
      return const PrintReceiptResult(
        success: false,
        queuedForRetry: false,
        message: 'The pending print confirmation could not be found.',
      );
    }
    if (job.status != _jobStatusAwaitingConfirmation) {
      return const PrintReceiptResult(
        success: false,
        queuedForRetry: false,
        message:
            'This print is not waiting for operator confirmation anymore.',
      );
    }

    final printedAt = DateTime.now().millisecondsSinceEpoch;
    final finalization = await _onPrintSuccess(
      job.participant,
      printedAt,
      job: job,
      isReprint: job.isReprint,
    );
    await _emitStateChanged();
    return PrintReceiptResult(
      success: finalization.success,
      queuedForRetry: false,
      message: finalization.message,
    );
  }

  static Future<PrintReceiptResult> rejectPrintDelivery(String jobId) async {
    final job = await _getPrintJobById(jobId);
    if (job == null) {
      return const PrintReceiptResult(
        success: false,
        queuedForRetry: false,
        message: 'The pending print confirmation could not be found.',
      );
    }
    if (job.status != _jobStatusAwaitingConfirmation) {
      return const PrintReceiptResult(
        success: false,
        queuedForRetry: false,
        message:
            'This print is not waiting for operator confirmation anymore.',
      );
    }

    const failure = _QueuedFailure(
      code: _failureWriteFailed,
      reason: 'Operator did not confirm paper output',
      userMessage:
          'Receipt output was not confirmed. The print was queued for retry.',
    );
    await _queueFailedJob(
      job.participant,
      job.deviceId,
      failure,
      isReprint: job.isReprint,
      retryJob: job,
    );
    await _emitStateChanged();
    return const PrintReceiptResult(
      success: false,
      queuedForRetry: true,
      message:
          'Receipt output was not confirmed. The print was queued for retry.',
    );
  }

  static Future<_PrintFinalizationResult> _onPrintSuccess(
    Participant participant,
    int printedAt, {
    required _FailedPrintJob job,
    required bool isReprint,
  }) async {
    try {
      final db = await DatabaseHelper.database;
      var participantFinalized = false;
      var participantStillVerified = false;
      await db.transaction((txn) async {
        final participantRows = await txn.query(
          'participants',
          columns: ['verified_at', 'printed_at'],
          where: 'id = ?',
          whereArgs: [participant.id],
          limit: 1,
        );
        if (participantRows.isNotEmpty) {
          final row = participantRows.first;
          final currentVerifiedAt = row['verified_at'] as int?;
          final currentPrintedAt = row['printed_at'] as int?;
          if (currentVerifiedAt != null) {
            participantStillVerified = true;
            if (!isReprint || currentPrintedAt == null) {
              await txn.update(
                'participants',
                {
                  'printed_at': printedAt,
                  'updated_at': DateTime.now().millisecondsSinceEpoch,
                },
                where: 'id = ?',
                whereArgs: [participant.id],
              );
              await SyncQueueDao.enqueueTaskInTransaction(
                txn,
                SyncQueueDao.typeMarkPrinted,
                {'participantId': participant.id, 'printedAt': printedAt},
              );
              participantFinalized = true;
            }
          }
        }

        await _markJobSuccessfulInTransaction(
          txn,
          job.jobId,
          printedAt: printedAt,
        );
        await _recordAttemptOutcomeInTransaction(
          txn,
          job.copyWith(printedAt: printedAt, updatedAt: printedAt),
          outcome: _attemptOutcomeSuccess,
          finishedAt: printedAt,
        );
      });

      await _recordPrintSuccess();
      await _removeQueuedJob(job.jobId);

      if (!participantStillVerified) {
        debugPrint(
          '[PrinterService] Print confirmed for ${participant.id}, but participant is no longer verified locally.',
        );
        return _PrintFinalizationResult(
          success: true,
          message: job.isReprint
              ? 'Receipt reprint confirmed. The participant was already unverified, so no check-in state was changed.'
              : 'Receipt output confirmed. The participant was already unverified, so no check-in state was changed.',
        );
      }

      if (job.isReprint) {
        return _PrintFinalizationResult(
          success: true,
          message: participantFinalized
              ? 'Receipt reprint confirmed successfully and the participant is now fully verified.'
              : 'Receipt reprint confirmed successfully.',
        );
      }

      return _PrintFinalizationResult(
        success: true,
        message: participantFinalized
            ? 'Receipt output confirmed. Participant is now fully verified.'
            : 'Receipt output confirmed successfully.',
      );
    } catch (e) {
      debugPrint('[PrinterService] Error recording print: $e');
      return const _PrintFinalizationResult(
        success: false,
        message:
            'Receipt output was confirmed, but local finalization could not be completed.',
      );
    }
  }

  static Future<_FailedPrintJob> _beginPrintAttempt(
    Participant participant,
    String deviceId, {
    required bool isReprint,
    _FailedPrintJob? retryJob,
  }) async {
    await _loadFailedJobs();
    final now = DateTime.now().millisecondsSinceEpoch;
    final baseJob = retryJob ??
        _findOpenJob(participant.id, isReprint) ??
        _FailedPrintJob.newJob(participant, deviceId);
    final startedJob = baseJob.copyWith(
      participant: participant,
      deviceId: deviceId,
      status: _jobStatusPrinting,
      lastAttemptAt: now,
      attemptCount: baseJob.attemptCount + 1,
      updatedAt: now,
      printerAddress: await getSelectedPrinterAddress(),
    );
    await _upsertPrintJob(startedJob);
    return startedJob;
  }

  static Future<void> _cancelQueuedJob(
    _FailedPrintJob job, {
    required String reason,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final db = await DatabaseHelper.database;
    await db.update(
      'print_jobs',
      {
        'status': _jobStatusCancelled,
        'failure_reason': reason,
        'completed_at': now,
        'updated_at': now,
      },
      where: 'job_id = ?',
      whereArgs: [job.jobId],
    );
    await _recordAttemptOutcome(
      job.copyWith(reason: reason, updatedAt: now),
      outcome: _attemptOutcomeCancelled,
      finishedAt: now,
    );
    await _removeQueuedJob(job.jobId);
  }

  static Future<void> _refreshQueuedJobsCache() async {
    final db = await DatabaseHelper.database;
    final rows = await db.query(
      'print_jobs',
      where: 'status IN (?, ?)',
      whereArgs: [_jobStatusQueued, _jobStatusAwaitingConfirmation],
      orderBy: 'queued_at ASC',
    );
    _failedJobs
      ..clear()
      ..addAll(rows.map(_FailedPrintJob.fromDbRow));
  }

  static _FailedPrintJob? _findOpenJob(String participantId, bool isReprint) {
    for (final job in _failedJobs) {
      if (job.matchesParticipant(participantId, isReprint: isReprint)) {
        return job;
      }
    }
    return null;
  }

  static _FailedPrintJob? _firstMatchingJob(
    bool Function(_FailedPrintJob job) test,
  ) {
    for (final job in _failedJobs) {
      if (test(job)) {
        return job;
      }
    }
    return null;
  }

  static Future<void> _replaceQueuedJob(_FailedPrintJob job) async {
    final index = _failedJobs.indexWhere((entry) => entry.jobId == job.jobId);
    if (index == -1) {
      _failedJobs.add(job);
    } else {
      _failedJobs[index] = job;
    }
  }

  static Future<void> _upsertPrintJob(_FailedPrintJob job) async {
    final db = await DatabaseHelper.database;
    await db.insert(
        'print_jobs',
        {
          'job_id': job.jobId,
          'participant_id': job.participant.id,
          'participant_name': job.participant.fullName,
          'participant_json': jsonEncode(job.participant.toJson()),
          'device_id': job.deviceId,
          'printer_address': job.printerAddress,
          'status': job.status,
          'failure_code': job.failureCode,
          'failure_reason': job.reason,
          'queued_at': job.queuedAt,
          'last_attempt_at': job.lastAttemptAt,
          'next_retry_at': job.nextRetryAt,
          'attempt_count': job.attemptCount,
          'is_reprint': job.isReprint ? 1 : 0,
          'printed_at': job.printedAt,
          'completed_at':
              job.status == _jobStatusSuccess ? job.printedAt : null,
          'updated_at': job.updatedAt,
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<void> _markJobSuccessfulInTransaction(
    DatabaseExecutor db,
    String jobId, {
    required int printedAt,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.update(
      'print_jobs',
      {
        'status': _jobStatusSuccess,
        'printed_at': printedAt,
        'completed_at': now,
        'updated_at': now,
        'failure_code': '',
        'failure_reason': '',
      },
      where: 'job_id = ?',
      whereArgs: [jobId],
    );
  }

  static Future<void> _markJobAwaitingConfirmation(String jobId) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final db = await DatabaseHelper.database;
    await db.update(
      'print_jobs',
      {
        'status': _jobStatusAwaitingConfirmation,
        'failure_code': '',
        'failure_reason': '',
        'updated_at': now,
      },
      where: 'job_id = ?',
      whereArgs: [jobId],
    );
  }

  static Future<_FailedPrintJob?> _getPrintJobById(String jobId) async {
    final db = await DatabaseHelper.database;
    final rows = await db.query(
      'print_jobs',
      where: 'job_id = ?',
      whereArgs: [jobId],
      limit: 1,
    );
    if (rows.isEmpty) {
      return null;
    }
    return _FailedPrintJob.fromDbRow(rows.first);
  }

  static Future<void> _recordAttemptOutcome(
    _FailedPrintJob job, {
    required String outcome,
    required int finishedAt,
  }) async {
    final startedAt = job.lastAttemptAt ?? job.queuedAt;
    final db = await DatabaseHelper.database;
    await db.insert(
        'print_job_attempts',
        {
          'job_id': job.jobId,
          'participant_id': job.participant.id,
          'participant_name': job.participant.fullName,
          'device_id': job.deviceId,
          'printer_address': job.printerAddress,
          'attempt_number': job.attemptCount,
          'outcome': outcome,
          'failure_code':
              outcome == _attemptOutcomeSuccess ? '' : job.failureCode,
          'failure_reason': outcome == _attemptOutcomeSuccess ? '' : job.reason,
          'is_reprint': job.isReprint ? 1 : 0,
          'started_at': startedAt,
          'finished_at': finishedAt,
          'created_at': finishedAt,
        },
        conflictAlgorithm: ConflictAlgorithm.abort);
  }

  static Future<void> _recordAttemptOutcomeInTransaction(
    DatabaseExecutor db,
    _FailedPrintJob job, {
    required String outcome,
    required int finishedAt,
  }) async {
    final startedAt = job.lastAttemptAt ?? job.queuedAt;
    await db.insert(
        'print_job_attempts',
        {
          'job_id': job.jobId,
          'participant_id': job.participant.id,
          'participant_name': job.participant.fullName,
          'device_id': job.deviceId,
          'printer_address': job.printerAddress,
          'attempt_number': job.attemptCount,
          'outcome': outcome,
          'failure_code':
              outcome == _attemptOutcomeSuccess ? '' : job.failureCode,
          'failure_reason': outcome == _attemptOutcomeSuccess ? '' : job.reason,
          'is_reprint': job.isReprint ? 1 : 0,
          'started_at': startedAt,
          'finished_at': finishedAt,
          'created_at': finishedAt,
        },
        conflictAlgorithm: ConflictAlgorithm.abort);
  }

  static Future<void> _reconcileInterruptedJobs() async {
    final db = await DatabaseHelper.database;
    final interruptedRows = await db.query(
      'print_jobs',
      where: 'status = ?',
      whereArgs: [_jobStatusPrinting],
    );
    if (interruptedRows.isEmpty) {
      await _refreshQueuedJobsCache();
      return;
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    for (final row in interruptedRows) {
      await db.update(
        'print_jobs',
        {
          'status': _jobStatusAwaitingConfirmation,
          'failure_code': _failureWriteFailed,
          'failure_reason': _recoveredPrintingReason,
          'updated_at': now,
        },
        where: 'job_id = ?',
        whereArgs: [row['job_id']],
      );
    }
    await _refreshQueuedJobsCache();
    await _emitStateChanged();
  }

  static Future<void> _migrateLegacyFailedJobsToTable() async {
    final db = await DatabaseHelper.database;
    final result = await db.query(
      'app_settings',
      where: 'key = ?',
      whereArgs: [_failedPrintJobsKey],
      limit: 1,
    );
    if (result.isEmpty) {
      return;
    }
    final raw = result.first['value'] as String?;
    if (raw == null || raw.isEmpty) {
      return;
    }

    try {
      final decoded = jsonDecode(raw) as List<dynamic>;
      for (final entry in decoded.whereType<Map<String, dynamic>>()) {
        final job = _FailedPrintJob.fromJson(entry);
        await _upsertPrintJob(
          job.copyWith(
            status: _jobStatusQueued,
            updatedAt: job.updatedAt == 0
                ? DateTime.now().millisecondsSinceEpoch
                : job.updatedAt,
          ),
        );
      }
      await db.insert(
          'app_settings',
          {
            'key': _failedPrintJobsKey,
            'value': '',
          },
          conflictAlgorithm: ConflictAlgorithm.replace);
    } catch (_) {
      // Ignore malformed legacy data and leave the old value untouched.
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

      final status = await getSelectedPrinterStatus(revalidateConnection: true);
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

  static Future<PrintReceiptResult> printSummaryReport({
    required String title,
    required List<String> bodyLines,
    bool requireOperatorConfirmation = false,
  }) async {
    try {
      final printerAddress = await getSelectedPrinterAddress();
      if (printerAddress == null) {
        const failure = _QueuedFailure(
          code: _failureNoPrinter,
          reason: 'No printer selected for summary printing',
          userMessage: 'Select a printer before printing a summary.',
        );
        await _recordPrintFailure(failure);
        return const PrintReceiptResult(
          success: false,
          queuedForRetry: false,
          message: 'Select a printer before printing a summary.',
        );
      }

      final permissionsGranted = await ensureBluetoothPermissions();
      if (!permissionsGranted) {
        const failure = _QueuedFailure(
          code: _failurePermissionRequired,
          reason: 'Bluetooth permission is required for summary printing',
          userMessage:
              'Bluetooth permission is required before printing a summary.',
        );
        await _recordPrintFailure(failure);
        return const PrintReceiptResult(
          success: false,
          queuedForRetry: false,
          message:
              'Bluetooth permission is required before printing a summary.',
        );
      }

      final status = await getSelectedPrinterStatus(
        requestPermissions: false,
        revalidateConnection: true,
      );
      if (!status.isPaired) {
        const failure = _QueuedFailure(
          code: _failureNotPaired,
          reason: 'The selected printer is not paired for summary printing',
          userMessage:
              'The selected printer is not paired in Android settings.',
        );
        await _recordPrintFailure(failure);
        return const PrintReceiptResult(
          success: false,
          queuedForRetry: false,
          message: 'The selected printer is not paired in Android settings.',
        );
      }

      final connected = await _ensureConnected(printerAddress);
      if (!connected) {
        const failure = _QueuedFailure(
          code: _failureConnectFailed,
          reason:
              'Could not connect to the selected printer for summary printing',
          userMessage: 'Could not connect to the selected printer.',
        );
        await _recordPrintFailure(failure);
        return const PrintReceiptResult(
          success: false,
          queuedForRetry: false,
          message: 'Could not connect to the selected printer.',
        );
      }

      final lines = <ReceiptLine>[
        for (final line in _wrapSummaryLine(title.toUpperCase(), align: 1))
          line,
        const ReceiptLine('--------------------------------', align: 1),
        for (final line in bodyLines) ..._wrapSummaryLine(line, align: 0),
      ];

      await _printReceiptLines(lines, printerAddress);
      if (requireOperatorConfirmation) {
        await _emitStateChanged();
        return const PrintReceiptResult(
          success: true,
          queuedForRetry: false,
          message:
              'Summary print command sent. Confirm whether paper actually came out.',
          requiresOperatorConfirmation: true,
        );
      }

      await _recordPrintSuccess();
      await _emitStateChanged();
      return const PrintReceiptResult(
        success: true,
        queuedForRetry: false,
        message: 'Summary printed successfully.',
      );
    } catch (e) {
      final failure = _failureFromException(e);
      await _recordPrintFailure(failure);
      await _emitStateChanged();
      return PrintReceiptResult(
        success: false,
        queuedForRetry: false,
        message: 'Summary print failed: $e',
      );
    }
  }

  static Future<PrintReceiptResult> confirmSummaryPrintDelivery() async {
    await _recordPrintSuccess();
    await _emitStateChanged();
    return const PrintReceiptResult(
      success: true,
      queuedForRetry: false,
      message: 'Summary output confirmed successfully.',
    );
  }

  static Future<PrintReceiptResult> rejectSummaryPrintDelivery() async {
    const failure = _QueuedFailure(
      code: _failureWriteFailed,
      reason: 'Operator did not confirm summary paper output',
      userMessage: 'Summary output was not confirmed.',
    );
    await _recordPrintFailure(failure);
    await _emitStateChanged();
    return const PrintReceiptResult(
      success: false,
      queuedForRetry: false,
      message:
          'Summary output was not confirmed. The printer should not be treated as successful.',
    );
  }

  static List<ReceiptLine> _wrapSummaryLine(
    String value, {
    required int align,
    int width = 32,
  }) {
    final normalized = value.trim();
    if (normalized.isEmpty) {
      return [ReceiptLine('', align: align)];
    }

    final words = normalized.split(RegExp(r'\s+'));
    final lines = <String>[];
    var current = '';
    for (final word in words) {
      if (current.isEmpty) {
        current = word;
        continue;
      }
      final candidate = '$current $word';
      if (candidate.length <= width) {
        current = candidate;
      } else {
        lines.add(current);
        current = word;
      }
    }
    if (current.isNotEmpty) {
      lines.add(current);
    }

    return lines.map((line) => ReceiptLine(line, align: align)).toList();
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
        '[PrinterService] Cut command failed, falling back to feed: $e',
      );
      await _printer.writeBytes(Uint8List.fromList(<int>[0x0A]));
    }
  }

  static Future<void> _printReceiptLines(
    List<ReceiptLine> lines,
    String printerAddress,
  ) async {
    await _printer.writeBytes(
      Uint8List.fromList(<int>[0x1B, 0x40, 0x1B, 0x61, 0x00]),
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
      Uint8List.fromList(<int>[0x1D, 0x21, 0x00, 0x1B, 0x61, 0x00, 0x0A]),
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

      final refreshedStatus = await getSelectedPrinterStatus(
        requestPermissions: false,
      );
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
    await _ensureConnected(printers.first.address!, requestPermissions: false);
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
        selectedName: status.selectedName,
        hasSelection: status.hasSelection,
        permissionsGranted: status.permissionsGranted,
        isPaired: status.isPaired,
        isConnected: status.isConnected,
        isConnecting: status.isConnecting,
        failedJobCount: _failedJobs.length,
        activeJobCount: status.activeJobCount,
        stateLabel: status.stateLabel,
        statusMessage: status.message,
        lastPrintSuccessAt: status.lastPrintSuccessAt,
        lastPrintFailureAt: status.lastPrintFailureAt,
        lastPrintFailureReason: status.lastPrintFailureReason,
      ),
    );
  }

  static Future<void> _recordPrintSuccess() async {
    final db = await DatabaseHelper.database;
    final now = DateTime.now().millisecondsSinceEpoch.toString();
    await db.insert(
        'app_settings',
        {
          'key': _lastPrintSuccessAtKey,
          'value': now,
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
    await db.insert(
        'app_settings',
        {
          'key': _lastPrintFailureAtKey,
          'value': '',
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
    await db.insert(
        'app_settings',
        {
          'key': _lastPrintFailureReasonKey,
          'value': '',
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
    await db.insert(
        'app_settings',
        {
          'key': _lastPrintFailureCodeKey,
          'value': '',
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
    await db.insert(
        'app_settings',
        {
          'key': _lastConnectionVerifiedAtKey,
          'value': now,
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
    await db.insert(
        'app_settings',
        {
          'key': _printFailureStreakKey,
          'value': '0',
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<void> _recordPrintFailure(_QueuedFailure failure) async {
    final db = await DatabaseHelper.database;
    final now = DateTime.now().millisecondsSinceEpoch.toString();
    final streakResult = await db.query(
      'app_settings',
      where: 'key = ?',
      whereArgs: [_printFailureStreakKey],
      limit: 1,
    );
    final currentStreak = streakResult.isEmpty
        ? 0
        : int.tryParse(streakResult.first['value'] as String? ?? '') ?? 0;
    final nextStreak = currentStreak + 1;
    await db.insert(
        'app_settings',
        {
          'key': _lastPrintFailureAtKey,
          'value': now,
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
    await db.insert(
        'app_settings',
        {
          'key': _lastPrintFailureReasonKey,
          'value': failure.reason,
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
    await db.insert(
        'app_settings',
        {
          'key': _lastPrintFailureCodeKey,
          'value': failure.code,
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
    await db.insert(
        'app_settings',
        {
          'key': _printFailureStreakKey,
          'value': nextStreak.toString(),
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<int> _readFailureStreak() async {
    final value = await _readStringSetting(_printFailureStreakKey);
    if (value == null || value.isEmpty) {
      return 0;
    }
    return int.tryParse(value) ?? 0;
  }

  static Future<bool> _isCircuitBreakerOpen() async {
    final streak = await _readFailureStreak();
    if (streak < _unhealthyFailureThreshold) {
      return false;
    }
    return _failedJobs.any((job) => job.status == _jobStatusQueued);
  }

  static bool _isConnectionVerificationFresh(int? verifiedAt) {
    if (verifiedAt == null) {
      return false;
    }
    final age = DateTime.now().millisecondsSinceEpoch - verifiedAt;
    return age <= _connectionVerificationFreshness.inMilliseconds;
  }

  static Future<bool> _revalidateConnection(
    String address, {
    bool requestPermissions = true,
  }) async {
    final granted = await _checkBluetoothPermissions(
      requestIfMissing: requestPermissions,
    );
    if (!granted) {
      return false;
    }

    try {
      try {
        await _printer.disconnect();
      } catch (_) {}
      _connectedDevice = null;
      final connected = await _ensureConnected(
        address,
        requestPermissions: false,
      );
      if (!connected) {
        return false;
      }

      final db = await DatabaseHelper.database;
      await db.insert(
          'app_settings',
          {
            'key': _lastConnectionVerifiedAtKey,
            'value': DateTime.now().millisecondsSinceEpoch.toString(),
          },
          conflictAlgorithm: ConflictAlgorithm.replace);
      return true;
    } finally {
      await _emitStateChanged();
    }
  }

  static Future<String?> _readStringSetting(String key) async {
    final db = await DatabaseHelper.database;
    final result = await db.query(
      'app_settings',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    if (result.isEmpty) {
      return null;
    }
    final value = result.first['value'] as String?;
    if (value == null || value.trim().isEmpty) {
      return null;
    }
    return value;
  }

  static Future<int?> _readIntSetting(String key) async {
    final raw = await _readStringSetting(key);
    if (raw == null) {
      return null;
    }
    return int.tryParse(raw);
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
  final String? selectedName;
  final String stateLabel;
  final bool permissionsGranted;
  final bool isPaired;
  final bool isConnected;
  final bool isConnecting;
  final int queuedJobCount;
  final int activeJobCount;
  final int? lastPrintSuccessAt;
  final int? lastPrintFailureAt;
  final String? lastPrintFailureReason;
  final BluetoothDevice? device;
  final String message;

  const PrinterStatusSnapshot({
    required this.hasSelection,
    this.selectedAddress,
    this.selectedName,
    required this.stateLabel,
    required this.permissionsGranted,
    required this.isPaired,
    required this.isConnected,
    required this.isConnecting,
    required this.queuedJobCount,
    required this.activeJobCount,
    this.lastPrintSuccessAt,
    this.lastPrintFailureAt,
    this.lastPrintFailureReason,
    this.device,
    required this.message,
  });
}

class PrinterServiceEvent {
  final String? selectedAddress;
  final String? selectedName;
  final bool hasSelection;
  final bool permissionsGranted;
  final bool isPaired;
  final bool isConnected;
  final bool isConnecting;
  final int failedJobCount;
  final int activeJobCount;
  final String stateLabel;
  final String statusMessage;
  final int? lastPrintSuccessAt;
  final int? lastPrintFailureAt;
  final String? lastPrintFailureReason;

  const PrinterServiceEvent({
    required this.selectedAddress,
    required this.selectedName,
    required this.hasSelection,
    required this.permissionsGranted,
    required this.isPaired,
    required this.isConnected,
    required this.isConnecting,
    required this.failedJobCount,
    required this.activeJobCount,
    required this.stateLabel,
    required this.statusMessage,
    required this.lastPrintSuccessAt,
    required this.lastPrintFailureAt,
    required this.lastPrintFailureReason,
  });
}

class PrinterQueuedJob {
  final String jobId;
  final String participantId;
  final String participantName;
  final bool isReprint;
  final String status;
  final String failureCode;
  final String reason;
  final int queuedAt;
  final int? lastAttemptAt;
  final int nextRetryAt;
  final int attemptCount;
  final int? printedAt;

  const PrinterQueuedJob({
    required this.jobId,
    required this.participantId,
    required this.participantName,
    required this.isReprint,
    required this.status,
    required this.failureCode,
    required this.reason,
    required this.queuedAt,
    required this.lastAttemptAt,
    required this.nextRetryAt,
    required this.attemptCount,
    required this.printedAt,
  });
}

class PrinterJobAttempt {
  final int attemptId;
  final String jobId;
  final String participantId;
  final String participantName;
  final String? deviceId;
  final String? printerAddress;
  final int attemptNumber;
  final String outcome;
  final String? failureCode;
  final String? failureReason;
  final bool isReprint;
  final int startedAt;
  final int finishedAt;

  const PrinterJobAttempt({
    required this.attemptId,
    required this.jobId,
    required this.participantId,
    required this.participantName,
    required this.deviceId,
    required this.printerAddress,
    required this.attemptNumber,
    required this.outcome,
    required this.failureCode,
    required this.failureReason,
    required this.isReprint,
    required this.startedAt,
    required this.finishedAt,
  });

  factory PrinterJobAttempt.fromDbRow(Map<String, Object?> row) {
    return PrinterJobAttempt(
      attemptId: row['attempt_id'] as int? ?? 0,
      jobId: row['job_id'] as String? ?? '',
      participantId: row['participant_id'] as String? ?? '',
      participantName: row['participant_name'] as String? ?? '',
      deviceId: row['device_id'] as String?,
      printerAddress: row['printer_address'] as String?,
      attemptNumber: row['attempt_number'] as int? ?? 0,
      outcome: row['outcome'] as String? ?? '',
      failureCode: row['failure_code'] as String?,
      failureReason: row['failure_reason'] as String?,
      isReprint: (row['is_reprint'] as int? ?? 0) == 1,
      startedAt: row['started_at'] as int? ?? 0,
      finishedAt: row['finished_at'] as int? ?? 0,
    );
  }
}

class PrintReceiptResult {
  final bool success;
  final bool queuedForRetry;
  final String message;
  final bool requiresOperatorConfirmation;
  final String? confirmationJobId;

  const PrintReceiptResult({
    required this.success,
    required this.queuedForRetry,
    required this.message,
    this.requiresOperatorConfirmation = false,
    this.confirmationJobId,
  });
}

class _PrintFinalizationResult {
  final bool success;
  final String message;

  const _PrintFinalizationResult({
    required this.success,
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
  final String? printerAddress;
  final String status;
  final String failureCode;
  final String reason;
  final int queuedAt;
  final int attemptCount;
  final int? lastAttemptAt;
  final int nextRetryAt;
  final bool isReprint;
  final int? printedAt;
  final int updatedAt;

  const _FailedPrintJob({
    required this.jobId,
    required this.participant,
    required this.deviceId,
    required this.printerAddress,
    required this.status,
    required this.failureCode,
    required this.reason,
    required this.queuedAt,
    required this.attemptCount,
    required this.lastAttemptAt,
    required this.nextRetryAt,
    required this.isReprint,
    required this.printedAt,
    required this.updatedAt,
  });

  factory _FailedPrintJob.newJob(Participant participant, String deviceId) {
    final now = DateTime.now().millisecondsSinceEpoch;
    return _FailedPrintJob(
      jobId: '${DateTime.now().microsecondsSinceEpoch}-${participant.id}',
      participant: participant,
      deviceId: deviceId,
      printerAddress: null,
      status: PrinterService._jobStatusQueued,
      failureCode: '',
      reason: '',
      queuedAt: now,
      attemptCount: 0,
      lastAttemptAt: null,
      nextRetryAt: now,
      isReprint: false,
      printedAt: null,
      updatedAt: now,
    );
  }

  bool matchesParticipant(String participantId, {required bool isReprint}) {
    return participant.id == participantId && this.isReprint == isReprint;
  }

  bool isReady(int now) => nextRetryAt <= now;

  _FailedPrintJob copyWith({
    Participant? participant,
    String? deviceId,
    String? printerAddress,
    String? status,
    String? failureCode,
    String? reason,
    int? attemptCount,
    int? lastAttemptAt,
    int? nextRetryAt,
    bool? isReprint,
    int? printedAt,
    int? updatedAt,
  }) {
    return _FailedPrintJob(
      jobId: jobId,
      participant: participant ?? this.participant,
      deviceId: deviceId ?? this.deviceId,
      printerAddress: printerAddress ?? this.printerAddress,
      status: status ?? this.status,
      failureCode: failureCode ?? this.failureCode,
      reason: reason ?? this.reason,
      queuedAt: queuedAt,
      attemptCount: attemptCount ?? this.attemptCount,
      lastAttemptAt: lastAttemptAt ?? this.lastAttemptAt,
      nextRetryAt: nextRetryAt ?? this.nextRetryAt,
      isReprint: isReprint ?? this.isReprint,
      printedAt: printedAt ?? this.printedAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'job_id': jobId,
      'participant': participant.toJson(),
      'device_id': deviceId,
      'printer_address': printerAddress,
      'status': status,
      'failure_code': failureCode,
      'reason': reason,
      'queued_at': queuedAt,
      'attempt_count': attemptCount,
      'last_attempt_at': lastAttemptAt,
      'next_retry_at': nextRetryAt,
      'is_reprint': isReprint,
      'printed_at': printedAt,
      'updated_at': updatedAt,
    };
  }

  factory _FailedPrintJob.fromDbRow(Map<String, Object?> row) {
    final participantJson = row['participant_json'] as String?;
    Participant participant;
    if (participantJson != null && participantJson.isNotEmpty) {
      participant = Participant.fromJson(
        Map<String, dynamic>.from(
          jsonDecode(participantJson) as Map<String, dynamic>,
        ),
      );
    } else {
      participant = Participant(
        id: row['participant_id'] as String? ?? '',
        fullName: row['participant_name'] as String? ?? '',
        sheetsRow: 0,
      );
    }
    return _FailedPrintJob(
      jobId: row['job_id'] as String? ?? '',
      participant: participant,
      deviceId: row['device_id'] as String? ?? '',
      printerAddress: row['printer_address'] as String?,
      status: row['status'] as String? ?? PrinterService._jobStatusQueued,
      failureCode: row['failure_code'] as String? ?? '',
      reason: row['failure_reason'] as String? ?? '',
      queuedAt: row['queued_at'] as int? ?? 0,
      attemptCount: row['attempt_count'] as int? ?? 0,
      lastAttemptAt: row['last_attempt_at'] as int?,
      nextRetryAt: row['next_retry_at'] as int? ?? 0,
      isReprint: (row['is_reprint'] as int? ?? 0) == 1,
      printedAt: row['printed_at'] as int?,
      updatedAt: row['updated_at'] as int? ?? 0,
    );
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
      printerAddress: json['printer_address'] as String?,
      status: json['status'] as String? ?? PrinterService._jobStatusQueued,
      failureCode: json['failure_code'] as String? ?? '',
      reason: json['reason'] as String? ?? '',
      queuedAt: queuedAt,
      attemptCount: attemptCount,
      lastAttemptAt: json['last_attempt_at'] as int?,
      nextRetryAt: nextRetryAt,
      isReprint: json['is_reprint'] as bool? ?? false,
      printedAt: json['printed_at'] as int?,
      updatedAt: json['updated_at'] as int? ?? queuedAt,
    );
  }
}
