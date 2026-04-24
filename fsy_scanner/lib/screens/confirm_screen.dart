import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../db/database_helper.dart';
import '../db/participants_dao.dart';
import '../db/sync_queue_dao.dart';
import '../models/participant.dart';
import '../print/printer_service.dart';
import '../providers/app_state.dart';
import '../utils/device_id.dart';

class ConfirmScreen extends StatelessWidget {
  final Participant participant;

  const ConfirmScreen({super.key, required this.participant});

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
                        participant.fullName,
                        style: const TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 16),
                      _buildInfoRow('Stake:', participant.stake ?? '(not assigned)'),
                      _buildInfoRow('Ward:', participant.ward ?? '(not assigned)'),
                      _buildInfoRow('Room:', participant.roomNumber ?? '(not assigned)'),
                      _buildInfoRow('Table:', participant.tableNumber ?? '(not assigned)'),
                      _buildInfoRow('Shirt:', participant.tshirtSize ?? '(not assigned)'),
                    ],
                  ),
                ),
              ),

              // Medical info warning if not empty
              if (participant.medicalInfo != null && participant.medicalInfo!.isNotEmpty)
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
                          participant.medicalInfo!,
                          style: const TextStyle(fontSize: 16),
                        ),
                      ],
                    ),
                  ),
                ),

              // Note if not empty
              if (participant.note != null && participant.note!.isNotEmpty)
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
                          participant.note!,
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
    // Mark participant as registered locally
    final db = await DatabaseHelper.database;
    final dao = ParticipantsDao(db);
    final deviceId = await DeviceId.get();
    final now = DateTime.now().millisecondsSinceEpoch;
    
    await dao.markRegisteredLocally(
      participant.id,
      deviceId,
      now,
    );

    // Enqueue sync task
    await SyncQueueDao.enqueueTask(
      'UPDATE',
      participant.toJson()..['registered'] = 1..['verified_at'] = now..['registered_by'] = deviceId,
    );

    // Print receipt (fire and forget)
    PrinterService.printReceipt(participant, deviceId);

    // Update app state
    final appState = Provider.of<AppState>(context, listen: false);
    appState.setLastScanResult('success');

    // Navigate back to scan screen
    Navigator.pop(context);

    // Show success snackbar
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Registration confirmed'),
        backgroundColor: Colors.green,
      ),
    );
  }
}