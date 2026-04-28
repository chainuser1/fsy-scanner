import 'dart:async';
import 'dart:convert';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
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
import 'participants_screen.dart';
import 'settings_screen.dart';

class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key});

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver{
  static const String _errorSoundPath = 'assets/sounds/error_sound.mp3';
  static const String _successSoundPath = 'assets/sounds/success_sound.mp3';

  MobileScannerController controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
  );
  final AudioPlayer _audioPlayer = AudioPlayer();
  final FlutterTts _flutterTts = FlutterTts();
  StreamSubscription<Map<String, dynamic>?>? _syncSub;
  bool _isSyncingNow = false;
  bool _isCooldown = false;
  bool _torchOn = false;
  Timer? _powerSaveTimer;
  bool _powerSaveMode = false;

  // Sync progress
  String _syncStatusText = '';
  double _syncProgress = 0.0;

  late AnimationController _cardAnimController;
  late Animation<double> _cardScaleAnimation;
  late Animation<double> _cardOpacityAnimation;

  late AnimationController _reticlePulseController;
  late Animation<double> _reticlePulseAnimation;

  bool _showResultCard = false;
  String _resultName = '';
  String _resultRoom = '';
  String _resultTable = '';
  String _resultShirt = '';
  bool _resultSuccess = false;
  String? _resultParticipantId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // Listen for sync status with progress details
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

    _cardAnimController = AnimationController(
      duration: const Duration(milliseconds: 600),
      vsync: this,
    );
    _cardScaleAnimation = CurvedAnimation(
      parent: _cardAnimController,
      curve: Curves.elasticOut,
    );
    _cardOpacityAnimation = CurvedAnimation(
      parent: _cardAnimController,
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
    });
    _resetPowerSaveTimer();
    _initTts();
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
      controller.start();
    }
    _powerSaveTimer = Timer(const Duration(minutes: 10), () {
      if (mounted) {
        setState(() => _powerSaveMode = true);
        controller.stop();
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (!_isCooldown && !_showResultCard && !_powerSaveMode) {
        controller.start();
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
    String? participantId,
  }) {
    controller.stop();
    setState(() {
      _resultName = name;
      _resultRoom = room ?? 'N/A';
      _resultTable = table ?? 'N/A';
      _resultShirt = shirt ?? 'N/A';
      _resultSuccess = success;
      _resultParticipantId = participantId;
      _showResultCard = true;
    });
    _cardAnimController.forward(from: 0.0);
  }

  Future<void> _hideAnimatedResult() async {
    await _cardAnimController.reverse();
    if (mounted) {
      setState(() {
        _showResultCard = false;
        _resultParticipantId = null;
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
      controller.start();
    }
    return result;
  }

  Future<bool> _onWillPop() async {
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Exit Scanner?'),
            content: const Text(
                'Are you sure you want to leave the scanning screen?'),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Cancel')),
              TextButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('Exit')),
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
      if (mounted) controller.start();
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
          title: Image.asset('assets/transparent_background_fsy_logo.png',
              height: 40),
          leading: IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () => _navigateTo(const SettingsScreen()),
          ),
          actions: [
            // Torch toggle
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
            Padding(
              padding: const EdgeInsets.only(right: 12.0),
              child: GestureDetector(
                onTap: _showQueueVisualizer,
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
                            valueColor:
                                AlwaysStoppedAnimation<Color>(Colors.white),
                          ),
                        ),
                      )
                    else
                      const Icon(Icons.cloud_done,
                          color: Colors.white70, size: 18),
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
                        Text('OFFLINE',
                            style: TextStyle(
                                fontSize: 14, fontWeight: FontWeight.bold)),
                      ],
                    ),
                  ),
                // Sync progress indicator
                if (_isSyncingNow && _syncProgress > 0)
                  LinearProgressIndicator(
                    value: _syncProgress,
                    backgroundColor: Colors.grey[300],
                    valueColor: const AlwaysStoppedAnimation<Color>(
                        FSYScannerApp.primaryBlue),
                  ),
                if (_isSyncingNow && _syncStatusText.isNotEmpty)
                  Container(
                    color: Colors.black54,
                    padding:
                        const EdgeInsets.symmetric(vertical: 4, horizontal: 12),
                    child: Text(
                      _syncStatusText,
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                    ),
                  ),
                Expanded(
                  child: Stack(
                    children: [
                      if (!_powerSaveMode)
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
                            final participant =
                                await dao.getParticipantById(barcode);

                            if (participant == null) {
                              _playSound(_errorSoundPath);
                              _hapticFeedback(false);
                              _showAnimatedResult(
                                name: 'Participant not found',
                                success: false,
                              );
                            } else if (participant.verifiedAt != null) {
                              _playSound(_errorSoundPath);
                              _hapticFeedback(false);
                              String timeStr = '';
                              if (participant.verifiedAt != null) {
                                final dt = DateTime.fromMillisecondsSinceEpoch(
                                    participant.verifiedAt!);
                                timeStr =
                                    '${dt.hour}:${dt.minute.toString().padLeft(2, '0')}';
                              }
                              _showAnimatedResult(
                                name: participant.fullName,
                                room: participant.roomNumber,
                                table: participant.tableNumber,
                                shirt: participant.tshirtSize,
                                success: false,
                              );
                              if (mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content:
                                        Text('Already checked in at $timeStr'),
                                    backgroundColor: Colors.orange,
                                    duration: const Duration(seconds: 2),
                                  ),
                                );
                              }
                            } else {
                              final deviceId = await DeviceId.get();
                              final now = DateTime.now().millisecondsSinceEpoch;

                              await dao.markVerifiedLocally(
                                  participant.id, deviceId, now);
                              appState.addRecentScan(participant);
                              SyncEngine.notifyUserActivity();

                              await SyncQueueDao.enqueueTask(
                                  SyncQueueDao.typeMarkRegistered, {
                                'participantId': participant.id,
                                'sheetsRow': participant.sheetsRow,
                                'verifiedAt': now,
                                'registeredBy': deviceId,
                              });

                              PrinterService.printReceipt(participant, deviceId)
                                  .then((success) {
                                if (!success && mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text(
                                          'Print failed – check printer connection'),
                                      backgroundColor: Colors.orange,
                                    ),
                                  );
                                }
                              });

                              _playSound(_successSoundPath);
                              _hapticFeedback(true);
                              _speak('${participant.fullName} checked in');
                              _showAnimatedResult(
                                name: participant.fullName,
                                room: participant.roomNumber,
                                table: participant.tableNumber,
                                shirt: participant.tshirtSize,
                                success: true,
                                participantId: participant.id,
                              );
                            }

                            await Future.delayed(const Duration(seconds: 2));
                            await _hideAnimatedResult();
                            if (mounted && !_powerSaveMode) controller.start();
                            await Future.delayed(
                                const Duration(milliseconds: 300));
                            _isCooldown = false;
                            _resetPowerSaveTimer();
                          },
                        )
                      else
                        Container(
                          color: Colors.black87,
                          child: Center(
                            child: GestureDetector(
                              onTap: _resetPowerSaveTimer,
                              child: const Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.touch_app,
                                      size: 64,
                                      color: FSYScannerApp.accentGold),
                                  SizedBox(height: 16),
                                  Text('Tap to Resume',
                                      style: TextStyle(
                                          color: Colors.white, fontSize: 18)),
                                ],
                              ),
                            ),
                          ),
                        ),
                      // Reticle with pulse
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
                              border: Border.all(color: Colors.white, width: 2),
                            ),
                          ),
                        ),
                      ),
                      // Live checked‑in badge
                      Positioned(
                        top: 60,
                        left: 20,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 8),
                          decoration: BoxDecoration(
                            color: Colors.black54,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            '${appState.participantsCount} checked in',
                            style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                                fontSize: 14),
                          ),
                        ),
                      ),
                      // Animated result card
                      if (_showResultCard)
                        Positioned(
                          bottom: 80,
                          left: 24,
                          right: 24,
                          child: AnimatedBuilder(
                            animation: _cardAnimController,
                            builder: (context, child) {
                              return Opacity(
                                opacity: _cardOpacityAnimation.value,
                                child: Transform.scale(
                                  scale: _cardScaleAnimation.value,
                                  child: child,
                                ),
                              );
                            },
                            child: Card(
                              elevation: 12,
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(24)),
                              color: _resultSuccess
                                  ? FSYScannerApp.accentGreen.withAlpha(240)
                                  : Colors.red[400]!.withAlpha(240),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                    vertical: 24, horizontal: 20),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    if (_resultSuccess)
                                      Image.asset(
                                          'assets/transparent_qr_code_logo_success.png',
                                          height: 48)
                                    else
                                      Image.asset(
                                          'assets/transparent_qr_code_logo_error.png',
                                          height: 48),
                                    const SizedBox(height: 12),
                                    Text(
                                      _resultName,
                                      style: const TextStyle(
                                        fontSize: 22,
                                        fontWeight: FontWeight.bold,
                                        color: Colors.white,
                                      ),
                                      textAlign: TextAlign.center,
                                    ),
                                    if (_resultSuccess) ...[
                                      const SizedBox(height: 16),
                                      _buildDetailRow('Room', _resultRoom),
                                      _buildDetailRow('Table', _resultTable),
                                      _buildDetailRow('Shirt', _resultShirt),
                                      const SizedBox(height: 12),
                                      TextButton.icon(
                                        onPressed: _undoScan,
                                        icon: const Icon(Icons.undo,
                                            color: Colors.white),
                                        label: const Text('Undo',
                                            style:
                                                TextStyle(color: Colors.white)),
                                      ),
                                    ] else
                                      const SizedBox(height: 12),
                                    Icon(
                                      _resultSuccess
                                          ? Icons.check_circle
                                          : Icons.cancel,
                                      color: Colors.white,
                                      size: 36,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      // First‑run loading overlay
                      if (appState.isInitialLoading)
                        Container(
                          color: Colors.black.withAlpha(204),
                          child: Center(
                            child: Card(
                              margin:
                                  const EdgeInsets.symmetric(horizontal: 32),
                              child: Padding(
                                padding: const EdgeInsets.all(24.0),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Image.asset('assets/fsy_logo.png',
                                        height: 80),
                                    const SizedBox(height: 24),
                                    const Text(
                                        'Setting up for the first time...',
                                        style: TextStyle(
                                            fontSize: 18,
                                            fontWeight: FontWeight.bold)),
                                    const SizedBox(height: 16),
                                    const Text('Downloading participant list'),
                                    const SizedBox(height: 24),
                                    const CircularProgressIndicator(),
                                    if (appState.syncError != null) ...[
                                      const SizedBox(height: 24),
                                      Text('Error: ${appState.syncError}',
                                          style: const TextStyle(
                                              color: Colors.red),
                                          textAlign: TextAlign.center),
                                      const SizedBox(height: 16),
                                      ElevatedButton(
                                        onPressed: () =>
                                            appState.setSyncError(null),
                                        child: const Text('Retry'),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            // FABs
            Positioned(
              right: 16,
              bottom: 32,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Semantics(
                    label: 'Sync now',
                    child: FloatingActionButton.small(
                      heroTag: 'sync_fab',
                      onPressed: () => SyncEngine.performFullSync(appState),
                      tooltip: 'Sync now',
                      child: const Icon(Icons.sync),
                    ),
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
                      child: Icon(appState.soundEnabled
                          ? Icons.volume_up
                          : Icons.volume_off),
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

  Widget _buildDetailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text('$label: ',
              style: const TextStyle(color: Colors.white70, fontSize: 14)),
          Text(value,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w500)),
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
    _audioPlayer.dispose();
    _flutterTts.stop();
    _cardAnimController.dispose();
    _reticlePulseController.dispose();
    controller.dispose();
    super.dispose();
  }
}
