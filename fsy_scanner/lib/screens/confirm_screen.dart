import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app.dart';
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
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
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
                      _buildInfoRow('Stake:',
                          widget.participant.stake ?? '(not assigned)'),
                      _buildInfoRow(
                          'Ward:', widget.participant.ward ?? '(not assigned)'),
                      _buildInfoRow('Room:',
                          widget.participant.roomNumber ?? '(not assigned)'),
                      _buildInfoRow('Table:',
                          widget.participant.tableNumber ?? '(not assigned)'),
                      _buildInfoRow('Shirt:',
                          widget.participant.tshirtSize ?? '(not assigned)'),
                    ],
                  ),
                ),
              ),
              if (widget.participant.medicalInfo != null &&
                  widget.participant.medicalInfo!.isNotEmpty)
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
              if (widget.participant.note != null &&
                  widget.participant.note!.isNotEmpty)
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
                        backgroundColor: FSYScannerApp.accentGold,
                        foregroundColor: Colors.black,
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
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontSize: 16),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmCheckIn(BuildContext context) async {
    if (!mounted) return;

    final appState = Provider.of<AppState>(context, listen: false);
    final db = await DatabaseHelper.database;
    final dao = ParticipantsDao(db);
    final deviceId = await DeviceId.get();
    final now = DateTime.now().millisecondsSinceEpoch;

    await dao.markVerifiedLocally(
      widget.participant.id,
      deviceId,
      now,
    );

    await SyncQueueDao.enqueueTask(
      SyncQueueDao.typeMarkRegistered,
      {
        'participantId': widget.participant.id,
        'sheetsRow': widget.participant.sheetsRow,
        'verifiedAt': now,
        'registeredBy': deviceId,
      },
    );

    PrinterService.printReceipt(widget.participant, deviceId).then((success) {
      if (!success && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Print failed – check printer connection'),
            backgroundColor: Colors.orange,
          ),
        );
      }
    });

    appState.setLastScanResult('success');

    if (mounted) {
      Navigator.pop(context);
    }

    await Future<void>.delayed(Duration.zero);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Registration confirmed',
              style: TextStyle(color: Colors.white)),
          backgroundColor: FSYScannerApp.accentGreen,
        ),
      );
    }
  }
}
