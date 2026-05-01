import 'dart:async';
import 'package:flutter/material.dart';

import '../app.dart';
import '../db/database_helper.dart';
import '../db/participants_dao.dart';
import '../models/participant.dart';
import '../print/printer_service.dart';
import '../utils/device_id.dart';
import 'participant_details_screen.dart';

class ParticipantsScreen extends StatefulWidget {
  const ParticipantsScreen({super.key});

  @override
  State<ParticipantsScreen> createState() => _ParticipantsScreenState();
}

class _ParticipantsScreenState extends State<ParticipantsScreen> {
  static const int _pageSize = 100;

  final TextEditingController _searchController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  Timer? _searchDebounce;
  List<Participant> _visibleParticipants = [];
  bool _isLoading = true;
  bool _isLoadingMore = false;
  int _totalParticipants = 0;
  int _verifiedCount = 0;
  int _totalMatches = 0;
  int _activeRequestId = 0;
  Set<String> _pendingConfirmationParticipantIds = <String>{};

  bool? _filterVerified;
  bool? _filterFullyVerified;
  bool? _filterMedical;
  bool? _filterPendingPrintConfirm;

  bool get _hasActiveFilters =>
      _filterVerified != null ||
      _filterFullyVerified != null ||
      _filterMedical != null ||
      _filterPendingPrintConfirm == true;

  bool get _hasActiveSearch => _searchController.text.trim().isNotEmpty;
  bool get _hasMoreResults => _visibleParticipants.length < _totalMatches;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onSearchChanged);
    _scrollController.addListener(_onScroll);
    _loadParticipants(reset: true);
  }

  Future<void> _loadParticipants({required bool reset}) async {
    if (!reset && (_isLoading || _isLoadingMore || !_hasMoreResults)) return;

    final requestId = ++_activeRequestId;
    final offset = reset ? 0 : _visibleParticipants.length;

    if (mounted) {
      setState(() {
        if (reset) {
          _isLoading = true;
        } else {
          _isLoadingMore = true;
        }
      });
    }

    try {
      final db = await DatabaseHelper.database;
      final dao = ParticipantsDao(db);
      final query = _searchController.text.trim();
      final totalParticipantsFuture = dao.getParticipantsCount();
      final verifiedCountFuture = ParticipantsDao.getRegisteredCount();
      final pendingConfirmationsFuture =
          PrinterService.getPendingConfirmationJobs();

      final pendingConfirmationJobs = await pendingConfirmationsFuture;
      final pendingIds =
          pendingConfirmationJobs.map((job) => job.participantId).toSet();

      late final ParticipantQueryResult queryResult;
      if (query.isEmpty && !_hasActiveFilters) {
        final pageFuture = dao.getParticipantsPage(
          limit: _pageSize,
          offset: offset,
        );
        final totalCount = await totalParticipantsFuture;
        final participants = await pageFuture;
        queryResult = ParticipantQueryResult(
          participants: participants,
          totalCount: totalCount,
        );
      } else {
        queryResult = await dao.searchParticipantsFiltered(
          query,
          limit: _pageSize,
          offset: offset,
          isVerified: _filterVerified,
          isFullyVerified: _filterFullyVerified,
          hasMedical: _filterMedical,
          hasPendingPrintConfirmation: _filterPendingPrintConfirm,
          pendingConfirmationParticipantIds: pendingIds,
        );
      }

      final totalParticipants = await totalParticipantsFuture;
      final verifiedCount = await verifiedCountFuture;

      if (!mounted || requestId != _activeRequestId) return;

      setState(() {
        _totalParticipants = totalParticipants;
        _verifiedCount = verifiedCount;
        _totalMatches = queryResult.totalCount;
        _visibleParticipants = reset
            ? queryResult.participants
            : [..._visibleParticipants, ...queryResult.participants];
        _pendingConfirmationParticipantIds = pendingIds;
        _isLoading = false;
        _isLoadingMore = false;
      });
    } catch (e) {
      if (!mounted || requestId != _activeRequestId) return;
      setState(() {
        _isLoading = false;
        _isLoadingMore = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error loading participants: $e')),
        );
      }
    }
  }

  void _onSearchChanged() {
    if (mounted) setState(() {});
    _searchDebounce?.cancel();
    _searchDebounce = Timer(
      const Duration(milliseconds: 180),
      () => _runSearch(_searchController.text),
    );
  }

  void _onScroll() {
    if (!_scrollController.hasClients || _isLoadingMore || !_hasMoreResults) {
      return;
    }
    final position = _scrollController.position;
    if (position.pixels >= position.maxScrollExtent - 300) {
      _loadParticipants(reset: false);
    }
  }

  Future<void> _runSearch(String rawQuery) async {
    final query = rawQuery.trim();
    if (!mounted || query != _searchController.text.trim()) return;
    await _loadParticipants(reset: true);
  }

  void _applyFilters({
    bool? verified,
    bool? fullyVerified,
    bool? medical,
    bool? pendingPrintConfirm,
  }) {
    setState(() {
      if (verified != null) {
        if (verified == true) {
          _filterVerified = true;
          _filterFullyVerified = null;
          _filterPendingPrintConfirm = null;
        } else {
          _filterVerified = false;
          _filterFullyVerified = null;
          _filterPendingPrintConfirm = null;
        }
      } else {
        _filterVerified = null;
      }

      if (fullyVerified != null) {
        if (_filterVerified != true) {
          _filterVerified = true;
        }
        _filterFullyVerified = fullyVerified;
      }

      if (medical != null) {
        _filterMedical = medical;
      }

      if (pendingPrintConfirm != null) {
        _filterPendingPrintConfirm = pendingPrintConfirm;
      }
    });
    _loadParticipants(reset: true);
  }

  @override
  Widget build(BuildContext context) {
    final summaryText = _hasActiveSearch || _hasActiveFilters
        ? 'Showing ${_visibleParticipants.length} of $_totalMatches matches'
        : 'Showing ${_visibleParticipants.length} of $_totalParticipants participants';

    return Scaffold(
      appBar: AppBar(title: const Text('Participants')),
      body: RefreshIndicator(
        onRefresh: () => _loadParticipants(reset: true),
        child: ListView.builder(
          controller: _scrollController,
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.only(bottom: 24),
          itemCount: _calculateItemCount(),
          itemBuilder: (context, index) {
            if (index == 0) return _buildSearchBar();
            if (index == 1) return _buildFilterChips();
            if (index == 2) return _buildSummaryRow(summaryText);
            if (_isLoading) return _buildLoader();
            if (_visibleParticipants.isEmpty) return _buildEmptyState();
            return _buildParticipantCard(index - 3);
          },
        ),
      ),
    );
  }

  int _calculateItemCount() {
    const int count = 3; // search, chips, summary
    if (_isLoading) return count + 1;
    if (_visibleParticipants.isEmpty) return count + 1;
    return count + _visibleParticipants.length + (_hasMoreResults ? 1 : 0);
  }

  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: TextField(
        controller: _searchController,
        decoration: InputDecoration(
          labelText: 'Search name, stake, ward, …',
          prefixIcon: const Icon(Icons.search),
          suffixIcon: _searchController.text.isEmpty
              ? null
              : IconButton(
                  onPressed: () {
                    _searchController.clear();
                    FocusScope.of(context).unfocus();
                  },
                  icon: const Icon(Icons.clear),
                  tooltip: 'Clear search',
                ),
          border: const OutlineInputBorder(),
        ),
      ),
    );
  }

  Widget _buildFilterChips() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Wrap(
        spacing: 8,
        runSpacing: 4,
        children: [
          FilterChip(
            label: const Text('All'),
            selected: !_hasActiveFilters,
            onSelected: (_) {
              setState(() {
                _filterVerified = null;
                _filterFullyVerified = null;
                _filterMedical = null;
                _filterPendingPrintConfirm = null;
              });
              _loadParticipants(reset: true);
            },
          ),
          FilterChip(
            label: const Text('Checked In'),
            selected: _filterVerified == true && _filterFullyVerified == null,
            onSelected: (_) => _applyFilters(verified: true),
          ),
          FilterChip(
            label: const Text('Pending'),
            selected: _filterVerified == false,
            onSelected: (_) => _applyFilters(verified: false),
          ),
          FilterChip(
            label: const Text('Fully Verified'),
            selected: _filterFullyVerified == true,
            onSelected: (_) => _applyFilters(fullyVerified: true),
          ),
          FilterChip(
            label: const Text('Partial (Printed?)'),
            selected: _filterFullyVerified == false,
            onSelected: (_) => _applyFilters(fullyVerified: false),
          ),
          FilterChip(
            label: const Text('Medical Flag'),
            selected: _filterMedical == true,
            onSelected: (_) => _applyFilters(medical: true),
          ),
          FilterChip(
            label: Text(
              'Print Confirm (${_pendingConfirmationParticipantIds.length})',
            ),
            selected: _filterPendingPrintConfirm == true,
            onSelected: (_) => _applyFilters(
              pendingPrintConfirm:
                  _filterPendingPrintConfirm == true ? null : true,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSummaryRow(String summaryText) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Row(
        children: [
          Text('Total: $_totalParticipants'),
          const SizedBox(width: 16),
          Text('Checked in: $_verifiedCount'),
          const Spacer(),
          Flexible(
            child: Text(
              summaryText,
              textAlign: TextAlign.end,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLoader() => const Padding(
        padding: EdgeInsets.symmetric(vertical: 32),
        child: Center(child: CircularProgressIndicator()),
      );

  Widget _buildEmptyState() => Padding(
        padding: const EdgeInsets.symmetric(vertical: 64),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.people_outline, size: 64, color: Colors.grey[400]),
            const SizedBox(height: 16),
            Text('No participants match the current filters.',
                style: TextStyle(color: Colors.grey[600])),
          ],
        ),
      );

  Widget _buildParticipantCard(int listIndex) {
    if (listIndex >= _visibleParticipants.length) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        child: OutlinedButton(
          onPressed:
              _isLoadingMore ? null : () => _loadParticipants(reset: false),
          child: _isLoadingMore
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(
                  'Load more (${_totalMatches - _visibleParticipants.length} remaining)',
                ),
        ),
      );
    }

    final participant = _visibleParticipants[listIndex];
    final visualStatus = _statusVisuals(participant);
    final hasPendingConfirmation =
        _pendingConfirmationParticipantIds.contains(participant.id);

    return Card(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: ListTile(
        title: Text(participant.fullName),
        subtitle: Text(
          _participantSummary(participant,
              hasPendingConfirmation: hasPendingConfirmation),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        leading: CircleAvatar(
          backgroundColor: visualStatus.color.withAlpha(45),
          child: Icon(visualStatus.icon, color: visualStatus.color),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (participant.isVerified)
              IconButton(
                icon: const Icon(Icons.print, color: FSYScannerApp.accentGold),
                tooltip: 'Reprint receipt',
                onPressed: () async {
                  final deviceId = await DeviceId.get();
                  var result = await PrinterService.printReceipt(
                    participant,
                    deviceId,
                    isReprint: true,
                  );
                  if (result.requiresOperatorConfirmation &&
                      result.confirmationJobId != null &&
                      mounted) {
                    result =
                        await _confirmPrintedOutput(result.confirmationJobId!);
                  }
                  if (!mounted) return;
                  if (result.success) {
                    await _loadParticipants(reset: true);
                    if (!mounted) return;
                  }
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(result.success
                          ? 'Receipt printed for ${participant.fullName}'
                          : result.message),
                      backgroundColor: result.success
                          ? Colors.green
                          : result.queuedForRetry
                              ? Colors.orange
                              : Colors.red,
                    ),
                  );
                },
              ),
            if (hasPendingConfirmation)
              const Padding(
                padding: EdgeInsets.only(right: 4),
                child: Icon(Icons.pending_actions,
                    color: Colors.deepOrange, size: 20),
              ),
            Icon(visualStatus.icon, color: visualStatus.color),
          ],
        ),
        onTap: () async => _openParticipantDetails(participant),
      ),
    );
  }

  Future<PrintReceiptResult> _confirmPrintedOutput(String jobId) async {
    final printed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Confirm Receipt Output'),
        content:
            const Text('Did the receipt actually come out of the printer?'),
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

  Future<void> _openParticipantDetails(Participant participant) async {
    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (context) =>
            ParticipantDetailsScreen(participant: participant),
      ),
    );
    if (changed == true) {
      _loadParticipants(reset: true);
    }
  }

  String _participantSummary(Participant p,
      {required bool hasPendingConfirmation}) {
    final parts = <String>[
      p.verificationLabel,
      if (hasPendingConfirmation) 'Awaiting print confirmation',
      if ((p.ward ?? '').isNotEmpty) p.ward!.trim(),
      if ((p.stake ?? '').isNotEmpty) p.stake!.trim(),
      if ((p.roomNumber ?? '').isNotEmpty) 'Room ${p.roomNumber!.trim()}',
      if ((p.tableNumber ?? '').isNotEmpty) 'Table ${p.tableNumber!.trim()}',
      if ((p.gender ?? '').isNotEmpty) p.gender!.trim(),
      if (p.age != null) 'Age ${p.age}',
      if ((p.medicalInfo ?? '').isNotEmpty) 'Medical*',
    ];
    return parts.isEmpty ? 'Tap to view details' : parts.join(' • ');
  }

  _ParticipantStatusVisual _statusVisuals(Participant p) {
    switch (p.verificationStage) {
      case ParticipantVerificationStage.pending:
        return _ParticipantStatusVisual(
            icon: Icons.circle_outlined, color: Colors.grey.shade500);
      case ParticipantVerificationStage.partiallyVerified:
        return const _ParticipantStatusVisual(
            icon: Icons.pending_actions, color: FSYScannerApp.accentGold);
      case ParticipantVerificationStage.fullyVerified:
        return const _ParticipantStatusVisual(
            icon: Icons.check_circle, color: FSYScannerApp.accentGreen);
    }
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _scrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }
}

class _ParticipantStatusVisual {
  final IconData icon;
  final Color color;
  const _ParticipantStatusVisual({required this.icon, required this.color});
}
