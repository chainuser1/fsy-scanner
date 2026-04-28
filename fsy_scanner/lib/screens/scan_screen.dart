import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:provider/provider.dart';

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

class _ScanScreenState extends State<ScanScreen> {
  MobileScannerController controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
  );
  final AudioPlayer _audioPlayer = AudioPlayer();
  StreamSubscription<bool>? _syncSub;
  bool _isSyncingNow = false;

  @override
  void initState() {
    super.initState();
    _syncSub = SyncEngine.syncStatusStream.listen((syncing) {
      if (mounted) setState(() => _isSyncingNow = syncing);
    });
  }

  Future<void> _playSound(String url) async {
    final db = await DatabaseHelper.database;
    final result = await db
        .query('app_settings', where: 'key = ?', whereArgs: ['sound_enabled']);
    final enabled = result.isEmpty || result.first['value'] != 'false';
    if (enabled) {
      await _audioPlayer.play(UrlSource(url));
    }
  }

  @override
  Widget build(BuildContext context) {
    final appState = Provider.of<AppState>(context);

    return Scaffold(
      appBar: AppBar(
        title: Image.asset(
          'assets/transparent_background_fsy_logo.png',
          height: 40,
        ),
        backgroundColor: Colors.blue[600],
        foregroundColor: Colors.white,
        leading: IconButton(
          icon: const Icon(Icons.settings),
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (context) => const SettingsScreen()),
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.people),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                  builder: (context) => const ParticipantsScreen()),
            ),
          ),
          // Dynamic sync status indicator
          Padding(
            padding: const EdgeInsets.only(right: 12.0),
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
                        valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                      ),
                    ),
                  )
                else
                  const Icon(Icons.cloud_done, color: Colors.white70, size: 18),
                const SizedBox(width: 4),
                GestureDetector(
                  onTap: () {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          _isSyncingNow
                              ? 'Sync in progress… ${appState.pendingTaskCount} pending'
                              : '${appState.pendingTaskCount} tasks pending sync',
                        ),
                      ),
                    );
                  },
                  child: Container(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _isSyncingNow
                          ? Colors.blue[300]
                          : appState.syncError != null
                              ? Colors.red[300]
                              : Colors.orange[300],
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
                ),
              ],
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          if (!appState.isOnline)
            Container(
              width: double.infinity,
              color: Colors.red[300],
              padding: const EdgeInsets.all(8.0),
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.cloud_off, size: 18),
                  SizedBox(width: 8),
                  Text('OFFLINE',
                      style:
                          TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                ],
              ),
            ),
          Expanded(
            child: Stack(
              children: [
                MobileScanner(
                  controller: controller,
                  onDetect: (capture) async {
                    final String? barcode = capture.barcodes.first.rawValue;
                    if (barcode == null || barcode.isEmpty) return;

                    controller.stop();

                    final db = await DatabaseHelper.database;
                    final dao = ParticipantsDao(db);
                    final participant = await dao.getParticipantById(barcode);

                    if (participant == null) {
                      _playSound(
                          'https://assets.mixkit.co/active_storage/sfx/948/948-preview.mp3');
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Participant not found'),
                            backgroundColor: Colors.red,
                            duration: Duration(seconds: 2),
                          ),
                        );
                        await Future.delayed(const Duration(seconds: 2));
                        if (mounted) controller.start();
                      }
                    } else if (participant.verifiedAt != null) {
                      _playSound(
                          'https://assets.mixkit.co/active_storage/sfx/948/948-preview.mp3');
                      if (mounted) {
                        String timeStr = '';
                        if (participant.verifiedAt != null) {
                          final dt = DateTime.fromMillisecondsSinceEpoch(
                              participant.verifiedAt!);
                          timeStr =
                              '${dt.hour}:${dt.minute.toString().padLeft(2, '0')}';
                        }
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                                'Already checked in — ${participant.fullName} at $timeStr'),
                            backgroundColor: Colors.orange,
                            duration: const Duration(seconds: 2),
                          ),
                        );
                        await Future.delayed(const Duration(seconds: 2));
                        if (mounted) controller.start();
                      }
                    } else {
                      // New check‑in
                      final deviceId = await DeviceId.get();
                      final now = DateTime.now().millisecondsSinceEpoch;

                      await dao.markVerifiedLocally(
                          participant.id, deviceId, now);
                      SyncEngine.notifyUserActivity();

                      await SyncQueueDao.enqueueTask(
                          SyncQueueDao.typeMarkRegistered, {
                        'participantId': participant.id,
                        'sheetsRow': participant.sheetsRow,
                        'verifiedAt': now,
                        'registeredBy': deviceId,
                      });

                      unawaited(
                          PrinterService.printReceipt(participant, deviceId));

                      _playSound(
                          'https://assets.mixkit.co/active_storage/sfx/2039/2039-preview.mp3');
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content:
                                Text('✓ ${participant.fullName} checked in'),
                            backgroundColor: Colors.green,
                            duration: const Duration(seconds: 1),
                          ),
                        );
                      }

                      await Future.delayed(const Duration(milliseconds: 800));
                      if (mounted) controller.start();
                    }
                  },
                ),
                Center(
                  child: Container(
                    width: 260,
                    height: 260,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: Colors.white, width: 2),
                    ),
                  ),
                ),
                if (appState.isInitialLoading)
                  Container(
                    color: Colors.black.withAlpha(204),
                    child: Center(
                      child: Card(
                        margin: const EdgeInsets.symmetric(horizontal: 32),
                        child: Padding(
                          padding: const EdgeInsets.all(24.0),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Image.asset(
                                'assets/fsy_logo.png',
                                height: 80,
                              ),
                              const Text('Setting up for the first time...',
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
                                    style: const TextStyle(color: Colors.red),
                                    textAlign: TextAlign.center),
                                const SizedBox(height: 16),
                                ElevatedButton(
                                  onPressed: () => appState.setSyncError(null),
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
    );
  }

  @override
  void dispose() {
    _syncSub?.cancel();
    _audioPlayer.dispose();
    controller.dispose();
    super.dispose();
  }
}
