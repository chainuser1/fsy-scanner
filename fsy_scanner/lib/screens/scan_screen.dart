import 'dart:async';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:provider/provider.dart';

import '../db/database_helper.dart';
import '../db/participants_dao.dart';
import '../db/sync_queue_dao.dart';
import '../print/printer_service.dart';
import '../utils/device_id.dart';
import '../providers/app_state.dart';
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

  @override
  Widget build(BuildContext context) {
    final appState = Provider.of<AppState>(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('FSY Scanner'),
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
              MaterialPageRoute(builder: (context) => const ParticipantsScreen()),
            ),
          ),
          // Pending sync task count badge
          GestureDetector(
            onTap: () {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('${appState.pendingTaskCount} tasks pending sync')),
              );
            },
            child: Container(
              margin: const EdgeInsets.only(right: 16),
              child: CircleAvatar(
                radius: 15,
                backgroundColor: appState.syncError != null ? Colors.red[300] : Colors.orange[300],
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
          ),
        ],
      ),
      body: Stack(
        children: [
          MobileScanner(
            controller: controller,
            onDetect: (capture) async {
              final String? barcode = capture.barcodes.first.rawValue;

              if (barcode != null && barcode.isNotEmpty) {
                // Pause scanning for 2 seconds
                controller.stop();

                // Look up participant in SQLite
                final db = await DatabaseHelper.database;
                final dao = ParticipantsDao(db);
                final participant = await dao.getParticipantById(barcode);

                if (participant == null) {
                  // Participant not found
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Participant not found'),
                        backgroundColor: Colors.red,
                        duration: Duration(seconds: 2),
                      ),
                    );
                    
                    // Resume scanning after 2 seconds
                    await Future.delayed(const Duration(seconds: 2));
                    if (mounted) {
                      controller.start();
                    }
                  }
                } else if (participant.registered == 1) {
                  // Already checked in
                  if (mounted) {
                    String timeStr = '';
                    if (participant.verifiedAt != null) {
                      final dt = DateTime.fromMillisecondsSinceEpoch(participant.verifiedAt!);
                      timeStr = '${dt.hour}:${dt.minute.toString().padLeft(2, '0')}';
                    }
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('Already checked in — ${participant.fullName} at $timeStr'),
                        backgroundColor: Colors.orange,
                        duration: Duration(seconds: 2),
                      ),
                    );
                    
                    // Resume scanning after 2 seconds
                    await Future.delayed(const Duration(seconds: 2));
                    if (mounted) {
                      controller.start();
                    }
                  }
                } else {
                  // Fast path: auto-check-in and print (no confirmation)
                  final deviceId = await DeviceId.get();
                  final now = DateTime.now().millisecondsSinceEpoch;

                  // Mark locally as registered
                  await dao.markRegisteredLocally(participant.id, deviceId, now);

                  // Enqueue a mark_registered task for the pusher
                  await SyncQueueDao.enqueueTask('mark_registered', {
                    'participantId': participant.id,
                    'sheetsRow': participant.sheetsRow,
                    'verifiedAt': now,
                    'registeredBy': deviceId,
                  });

                  // Fire-and-forget print
                  unawaited(PrinterService.printReceipt(participant, deviceId));

                  // Show quick success feedback
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('✓ ${participant.fullName} checked in'),
                        backgroundColor: Colors.green,
                        duration: const Duration(seconds: 1),
                      ),
                    );
                  }

                  // Short pause then resume scanning
                  await Future.delayed(const Duration(milliseconds: 800));
                  if (mounted) controller.start();
                }
              }
            },
          ),
          // Centered scanning reticle: 260×260 square overlay
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
          // First-run loading state overlay
          if (appState.isInitialLoading)
            Container(
              color: Colors.black.withValues(alpha: 0.8),
              child: Center(
                child: Card(
                  margin: const EdgeInsets.symmetric(horizontal: 32),
                  child: Padding(
                    padding: const EdgeInsets.all(24.0),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text(
                          'Setting up for the first time...',
                          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 16),
                        const Text('Downloading participant list'),
                        const SizedBox(height: 24),
                        const CircularProgressIndicator(),
                        if (appState.syncError != null) ...[
                          const SizedBox(height: 24),
                          Text(
                            'Error: ${appState.syncError}',
                            style: const TextStyle(color: Colors.red),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 16),
                          ElevatedButton(
                            onPressed: () {
                              appState.setSyncError(null);
                              // SyncEngine tick will retry
                            },
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
    );
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }
}
