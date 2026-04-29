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
  static const String _printerAddressKey = 'printer_address';
  static const String _failedPrintJobsKey = 'failed_print_jobs';

  static final BlueThermalPrinter _printer = BlueThermalPrinter.instance;
  static BluetoothDevice? _connectedDevice;
  static bool _isConnecting = false;
  static bool _failedJobsLoaded = false;
  static final Map<String, bool> _pendingPrints = <String, bool>{};
  static final Set<String> _cancelledPrints = <String>{};

  static final List<_FailedPrintJob> _failedJobs = [];

  static Future<bool> ensureBluetoothPermissions() async {
    if (!Platform.isAndroid) {
      return true;
    }

    final statuses = await <Permission>[
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
    ].request();

    return statuses.values.every((status) => status.isGranted);
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

  static Future<List<BluetoothDevice>> _getBondedDevicesUnsafe() async {
    final devices = await _printer.getBondedDevices();
    final filtered = devices
        .where((device) => (device.address ?? '').isNotEmpty)
        .toList()
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

  /// Load paired Bluetooth printers from Android.
  static Future<List<BluetoothDevice>> scanPrinters() async {
    final granted = await ensureBluetoothPermissions();
    if (!granted) {
      debugPrint('[PrinterService] Bluetooth permission not granted');
      return [];
    }

    try {
      final devices = await _getBondedDevicesUnsafe();
      debugPrint('[PrinterService] Found ${devices.length} bonded devices');
      return devices;
    } catch (e) {
      debugPrint('[PrinterService] Scan error: $e');
      return [];
    }
  }

  static Future<PrinterConnectionResult> connect(
    BluetoothDevice device, {
    bool rememberSelection = false,
  }) async {
    final address = device.address;
    if (address == null || address.isEmpty) {
      return const PrinterConnectionResult(
        success: false,
        message: 'The selected printer does not expose a valid Bluetooth address.',
      );
    }

    final granted = await ensureBluetoothPermissions();
    if (!granted) {
      return const PrinterConnectionResult(
        success: false,
        message: 'Bluetooth permission is required before connecting to a printer.',
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
        return PrinterConnectionResult(
          success: true,
          message: rememberSelection
              ? 'Connected to ${device.name ?? 'the selected printer'}'
              : 'Connected to ${device.name ?? 'the printer'}',
          device: device,
        );
      }

      return PrinterConnectionResult(
        success: false,
        message: 'Could not connect to ${device.name ?? 'the printer'}.',
        device: device,
      );
    } catch (e) {
      debugPrint('[PrinterService] Connection error: $e');
      return PrinterConnectionResult(
        success: false,
        message: 'Connection failed: $e',
        device: device,
      );
    } finally {
      _isConnecting = false;
    }
  }

  /// Whether we are currently connected to a printer.
  static Future<bool> get isConnected async {
    try {
      return (await _printer.isConnected) == true;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> _ensureConnected(String address) async {
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

    final granted = await ensureBluetoothPermissions();
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
        debugPrint('[PrinterService] Printer $address not found in bonded devices');
        return false;
      }

      final result = await connect(device);
      return result.success;
    } catch (e) {
      debugPrint('[PrinterService] Auto‑connect error: $e');
      return false;
    } finally {
      _isConnecting = false;
    }
  }

  static Future<PrinterStatusSnapshot> getSelectedPrinterStatus() async {
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

    final granted = await ensureBluetoothPermissions();
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

      final connected = _connectedDevice?.address == address && await isConnected;
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
      Participant participant, String deviceId) async {
    await _loadFailedJobs();
    _cancelledPrints.remove(participant.id);
    _pendingPrints[participant.id] = false;

    try {
      debugPrint('[PrinterService] Starting print for ${participant.fullName}');

      final db = await DatabaseHelper.database;
      final eventResult = await db.query(
        'app_settings',
        where: 'key = ?',
        whereArgs: [_eventNameKey],
        limit: 1,
      );
      final eventName = eventResult.isNotEmpty
          ? eventResult.first['value'] as String
          : 'FSY Event';

      final printerAddress = await getSelectedPrinterAddress();
      if (printerAddress == null) {
        debugPrint('[PrinterService] No printer address saved');
        await _queueFailedJob(
          participant,
          deviceId,
          'No printer selected',
        );
        return const PrintReceiptResult(
          success: false,
          queuedForRetry: true,
          message: 'No printer selected. The receipt was queued for retry.',
        );
      }

      final status = await getSelectedPrinterStatus();
      if (!status.permissionsGranted) {
        await _queueFailedJob(
          participant,
          deviceId,
          'Bluetooth permission required',
        );
        return const PrintReceiptResult(
          success: false,
          queuedForRetry: true,
          message:
              'Bluetooth permission is required before printing. The receipt was queued for retry.',
        );
      }

      if (!status.isPaired) {
        await _queueFailedJob(
          participant,
          deviceId,
          'Selected printer is not paired',
        );
        return const PrintReceiptResult(
          success: false,
          queuedForRetry: true,
          message:
              'The selected printer is not paired in Android settings. The receipt was queued for retry.',
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
        debugPrint('[PrinterService] Could not connect to printer');
        await _queueFailedJob(
          participant,
          deviceId,
          'Could not connect to the selected printer',
        );
        return const PrintReceiptResult(
          success: false,
          queuedForRetry: true,
          message:
              'Could not connect to the selected printer. The receipt was queued for retry.',
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
      final receiptText = ReceiptBuilder.build(participant, eventName, deviceId);
      await _printer.write(receiptText);

      final now = DateTime.now().millisecondsSinceEpoch;
      final recorded = await _onPrintSuccess(participant, now);

      debugPrint('[PrinterService] Print successful');
      if (!recorded) {
        return const PrintReceiptResult(
          success: true,
          queuedForRetry: false,
          message:
              'Receipt printed, but the local print state could not be updated.',
        );
      }

      return const PrintReceiptResult(
        success: true,
        queuedForRetry: false,
        message: 'Receipt printed successfully.',
      );
    } catch (e) {
      debugPrint('[PrinterService] Print failed: $e');
      await _queueFailedJob(participant, deviceId, e.toString());
      return PrintReceiptResult(
        success: false,
        queuedForRetry: true,
        message: 'Print failed: $e. The receipt was queued for retry.',
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
    String reason,
  ) async {
    await _loadFailedJobs();
    _failedJobs.add(
      _FailedPrintJob(
        jobId: '${DateTime.now().microsecondsSinceEpoch}-${participant.id}',
        participant: participant,
        deviceId: deviceId,
        reason: reason,
        queuedAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    await _saveFailedJobs();
  }

  static Future<PrinterRetrySummary> retryFailedPrints() async {
    await _loadFailedJobs();
    if (_failedJobs.isEmpty) {
      return const PrinterRetrySummary(attempted: 0, succeeded: 0, remaining: 0);
    }

    final jobs = List<_FailedPrintJob>.from(_failedJobs);
    _failedJobs.clear();
    await _saveFailedJobs();

    int success = 0;
    for (final job in jobs) {
      final result = await printReceipt(job.participant, job.deviceId);
      if (result.success) {
        success++;
      }
    }

    await _loadFailedJobs();
    return PrinterRetrySummary(
      attempted: jobs.length,
      succeeded: success,
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

class _FailedPrintJob {
  final String jobId;
  final Participant participant;
  final String deviceId;
  final String reason;
  final int queuedAt;

  const _FailedPrintJob({
    required this.jobId,
    required this.participant,
    required this.deviceId,
    required this.reason,
    required this.queuedAt,
  });

  Map<String, dynamic> toJson() {
    return {
      'job_id': jobId,
      'participant': participant.toJson(),
      'device_id': deviceId,
      'reason': reason,
      'queued_at': queuedAt,
    };
  }

  factory _FailedPrintJob.fromJson(Map<String, dynamic> json) {
    return _FailedPrintJob(
      jobId: json['job_id'] as String? ?? '',
      participant: Participant.fromJson(
        Map<String, dynamic>.from(json['participant'] as Map<dynamic, dynamic>),
      ),
      deviceId: json['device_id'] as String? ?? '',
      reason: json['reason'] as String? ?? '',
      queuedAt: json['queued_at'] as int? ?? 0,
    );
  }
}
