import 'dart:async';
import 'dart:convert';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../app.dart';
import '../db/database_helper.dart';
import '../db/participants_dao.dart';
import '../db/sync_queue_dao.dart';
import '../print/printer_service.dart';
import '../providers/app_state.dart';
import '../sync/sync_engine.dart';
import '../utils/device_id.dart';
import 'analytics_screen.dart';
import 'participants_screen.dart';
import 'settings_screen.dart';

class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key});

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  static const String _errorSoundPath = 'error_sound.mp3';
  static const String _successSoundPath = 'success_sound.mp3';
  static const String _warningSoundPath = 'warning_sound.mp3';

  MobileScannerController controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
  );
  final AudioPlayer _audioPlayer = AudioPlayer();
  final FlutterTts _flutterTts = FlutterTts();
  StreamSubscription<Map<String, dynamic>?>? _syncSub;
  StreamSubscription<PrinterServiceEvent>? _printerSub;
  bool _isSyncingNow = false;
  bool _isCooldown = false;
  bool _torchOn = false;
  bool _isFrontCamera = false; // remembers user’s camera choice
  Timer? _powerSaveTimer;
  bool _powerSaveMode = false;
  PermissionStatus _cameraPermissionStatus = PermissionStatus.denied;
  bool _cameraPermissionChecked = false;

  String _syncStatusText = '';
  double _syncProgress = 0.0;
  bool _showPendingConfirmationTray = false;
  bool _isResolvingPendingConfirmation = false;
  List<PrinterQueuedJob> _pendingConfirmationJobs = [];

  // Overlay animations (renamed from card* for clarity)
  late AnimationController _overlayAnimController;
  late Animation<double> _overlayScaleAnimation;
  late Animation<double> _overlayOpacityAnimation;

  late AnimationController _reticlePulseController;
  late Animation<double> _reticlePulseAnimation;

  bool _showResultCard = false;
  String _resultName = '';
  String _resultRoom = '';
  String _resultTable = '';
  String _resultShirt = '';
  bool _resultSuccess = false;
  bool _resultAlreadyChecked = false;
  String? _resultParticipantId;
  String? _resultTimeStr;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _syncSub = SyncEngine.syncStatusStream.listen((data) {
      if (mounted) {
        setState(() {
          _isSyncingNow = data['syncing'] as bool? ?? false;
          _syncStatusText = data['message'] as String? ?? '';
          _syncProgress = (data['progress'] as double?) ?? 0.0;
        });
      }
    });

    WakelockPlus.enable();

    _overlayAnimController = AnimationController(
      duration: const Duration(milliseconds: 600),
      vsync: this,
    );
    _overlayScaleAnimation = CurvedAnimation(
      parent: _overlayAnimController,
      curve: Curves.elasticOut,
    );
    _overlayOpacityAnimation = CurvedAnimation(
      parent: _overlayAnimController,
      curve: const Interval(0.0, 0.3, curve: Curves.easeIn),
    );

    _reticlePulseController = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );
    _reticlePulseAnimation = Tween<double>(begin: 1.0, end: 1.15).animate(
      CurvedAnimation(parent: _reticlePulseController, curve: Curves.easeInOut),
    );
    _reticlePulseController.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        _reticlePulseController.reverse();
      }
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<AppState>().loadPreferences();
      unawaited(context.read<AppState>().startPrinterAutomation());
      unawaited(_refreshPendingConfirmationJobs());
    });
    _printerSub = PrinterService.events.listen((_) {
      unawaited(_refreshPendingConfirmationJobs());
    });
    unawaited(_ensureCameraPermission());
    _resetPowerSaveTimer();
    _initTts();
  }

  Future<void> _ensureCameraPermission() async {
    var status = await Permission.camera.status;
    if (!status.isGranted) {
      status = await Permission.camera.request();
    }

    if (!mounted) {
      return;
    }

    setState(() {
      _cameraPermissionStatus = status;
      _cameraPermissionChecked = true;
    });
  }

  Future<void> _initTts() async {
    await _flutterTts.setLanguage('en-US');
    await _flutterTts.setSpeechRate(0.45);
    await _flutterTts.setVolume(1.0);
    await _flutterTts.setPitch(1.0);
  }

  void _resetPowerSaveTimer() {
    _powerSaveTimer?.cancel();
    if (_powerSaveMode) {
      setState(() => _powerSaveMode = false);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          controller.start();
          _ensureCameraMatchesFlag();
        }
      });
    }
    _powerSaveTimer = Timer(const Duration(minutes: 10), () {
      if (mounted) {
        setState(() => _powerSaveMode = true);
        controller.stop();
      }
    });
  }

  /// Make sure the active camera matches [_isFrontCamera].
  /// Call this after any `controller.start()` that might reset to rear.
  void _ensureCameraMatchesFlag() {
    // The controller doesn't expose which camera is currently active,
    // but we can safely toggle once if the flag says front.
    // We assume the camera is rear after a fresh start().
    if (_isFrontCamera) {
      // Small delay to let the camera initialise, then switch.
      Future.delayed(const Duration(milliseconds: 200), () {
        if (mounted) controller.switchCamera();
      });
    }
  }

  void _toggleCamera() {
    setState(() => _isFrontCamera = !_isFrontCamera);
    controller.switchCamera();
  }

  Future<void> _refreshPendingConfirmationJobs() async {
    final jobs = await PrinterService.getPendingConfirmationJobs();
    if (!mounted) {
      return;
    }
    setState(() {
      _pendingConfirmationJobs = jobs;
      if (jobs.isEmpty) {
        _showPendingConfirmationTray = false;
      }
    });
  }

  Future<void> _resolvePendingConfirmationJob(
    PrinterQueuedJob job,
    bool printed,
  ) async {
    if (_isResolvingPendingConfirmation) {
      return;
    }
    setState(() {
      _isResolvingPendingConfirmation = true;
    });
    final result = printed
        ? await PrinterService.confirmPrintDelivery(job.jobId)
        : await PrinterService.rejectPrintDelivery(job.jobId);
    await _refreshPendingConfirmationJobs();
    if (!mounted) {
      return;
    }
    setState(() {
      _isResolvingPendingConfirmation = false;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(result.message),
        backgroundColor: result.success
            ? Colors.green
            : result.queuedForRetry
                ? Colors.orange
                : Colors.red,
      ),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_ensureCameraPermission());
      if (mounted) {
        unawaited(context.read<AppState>().startPrinterAutomation());
      }
      if (_cameraPermissionStatus.isGranted &&
          !_isCooldown &&
          !_showResultCard &&
          !_powerSaveMode) {
        controller.start();
        _ensureCameraMatchesFlag();
      }
      WakelockPlus.enable();
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      controller.stop();
      WakelockPlus.disable();
    }
  }

  Future<void> _playSound(String assetPath) async {
    try {
      final appState = context.read<AppState>();
      if (appState.soundEnabled) {
        await _audioPlayer.play(AssetSource(assetPath));
      }
    } catch (e) {
      debugPrint('[ScanScreen] Sound error: $e');
    }
  }

  void _hapticFeedback(bool success) {
    final appState = context.read<AppState>();
    if (appState.hapticEnabled) {
      if (success) {
        HapticFeedback.mediumImpact();
      } else {
        HapticFeedback.heavyImpact();
      }
    }
  }

  Future<void> _speak(String text) async {
    final appState = context.read<AppState>();
    if (appState.voiceEnabled) {
      await _flutterTts.speak(text);
    }
  }

  void _pulseReticle() {
    _reticlePulseController.forward(from: 0.0);
  }

  void _toggleTorch() {
    setState(() {
      _torchOn = !_torchOn;
    });
    controller.toggleTorch();
  }

  void _showAnimatedResult({
    required String name,
    String? room,
    String? table,
    String? shirt,
    required bool success,
    required bool alreadyChecked,
    String? participantId,
    String? timeStr,
  }) {
    controller.stop();
    setState(() {
      _resultName = name;
      _resultRoom = room ?? 'N/A';
      _resultTable = table ?? 'N/A';
      _resultShirt = shirt ?? 'N/A';
      _resultSuccess = success;
      _resultAlreadyChecked = alreadyChecked;
      _resultParticipantId = participantId;
      _resultTimeStr = timeStr;
      _showResultCard = true;
    });
    _overlayAnimController.forward(from: 0.0);
  }

  Future<void> _hideAnimatedResult() async {
    await _overlayAnimController.reverse();
    if (mounted) {
      setState(() {
        _showResultCard = false;
        _resultParticipantId = null;
        _resultAlreadyChecked = false;
        _resultTimeStr = null;
      });
    }
  }

  Future<T?> _navigateTo<T>(Widget screen) async {
    controller.stop();
    final result = await Navigator.push<T>(
      context,
      MaterialPageRoute(builder: (context) => screen),
    );
    if (mounted &&
        !_isCooldown &&
        !_showResultCard &&
        !_powerSaveMode &&
        !context.read<AppState>().isInitialLoading) {
      unawaited(context.read<AppState>().startPrinterAutomation());
      controller.start();
      _ensureCameraMatchesFlag();
    }
    return result;
  }

  Future<bool> _onWillPop() async {
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Exit Scanner?'),
            content: const Text(
              'Are you sure you want to leave the scanning screen?',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Exit'),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _showQueueVisualizer() async {
    final tasks = await SyncQueueDao.getAllPendingTasks();
    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      builder: (context) {
        return DraggableScrollableSheet(
          initialChildSize: 0.4,
          maxChildSize: 0.8,
          minChildSize: 0.2,
          expand: false,
          builder: (context, scrollController) {
            return ListView.builder(
              controller: scrollController,
              itemCount: tasks.length,
              itemBuilder: (context, index) {
                final task = tasks[index];
                final payload = task['payload'] as String;
                Map<String, dynamic> data;
                try {
                  data = jsonDecode(payload) as Map<String, dynamic>;
                } catch (_) {
                  data = {};
                }
                final name = data['participantId'] ?? 'Unknown';
                return ListTile(
                  title: Text(name.toString()),
                  subtitle: Text(task['type'].toString()),
                  trailing: Text(task['status'].toString()),
                );
              },
            );
          },
        );
      },
    );
  }

  Future<void> _undoScan() async {
    final participantId = _resultParticipantId;
    if (participantId == null) return;
    final appState = context.read<AppState>();
    final success = await appState.undoRecentScan(participantId);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(success ? 'Scan undone' : 'Undo failed'),
          backgroundColor: success ? Colors.green : Colors.red,
        ),
      );
    }
    if (success) {
      await _hideAnimatedResult();
      if (mounted) {
        controller.start();
        _ensureCameraMatchesFlag();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final appState = Provider.of<AppState>(context);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        final shouldPop = await _onWillPop();
        if (shouldPop && mounted) {
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Image.asset(
            'assets/transparent_background_fsy_logo.png',
            height: 40,
          ),
          leading: IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () => _navigateTo(const SettingsScreen()),
          ),
          actions: [
            IconButton(
              icon: Icon(
                _torchOn ? Icons.flashlight_on : Icons.flashlight_off,
                color: Colors.white,
              ),
              onPressed: _toggleTorch,
              tooltip: 'Toggle flashlight',
            ),
            IconButton(
              icon: const Icon(Icons.people),
              onPressed: () => _navigateTo(const ParticipantsScreen()),
            ),
            IconButton(
              icon: const Icon(Icons.dashboard),
              onPressed: () => _navigateTo(const AnalyticsScreen()),
            ),
            Padding(
              padding: const EdgeInsets.only(right: 12.0),
              child: GestureDetector(
                onTap: _showQueueVisualizer,
                onLongPress: () {
                  SyncEngine.pushImmediately(appState);
                },
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_isSyncingNow)
                      const Padding(
                        padding: EdgeInsets.only(right: 4.0),
                        child: SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation<Color>(
                              Colors.white,
                            ),
                          ),
                        ),
                      )
                    else
                      const Icon(
                        Icons.cloud_done,
                        color: Colors.white70,
                        size: 18,
                      ),
                    const SizedBox(width: 4),
                    Container(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _isSyncingNow
                            ? Colors.blue[300]
                            : appState.syncError != null
                                ? Colors.red[300]
                                : FSYScannerApp.accentGold,
                      ),
                      padding: const EdgeInsets.all(6),
                      child: Text(
                        '${appState.pendingTaskCount}',
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: Colors.black,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
        body: Stack(
          children: [
            Column(
              children: [
                if (!appState.isOnline)
                  Container(
                    width: double.infinity,
                    color: FSYScannerApp.accentGold,
                    padding: const EdgeInsets.all(8.0),
                    child: const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.cloud_off, size: 18),
                        SizedBox(width: 8),
                        Text(
                          'OFFLINE',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                if (appState.printerAddress != null &&
                    (!appState.printerConnected ||
                        appState.printerFailedJobCount > 0))
                  Container(
                    width: double.infinity,
                    color: appState.printerConnected
                        ? Colors.orange.shade200
                        : Colors.red.shade200,
                    padding: const EdgeInsets.all(8.0),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          appState.printerConnected
                              ? Icons.receipt_long
                              : Icons.bluetooth_disabled,
                          size: 18,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            appState.printerConnected
                                ? '${appState.printerFailedJobCount} receipt${appState.printerFailedJobCount == 1 ? '' : 's'} waiting to retry automatically.'
                                : appState.printerFailedJobCount > 0
                                    ? 'Printer disconnected. Continue scanning; ${appState.printerFailedJobCount} receipt${appState.printerFailedJobCount == 1 ? '' : 's'} queued for auto-retry.'
                                    : 'Printer disconnected. Continue scanning; receipts will queue until the printer reconnects.',
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ],
                    ),
                  ),
                if (!_powerSaveMode && _isSyncingNow && _syncProgress > 0)
                  LinearProgressIndicator(
                    value: _syncProgress,
                    backgroundColor: Colors.grey[300],
                    valueColor: const AlwaysStoppedAnimation<Color>(
                      FSYScannerApp.primaryBlue,
                    ),
                  ),
                if (!_powerSaveMode &&
                    _isSyncingNow &&
                    _syncStatusText.isNotEmpty)
                  Container(
                    color: Colors.black54,
                    padding: const EdgeInsets.symmetric(
                      vertical: 4,
                      horizontal: 12,
                    ),
                    child: Text(
                      _syncStatusText,
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                    ),
                  ),
                Expanded(
                  child: Stack(
                    children: [
                      if (!_powerSaveMode)
                        if (_cameraPermissionStatus.isGranted)
                          MobileScanner(
                            controller: controller,
                            onDetect: (capture) async {
                              if (_isCooldown || _showResultCard) return;
                              final String? barcode =
                                  capture.barcodes.first.rawValue;
                              if (barcode == null || barcode.isEmpty) return;

                              _pulseReticle();
                              _isCooldown = true;

                              final db = await DatabaseHelper.database;
                              final dao = ParticipantsDao(db);
                              final participant = await dao.getParticipantById(
                                barcode,
                              );

                              if (participant == null) {
                                _playSound(_errorSoundPath);
                                _hapticFeedback(false);
                                _showAnimatedResult(
                                  name: 'Participant not found',
                                  success: false,
                                  alreadyChecked: false,
                                );
                              } else if (participant.isVerified) {
                                _playSound(_warningSoundPath);
                                _hapticFeedback(false);
                                String timeStr = '';
                                if (participant.verifiedAt != null) {
                                  final dt =
                                      DateTime.fromMillisecondsSinceEpoch(
                                    participant.verifiedAt!,
                                  );
                                  timeStr =
                                      '${dt.hour}:${dt.minute.toString().padLeft(2, '0')}';
                                }
                                _showAnimatedResult(
                                  name: participant.fullName,
                                  room: participant.roomNumber,
                                  table: participant.tableNumber,
                                  shirt: participant.tshirtSize,
                                  success: false,
                                  timeStr: timeStr,
                                  alreadyChecked: true,
                                );
                              } else {
                                final deviceId = await DeviceId.get();
                                final now =
                                    DateTime.now().millisecondsSinceEpoch;

                                await ParticipantsDao.markVerifiedAndQueue(
                                  participant.id,
                                  deviceId,
                                  now,
                                );
                                appState.addRecentScan(participant);
                                unawaited(appState.refreshParticipantsCount());
                                SyncEngine.notifyUserActivity();

                                var printResult =
                                    await PrinterService.printReceipt(
                                  participant,
                                  deviceId,
                                );
                                if (printResult.requiresOperatorConfirmation &&
                                    printResult.confirmationJobId != null &&
                                    mounted) {
                                  printResult = await _confirmPrintedOutput(
                                    printResult.confirmationJobId!,
                                  );
                                }
                                if (mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        printResult.awaitingOperatorConfirmation
                                            ? 'Receipt queued for confirmation for ${participant.fullName}'
                                            : printResult.success
                                                ? 'Receipt confirmed for ${participant.fullName}'
                                                : printResult.message,
                                      ),
                                      backgroundColor: printResult
                                              .awaitingOperatorConfirmation
                                          ? Colors.blueGrey
                                          : printResult.success
                                              ? Colors.green
                                              : printResult.queuedForRetry
                                                  ? Colors.orange
                                                  : Colors.red,
                                    ),
                                  );
                                }

                                _playSound(_successSoundPath);
                                _hapticFeedback(true);
                                _speak(
                                  '${participant.fullName} partially verified',
                                );
                                _showAnimatedResult(
                                  name: participant.fullName,
                                  room: participant.roomNumber,
                                  table: participant.tableNumber,
                                  shirt: participant.tshirtSize,
                                  success: true,
                                  alreadyChecked: false,
                                  participantId: participant.id,
                                );
                              }

                              await Future.delayed(const Duration(seconds: 2));
                              await _hideAnimatedResult();
                              if (mounted && !_powerSaveMode) {
                                controller.start();
                                _ensureCameraMatchesFlag();
                              }
                              await Future.delayed(
                                const Duration(milliseconds: 300),
                              );
                              _isCooldown = false;
                              _resetPowerSaveTimer();
                            },
                          )
                        else if (_cameraPermissionChecked)
                          Material(
                            color: Colors.black87,
                            child: Center(
                              child: Padding(
                                padding: const EdgeInsets.all(24),
                                child: Card(
                                  child: Padding(
                                    padding: const EdgeInsets.all(24),
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        const Icon(
                                          Icons.camera_alt,
                                          size: 56,
                                          color: FSYScannerApp.primaryBlue,
                                        ),
                                        const SizedBox(height: 16),
                                        const Text(
                                          'Camera Permission Required',
                                          style: TextStyle(
                                            fontSize: 18,
                                            fontWeight: FontWeight.bold,
                                          ),
                                          textAlign: TextAlign.center,
                                        ),
                                        const SizedBox(height: 12),
                                        Text(
                                          _cameraPermissionStatus
                                                  .isPermanentlyDenied
                                              ? 'Camera access was permanently denied. Open app settings to enable scanning.'
                                              : 'Allow camera access to scan participant QR codes.',
                                          textAlign: TextAlign.center,
                                        ),
                                        const SizedBox(height: 16),
                                        ElevatedButton(
                                          onPressed: _cameraPermissionStatus
                                                  .isPermanentlyDenied
                                              ? openAppSettings
                                              : _ensureCameraPermission,
                                          child: Text(
                                            _cameraPermissionStatus
                                                    .isPermanentlyDenied
                                                ? 'Open Settings'
                                                : 'Grant Camera Access',
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          )
                        else
                          const Center(child: CircularProgressIndicator())
                      else
                        Material(
                          color: Colors.black87,
                          child: InkWell(
                            onTap: _resetPowerSaveTimer,
                            child: const Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.touch_app,
                                    size: 64,
                                    color: FSYScannerApp.accentGold,
                                  ),
                                  SizedBox(height: 16),
                                  Text(
                                    'Tap to Resume',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 18,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      if (!_powerSaveMode && _cameraPermissionStatus.isGranted)
                        Center(
                          child: AnimatedBuilder(
                            animation: _reticlePulseAnimation,
                            builder: (context, child) {
                              return Transform.scale(
                                scale: _reticlePulseAnimation.value,
                                child: child,
                              );
                            },
                            child: Container(
                              width: 260,
                              height: 260,
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(
                                  color: Colors.white,
                                  width: 2,
                                ),
                              ),
                            ),
                          ),
                        ),
                      Positioned(
                        top: 60,
                        left: 20,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black54,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            '${appState.participantsCount} checked in',
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 14,
                            ),
                          ),
                        ),
                      ),
                      // Full-screen result overlay
                      if (_showResultCard)
                        Positioned.fill(
                          child: AnimatedBuilder(
                            animation: _overlayAnimController,
                            builder: (context, child) {
                              return Opacity(
                                opacity: _overlayOpacityAnimation.value,
                                child: Transform.scale(
                                  scale: _overlayScaleAnimation.value,
                                  child: child,
                                ),
                              );
                            },
                            child: Container(
                              color: _resultSuccess
                                  ? FSYScannerApp.accentGreen.withAlpha(230)
                                  : _resultAlreadyChecked
                                      ? Colors.orange.withAlpha(230)
                                      : Colors.redAccent.withAlpha(230),
                              child: Center(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Spacer(),
                                    Image.asset(
                                      _resultSuccess
                                          ? 'assets/transparent_qr_code_logo_success.png'
                                          : 'assets/transparent_qr_code_logo_error.png',
                                      height: 130,
                                    ),
                                    const SizedBox(height: 24),
                                    Text(
                                      _resultName,
                                      style: const TextStyle(
                                        fontSize: 28,
                                        fontWeight: FontWeight.bold,
                                        color: Colors.white,
                                      ),
                                      textAlign: TextAlign.center,
                                    ),
                                    if (_resultAlreadyChecked &&
                                        _resultTimeStr != null)
                                      Padding(
                                        padding: const EdgeInsets.only(top: 12),
                                        child: Text(
                                          'Checked in at $_resultTimeStr',
                                          style: const TextStyle(
                                            fontSize: 18,
                                            color: Colors.white70,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ),
                                    if (_resultSuccess) ...[
                                      const SizedBox(height: 20),
                                      _buildDetailRow('Room', _resultRoom),
                                      _buildDetailRow('Table', _resultTable),
                                      _buildDetailRow('Shirt', _resultShirt),
                                      const SizedBox(height: 24),
                                      OutlinedButton.icon(
                                        onPressed: _undoScan,
                                        icon: const Icon(
                                          Icons.undo,
                                          color: Colors.white,
                                        ),
                                        label: const Text(
                                          'Undo',
                                          style: TextStyle(color: Colors.white),
                                        ),
                                        style: OutlinedButton.styleFrom(
                                          foregroundColor: Colors.white,
                                          side: const BorderSide(
                                            color: Colors.white70,
                                          ),
                                          backgroundColor:
                                              Colors.white.withAlpha(38),
                                        ),
                                      ),
                                    ] else
                                      const SizedBox(height: 24),
                                    const Spacer(),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      if (appState.isInitialLoading)
                        Container(
                          color: Colors.black.withAlpha(204),
                          child: Center(
                            child: Card(
                              margin: const EdgeInsets.symmetric(
                                horizontal: 32,
                              ),
                              child: Padding(
                                padding: const EdgeInsets.all(24.0),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Image.asset(
                                      'assets/fsy_logo.png',
                                      height: 80,
                                    ),
                                    const SizedBox(height: 24),
                                    const Text(
                                      'Setting up for the first time...',
                                      style: TextStyle(
                                        fontSize: 18,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    const SizedBox(height: 16),
                                    const Text('Downloading participant list'),
                                    const SizedBox(height: 24),
                                    const CircularProgressIndicator(),
                                    if (appState.syncError != null) ...[
                                      const SizedBox(height: 24),
                                      Text(
                                        'Error: ${appState.syncError}',
                                        style: const TextStyle(
                                          color: Colors.red,
                                        ),
                                        textAlign: TextAlign.center,
                                      ),
                                      const SizedBox(height: 16),
                                      ElevatedButton(
                                        onPressed: () => SyncEngine.retryNow(
                                          context.read<AppState>(),
                                        ),
                                        child: const Text('Retry'),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      if (!appState.isInitialLoading &&
                          !_powerSaveMode &&
                          _pendingConfirmationJobs.isNotEmpty)
                        Positioned(
                          left: 16,
                          right: 88,
                          bottom: 20,
                          child: _buildPendingConfirmationTray(),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            Positioned(
              right: 16,
              bottom: 32,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Camera flip (uses persistent state)
                  FloatingActionButton.small(
                    heroTag: 'camera_flip',
                    onPressed: _toggleCamera,
                    tooltip: 'Flip camera (front/back)',
                    child: const Icon(Icons.flip_camera_android),
                  ),
                  const SizedBox(height: 8),
                  Semantics(
                    label:
                        appState.soundEnabled ? 'Mute sounds' : 'Enable sounds',
                    child: FloatingActionButton.small(
                      heroTag: 'sound_fab',
                      onPressed: () =>
                          appState.setSoundEnabled(!appState.soundEnabled),
                      tooltip: appState.soundEnabled
                          ? 'Mute sounds'
                          : 'Enable sounds',
                      child: Icon(
                        appState.soundEnabled
                            ? Icons.volume_up
                            : Icons.volume_off,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Semantics(
                    label: appState.hapticEnabled
                        ? 'Disable vibration'
                        : 'Enable vibration',
                    child: FloatingActionButton.small(
                      heroTag: 'haptic_fab',
                      onPressed: () =>
                          appState.setHapticEnabled(!appState.hapticEnabled),
                      tooltip: appState.hapticEnabled
                          ? 'Disable vibration'
                          : 'Enable vibration',
                      child: Icon(
                        Icons.vibration,
                        color: appState.hapticEnabled ? null : Colors.grey,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
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

  Widget _buildPendingConfirmationTray() {
    final visibleJobs = _pendingConfirmationJobs.take(2).toList();
    final extraCount = _pendingConfirmationJobs.length - visibleJobs.length;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.black.withAlpha(150),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withAlpha(30)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: () {
              setState(() {
                _showPendingConfirmationTray = !_showPendingConfirmationTray;
              });
            },
            child: Row(
              children: [
                const Icon(
                  Icons.pending_actions,
                  color: Colors.white70,
                  size: 18,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${_pendingConfirmationJobs.length} pending print${_pendingConfirmationJobs.length == 1 ? '' : 's'}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                Icon(
                  _showPendingConfirmationTray
                      ? Icons.expand_more
                      : Icons.chevron_right,
                  color: Colors.white70,
                  size: 18,
                ),
              ],
            ),
          ),
          if (_showPendingConfirmationTray) ...[
            const SizedBox(height: 8),
            ...visibleJobs.map(
              (job) => Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        job.participantName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 12,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    TextButton(
                      onPressed: _isResolvingPendingConfirmation
                          ? null
                          : () => _resolvePendingConfirmationJob(job, false),
                      style: TextButton.styleFrom(
                        minimumSize: Size.zero,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 6,
                        ),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: const Text(
                        'Retry',
                        style: TextStyle(fontSize: 12),
                      ),
                    ),
                    FilledButton.tonal(
                      onPressed: _isResolvingPendingConfirmation
                          ? null
                          : () => _resolvePendingConfirmationJob(job, true),
                      style: FilledButton.styleFrom(
                        minimumSize: Size.zero,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        backgroundColor: Colors.white.withAlpha(24),
                        foregroundColor: Colors.white,
                      ),
                      child: const Text(
                        'Printed',
                        style: TextStyle(fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (extraCount > 0)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '+$extraCount more in Settings',
                  style: const TextStyle(
                    color: Colors.white54,
                    fontSize: 11,
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }

  Widget _buildDetailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            '$label: ',
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 16,
              fontWeight: FontWeight.w500,
            ),
          ),
          Text(
            value,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _powerSaveTimer?.cancel();
    WakelockPlus.disable();
    WidgetsBinding.instance.removeObserver(this);
    _syncSub?.cancel();
    _printerSub?.cancel();
    _audioPlayer.dispose();
    _flutterTts.stop();
    _overlayAnimController.dispose();
    _reticlePulseController.dispose();
    controller.dispose();
    super.dispose();
  }
}
