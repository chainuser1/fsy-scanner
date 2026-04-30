import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../app.dart';
import '../db/database_helper.dart';
import '../db/participants_dao.dart';
import '../models/participant.dart';
import '../print/printer_service.dart';
import '../utils/device_id.dart';
import 'confirm_screen.dart';

class ParticipantDetailsScreen extends StatefulWidget {
  final Participant participant;

  const ParticipantDetailsScreen({super.key, required this.participant});

  @override
  State<ParticipantDetailsScreen> createState() =>
      _ParticipantDetailsScreenState();
}

class _ParticipantDetailsScreenState extends State<ParticipantDetailsScreen> {
  late Participant _participant;
  bool _didChange = false;
  PrinterQueuedJob? _pendingConfirmationJob;

  @override
  void initState() {
    super.initState();
    _participant = widget.participant;
    unawaited(_refreshPendingConfirmationJob());
  }

  @override
  Widget build(BuildContext context) {
    final isVerified = _participant.isVerified;
    final isFullyVerified = _participant.isFullyVerified;
    final statusColor = switch (_participant.verificationStage) {
      ParticipantVerificationStage.pending => Colors.grey,
      ParticipantVerificationStage.partiallyVerified =>
        FSYScannerApp.accentGold,
      ParticipantVerificationStage.fullyVerified => FSYScannerApp.accentGreen,
    };

    return Scaffold(
      appBar: AppBar(
        title: const Text('Participant Details'),
        actions: [
          if (isVerified)
            IconButton(
              onPressed: _handleReprint,
              icon: const Icon(Icons.print),
              tooltip: 'Reprint receipt',
            ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _participant.fullName,
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          _statusChip(
                            label: _participant.verificationLabel,
                            color: statusColor.withValues(alpha: 0.18),
                            textColor: Colors.black87,
                          ),
                          _statusChip(
                            label: _participant.receiptStatusLabel,
                            color: isFullyVerified
                                ? FSYScannerApp.primaryBlue.withValues(
                                    alpha: 0.14,
                                  )
                                : Colors.orange.withValues(alpha: 0.18),
                            textColor: isFullyVerified
                                ? FSYScannerApp.primaryBlue
                                : Colors.deepOrange,
                          ),
                          if (_hasValue(_participant.ward))
                            _statusChip(
                              label: _participant.ward!,
                              color: FSYScannerApp.primaryBlue.withValues(
                                alpha: 0.12,
                              ),
                              textColor: FSYScannerApp.primaryBlue,
                            ),
                          if (_hasValue(_participant.stake))
                            _statusChip(
                              label: _participant.stake!,
                              color: FSYScannerApp.accentGold.withValues(
                                alpha: 0.18,
                              ),
                              textColor: Colors.black87,
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              _buildSection(
                context,
                title: 'Assignment',
                children: [
                  _infoTile('Ward', _participant.ward),
                  _infoTile('Stake', _participant.stake),
                  _infoTile('Room', _participant.roomNumber),
                  _infoTile('Table', _participant.tableNumber),
                ],
              ),
              const SizedBox(height: 12),
              _buildSection(
                context,
                title: 'Participant Info',
                children: [
                  _infoTile('Gender', _participant.gender),
                  _infoTile('Age', _participant.age?.toString()),
                  _infoTile('Birthday', _participant.birthday),
                  _infoTile('Shirt Size', _participant.tshirtSize),
                  _infoTile('Sheet Status', _participant.status),
                ],
              ),
              if (_hasValue(_participant.medicalInfo) ||
                  _hasValue(_participant.note)) ...[
                const SizedBox(height: 12),
                _buildSection(
                  context,
                  title: 'Notes',
                  children: [
                    _infoTile('Medical', _participant.medicalInfo),
                    _infoTile('Note', _participant.note),
                  ],
                ),
              ],
              const SizedBox(height: 12),
              _buildSection(
                context,
                title: 'Check-In',
                children: [
                  _infoTile(
                    'Verification State',
                    _participant.verificationLabel,
                  ),
                  _infoTile('Receipt State', _participant.receiptStatusLabel),
                  _infoTile(
                    'Verified At',
                    _formatTimestamp(_participant.verifiedAt),
                  ),
                  _infoTile(
                    'Printed At',
                    _formatTimestamp(_participant.printedAt),
                  ),
                  _infoTile('Registered By', _participant.registeredBy),
                  _infoTile('Sheets Row', _participant.sheetsRow.toString()),
                  if (_participant.isPartiallyVerified)
                    _infoTile(
                      'Action Needed',
                      _pendingConfirmationJob != null
                          ? 'Receipt output is waiting for operator confirmation below.'
                          : 'Receipt still needs a successful print. Retry from this screen or Settings.',
                    ),
                ],
              ),
              if (_pendingConfirmationJob != null) ...[
                const SizedBox(height: 12),
                _buildSection(
                  context,
                  title: 'Pending Print Confirmation',
                  children: [
                    _infoTile(
                      'Status',
                      'The latest print was sent, but paper output still needs explicit confirmation.',
                    ),
                    _infoTile(
                      'Last Attempt',
                      _formatTimestamp(
                        _pendingConfirmationJob!.lastAttemptAt ??
                            _pendingConfirmationJob!.queuedAt,
                      ),
                    ),
                    _infoTile('Print Type',
                        _pendingConfirmationJob!.isReprint ? 'Reprint' : 'Initial print'),
                    if (_pendingConfirmationJob!.reason.trim().isNotEmpty)
                      _infoTile('Note', _pendingConfirmationJob!.reason),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        FilledButton.icon(
                          onPressed: () => _resolvePendingConfirmation(true),
                          icon: const Icon(Icons.check_circle),
                          label: const Text('Confirm Printed'),
                        ),
                        OutlinedButton.icon(
                          onPressed: () => _resolvePendingConfirmation(false),
                          icon: const Icon(Icons.replay),
                          label: const Text('Queue Retry'),
                        ),
                      ],
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 24),
              if (!isVerified)
                ElevatedButton.icon(
                  onPressed: () async {
                    final changed = await Navigator.push<bool>(
                      context,
                      MaterialPageRoute(
                        builder: (context) =>
                            ConfirmScreen(participant: _participant),
                      ),
                    );
                    if (changed == true && context.mounted) {
                      Navigator.pop(context, true);
                    }
                  },
                  icon: const Icon(Icons.verified),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: FSYScannerApp.accentGold,
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  label: const Text('Proceed To Check-In'),
                )
              else
                OutlinedButton.icon(
                  onPressed: () => Navigator.pop(context, _didChange),
                  icon: Icon(
                    isFullyVerified
                        ? Icons.check_circle
                        : Icons.pending_actions,
                  ),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  label: Text(
                    isFullyVerified
                        ? 'Participant Fully Verified'
                        : 'Participant Partially Verified',
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _handleReprint() async {
    final deviceId = await DeviceId.get();
    var result = await PrinterService.printReceipt(
      _participant,
      deviceId,
      isReprint: true,
      requireOperatorConfirmation: true,
    );
    if (result.requiresOperatorConfirmation &&
        result.confirmationJobId != null &&
        mounted) {
      result = await _confirmPrintedOutput(result.confirmationJobId!);
    }
    if (!mounted) {
      return;
    }

    if (result.success) {
      await _reloadParticipant();
      _didChange = true;
    }

    if (!mounted) {
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          result.success
              ? 'Receipt printed for ${_participant.fullName}'
              : result.message,
        ),
        backgroundColor: result.success
            ? Colors.green
            : result.queuedForRetry
                ? Colors.orange
                : Colors.red,
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

  Future<void> _reloadParticipant() async {
    final db = await DatabaseHelper.database;
    final dao = ParticipantsDao(db);
    final refreshed = await dao.getParticipantById(_participant.id);
    if (!mounted || refreshed == null) {
      return;
    }
    setState(() {
      _participant = refreshed;
    });
    await _refreshPendingConfirmationJob();
  }

  Future<void> _refreshPendingConfirmationJob() async {
    final job = await PrinterService.getPendingConfirmationJobForParticipant(
      _participant.id,
    );
    if (!mounted) {
      return;
    }
    setState(() {
      _pendingConfirmationJob = job;
    });
  }

  Future<void> _resolvePendingConfirmation(bool printed) async {
    final job = _pendingConfirmationJob;
    if (job == null) {
      return;
    }
    final result = printed
        ? await PrinterService.confirmPrintDelivery(job.jobId)
        : await PrinterService.rejectPrintDelivery(job.jobId);
    if (result.success || result.queuedForRetry) {
      _didChange = true;
    }
    await _reloadParticipant();
    if (!mounted) {
      return;
    }
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

  Widget _buildSection(
    BuildContext context, {
    required String title,
    required List<Widget> children,
  }) {
    final visibleChildren =
        children.where((child) => child is! SizedBox).toList();
    if (visibleChildren.isEmpty) {
      return const SizedBox.shrink();
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            ...visibleChildren,
          ],
        ),
      ),
    );
  }

  Widget _infoTile(String label, String? value) {
    if (!_hasValue(value)) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: Colors.black54,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            value!.trim(),
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
          ),
        ],
      ),
    );
  }

  Widget _statusChip({
    required String label,
    required Color color,
    required Color textColor,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(fontWeight: FontWeight.w700, color: textColor),
      ),
    );
  }

  String? _formatTimestamp(int? value) {
    if (value == null) {
      return null;
    }

    final date = DateTime.fromMillisecondsSinceEpoch(value);
    return DateFormat('dd MMM yyyy, hh:mm a').format(date);
  }

  bool _hasValue(String? value) {
    if (value == null) {
      return false;
    }

    final trimmed = value.trim();
    return trimmed.isNotEmpty &&
        trimmed.toLowerCase() != 'none' &&
        trimmed.toLowerCase() != 'n/a' &&
        trimmed.toLowerCase() != 'null';
  }
}
