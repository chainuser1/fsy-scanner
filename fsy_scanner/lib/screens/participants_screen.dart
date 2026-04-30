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
    if (!reset && (_isLoading || _isLoadingMore || !_hasMoreResults)) {
      return;
    }

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

      late final ParticipantQueryResult queryResult;
      if (query.isEmpty) {
        final pageFuture =
            dao.getParticipantsPage(limit: _pageSize, offset: offset);
        final totalCount = await totalParticipantsFuture;
        final participants = await pageFuture;
        queryResult = ParticipantQueryResult(
          participants: participants,
          totalCount: totalCount,
        );
      } else {
        queryResult = await dao.searchParticipants(
          query,
          limit: _pageSize,
          offset: offset,
        );
      }

      final totalParticipants = query.isEmpty
          ? queryResult.totalCount
          : await totalParticipantsFuture;
      final verifiedCount = await verifiedCountFuture;

      if (!mounted || requestId != _activeRequestId) {
        return;
      }

      setState(() {
        _totalParticipants = totalParticipants;
        _verifiedCount = verifiedCount;
        _totalMatches = queryResult.totalCount;
        _visibleParticipants = reset
            ? queryResult.participants
            : [..._visibleParticipants, ...queryResult.participants];
        _isLoading = false;
        _isLoadingMore = false;
      });
    } catch (e) {
      if (!mounted || requestId != _activeRequestId) {
        return;
      }
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
    if (mounted) {
      setState(() {});
    }
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
    if (!mounted || query != _searchController.text.trim()) {
      return;
    }
    await _loadParticipants(reset: true);
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
      await _loadParticipants(reset: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final summaryText = _hasActiveSearch
        ? 'Showing ${_visibleParticipants.length} of $_totalMatches matches'
        : 'Showing ${_visibleParticipants.length} of $_totalParticipants participants';
    final itemCount = 2 +
        (_isLoading
            ? 1
            : _visibleParticipants.isEmpty
                ? 1
                : _visibleParticipants.length + (_hasMoreResults ? 1 : 0));

    return Scaffold(
      appBar: AppBar(title: const Text('Participants')),
      body: RefreshIndicator(
        onRefresh: () => _loadParticipants(reset: true),
        child: ListView.builder(
          controller: _scrollController,
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.only(bottom: 24),
          itemCount: itemCount,
          itemBuilder: (context, index) {
            if (index == 0) {
              return Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                child: TextField(
                  controller: _searchController,
                  decoration: InputDecoration(
                    labelText: 'Search name, ward, stake, room, or table',
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

            if (index == 1) {
              return Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
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

            if (_isLoading) {
              return const Padding(
                padding: EdgeInsets.symmetric(vertical: 32),
                child: Center(child: CircularProgressIndicator()),
              );
            }

            if (_visibleParticipants.isEmpty) {
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 64),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.people_outline,
                        size: 64, color: Colors.grey[400]),
                    const SizedBox(height: 16),
                    Text(
                      'No participants found',
                      style: TextStyle(color: Colors.grey[600]),
                    ),
                  ],
                ),
              );
            }

            final participantIndex = index - 2;
            if (participantIndex >= _visibleParticipants.length) {
              return Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: OutlinedButton(
                  onPressed: _isLoadingMore
                      ? null
                      : () => _loadParticipants(reset: false),
                  child: _isLoadingMore
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(
                          'Load more (${_totalMatches - _visibleParticipants.length} remaining)'),
                ),
              );
            }

            final participant = _visibleParticipants[participantIndex];
            final isVerified = participant.verifiedAt != null;
            return Card(
              margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: ListTile(
                title: Text(participant.fullName),
                subtitle: Text(
                  _participantSummary(participant),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                leading: CircleAvatar(
                  backgroundColor: isVerified
                      ? FSYScannerApp.accentGreen.withValues(alpha: 0.3)
                      : FSYScannerApp.primaryBlue.withValues(alpha: 0.12),
                  child: Icon(
                    isVerified ? Icons.check_circle : Icons.person,
                    color: isVerified
                        ? FSYScannerApp.accentGreen
                        : FSYScannerApp.primaryBlue,
                  ),
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (isVerified)
                      IconButton(
                        icon: const Icon(Icons.print,
                            color: FSYScannerApp.accentGold),
                        tooltip: 'Reprint receipt',
                        onPressed: () async {
                          final deviceId = await DeviceId.get();
                          final result = await PrinterService.printReceipt(
                            participant,
                            deviceId,
                            isReprint: true,
                          );
                          if (!mounted) {
                            return;
                          }
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                result.success
                                    ? 'Receipt printed for ${participant.fullName}'
                                    : result.message,
                              ),
                              backgroundColor: result.success
                                  ? Colors.green
                                  : result.queuedForRetry
                                      ? Colors.orange
                                      : Colors.red,
                            ),
                          );
                        },
                      ),
                    Icon(
                      isVerified ? Icons.check_circle : Icons.circle_outlined,
                      color: isVerified
                          ? FSYScannerApp.accentGreen
                          : Colors.grey[400],
                    ),
                  ],
                ),
                onTap: () async {
                  await _openParticipantDetails(participant);
                },
              ),
            );
          },
        ),
      ),
    );
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _scrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  String _participantSummary(Participant participant) {
    final values = <String>[
      if ((participant.ward ?? '').trim().isNotEmpty) participant.ward!.trim(),
      if ((participant.stake ?? '').trim().isNotEmpty)
        participant.stake!.trim(),
      if ((participant.roomNumber ?? '').trim().isNotEmpty)
        'Room ${participant.roomNumber!.trim()}',
      if ((participant.tableNumber ?? '').trim().isNotEmpty)
        'Table ${participant.tableNumber!.trim()}',
    ];

    return values.isEmpty
        ? 'Tap to view full participant details'
        : values.join(' • ');
  }
}
