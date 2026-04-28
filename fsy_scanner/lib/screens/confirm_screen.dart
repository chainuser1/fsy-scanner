import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../db/database_helper.dart';
import '../db/participants_dao.dart';
import '../db/sync_queue_dao.dart';
import '../models/participant.dart';
import '../print/printer_service.dart';
import '../providers/app_state.dart';
import '../utils/device_id.dart';

class ConfirmScreen extends StatefulWidget {
  final Participant participant;

  const ConfirmScreen({super.key, required this.participant});

  @override
  State<ConfirmScreen> createState() => _ConfirmScreenState();
}

class _ConfirmScreenState extends State<ConfirmScreen> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Confirm Registration'),
        backgroundColor: Colors.blue[600],
        foregroundColor: Colors.white,
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Participant card
              Card(
                elevation: 4,
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.participant.fullName,
                        style: const TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 16),
                      _buildInfoRow('Stake:', widget.participant.stake ?? '(not assigned)'),
                      _buildInfoRow('Ward:', widget.participant.ward ?? '(not assigned)'),
                      _buildInfoRow('Room:', widget.participant.roomNumber ?? '(not assigned)'),
                      _buildInfoRow('Table:', widget.participant.tableNumber ?? '(not assigned)'),
                      _buildInfoRow('Shirt:', widget.participant.tshirtSize ?? '(not assigned)'),
                    ],
                  ),
                ),
              ),

              // Medical info warning if not empty
              if (widget.participant.medicalInfo != null && widget.participant.medicalInfo!.isNotEmpty)
                Card(
                  color: Colors.yellow[100],
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          '⚠ MEDICAL WARNING',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: Colors.red,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          widget.participant.medicalInfo!,
                          style: const TextStyle(fontSize: 16),
                        ),
                      ],
                    ),
                  ),
                ),

              // Note if not empty
              if (widget.participant.note != null && widget.participant.note!.isNotEmpty)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Note:',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          widget.participant.note!,
                          style: const TextStyle(fontSize: 16),
                        ),
                      ],
                    ),
                  ),
                ),

              const SizedBox(height: 32),

              // Buttons
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () => Navigator.pop(context),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.grey,
                        foregroundColor: Colors.white,
                      ),
                      child: const Text('Cancel'),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () => _confirmCheckIn(context),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.green,
                        foregroundColor: Colors.white,
                      ),
                      child: const Text('Confirm Check-In'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8.0),
      child: Row(
        children: [
          SizedBox(
            width: 70,
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          Text(
            value,
            style: const TextStyle(fontSize: 16),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmCheckIn(BuildContext context) async {
    if (!mounted) return;
    
    // Get app state first before any async operations
    final appState = Provider.of<AppState>(context, listen: false);
    
    // Mark participant as registered locally
    final db = await DatabaseHelper.database;
    final dao = ParticipantsDao(db);
    final deviceId = await DeviceId.get();
    final now = DateTime.now().millisecondsSinceEpoch;
    
    await dao.markRegisteredLocally(
      widget.participant.id,
      deviceId,
      now,
    );

    // Enqueue sync task
    await SyncQueueDao.enqueueTask(
      SyncQueueDao.typeMarkRegistered,
      widget.participant.toJson()..['registered'] = 1..['verified_at'] = now..['registered_by'] = deviceId,
    );

    // Print receipt (fire and forget) - ignore unawaited result
    unawaited(PrinterService.printReceipt(widget.participant, deviceId));

    // Update app state
    appState.setLastScanResult('success');

    // Ensure we're still mounted before navigation and snackbar
    if (mounted) {
      // Navigate back to scan screen
      Navigator.pop(context);
    }
    
    // Wait a frame to ensure navigation completes if mounted
    await Future<void>.delayed(Duration.zero);
    
    // Show success snackbar only if still mounted after navigation
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Registration confirmed'),
          backgroundColor: Colors.green,
        ),
      );
    }
  }
}