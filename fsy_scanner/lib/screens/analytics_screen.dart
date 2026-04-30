import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../app.dart';
import '../db/database_helper.dart';
import '../db/participants_dao.dart';
import '../models/participant.dart';
import '../print/printer_service.dart';
import '../providers/app_state.dart';
import '../services/analytics_export_service.dart';
import '../services/analytics_saved_views_service.dart';
import '../sync/sync_engine.dart';

enum _CommitteeView {
  all,
  registration,
  hotel,
  activity,
  food,
  leaders,
  operations,
}

class AnalyticsScreen extends StatefulWidget {
  const AnalyticsScreen({super.key});

  @override
  State<AnalyticsScreen> createState() => _AnalyticsScreenState();
}

class _AnalyticsScreenState extends State<AnalyticsScreen> {
  List<Participant> _participants = [];
  List<_SyncTaskEntry> _syncTasks = [];
  List<PrinterQueuedJob> _printJobs = [];
  List<PrinterJobAttempt> _printAttempts = [];
  List<AnalyticsSavedView> _savedViews = [];
  bool _loading = true;
  String? _error;
  int _requestId = 0;
  _CommitteeView _committeeView = _CommitteeView.all;
  int? _selectedSavedViewId;
  int? _recentScanMarker;
  int? _pendingTaskMarker;
  int? _failedPrintMarker;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final appState = Provider.of<AppState>(context);
    final latestRecentScan =
        appState.recentScans.isEmpty ? 0 : appState.recentScans.first.timestamp;
    final shouldReload = _recentScanMarker != null &&
        (_recentScanMarker != latestRecentScan ||
            _pendingTaskMarker != appState.pendingTaskCount ||
            _failedPrintMarker != appState.printerFailedJobCount);

    _recentScanMarker = latestRecentScan;
    _pendingTaskMarker = appState.pendingTaskCount;
    _failedPrintMarker = appState.printerFailedJobCount;

    if (shouldReload && !_loading) {
      unawaited(_load(showSpinner: false));
    }
  }

  Future<void> _load({bool showSpinner = true}) async {
    final requestId = ++_requestId;

    if (mounted && showSpinner) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }

    try {
      final db = await DatabaseHelper.database;
      final dao = ParticipantsDao(db);
      final participantsFuture = dao.getAllParticipants();
      final syncTasksFuture = db.rawQuery('''
        SELECT id, type, payload, status, attempts, last_error, created_at
        FROM sync_tasks
        WHERE status IN ('pending', 'in_progress')
        ORDER BY created_at DESC
      ''');
      final printJobsFuture = PrinterService.getRecentPrintJobs(limit: 500);
      final printAttemptsFuture = PrinterService.getRecentPrintAttempts(
        limit: 1000,
      );
      final savedViewsFuture = AnalyticsSavedViewsService.listViews();

      final participants = await participantsFuture;
      final taskRows = await syncTasksFuture;
      final printJobs = await printJobsFuture;
      final printAttempts = await printAttemptsFuture;
      final savedViews = await savedViewsFuture;

      participants.sort((a, b) {
        final verifiedCompare = (b.verifiedAt ?? 0).compareTo(
          a.verifiedAt ?? 0,
        );
        if (verifiedCompare != 0) {
          return verifiedCompare;
        }
        return a.fullName.compareTo(b.fullName);
      });

      if (!mounted || requestId != _requestId) {
        return;
      }

      setState(() {
        _participants = participants;
        _syncTasks = taskRows.map(_SyncTaskEntry.fromRow).toList();
        _printJobs = printJobs;
        _printAttempts = printAttempts;
        _savedViews = savedViews;
        final selectedView = _selectedSavedViewId == null
            ? null
            : _firstWhereOrNull(
                savedViews,
                (view) => view.id == _selectedSavedViewId,
              );
        final defaultView = _firstWhereOrNull(
          savedViews,
          (view) => view.isDefault,
        );
        final effectiveView = selectedView ?? defaultView;
        if (effectiveView != null) {
          _selectedSavedViewId = effectiveView.id;
          _committeeView = _committeeViewFromKey(effectiveView.committeeView);
        }
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted || requestId != _requestId) {
        return;
      }
      setState(() {
        _loading = false;
        _error = 'Unable to load analytics: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final analytics = _AnalyticsSnapshot.fromData(
      participants: _participants,
      syncTasks: _syncTasks,
      printJobs: _printJobs,
      printAttempts: _printAttempts,
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('Analytics'),
        actions: [
          IconButton(
            onPressed: _loading ? null : _refreshEventWideData,
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh event-wide analytics',
          ),
          PopupMenuButton<String>(
            onSelected: _handleAnalyticsAction,
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: 'save_view',
                child: Text('Save current view'),
              ),
              PopupMenuItem(
                value: 'export_summary',
                child: Text('Export briefing summary'),
              ),
              PopupMenuItem(
                value: 'print_summary',
                child: Text('Print briefing summary'),
              ),
            ],
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? _buildErrorState()
              : RefreshIndicator(
                  onRefresh: _refreshEventWideData,
                  child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.all(12),
                    children: _buildSectionList(appState, analytics),
                  ),
                ),
    );
  }

  Widget _buildErrorState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.analytics_outlined, size: 56),
            const SizedBox(height: 16),
            Text(
              _error ?? 'Unable to load analytics.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: _load,
              icon: const Icon(Icons.refresh),
              label: const Text('Try again'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(AppState appState, _AnalyticsSnapshot analytics) {
    final title = appState.eventName.trim().isEmpty
        ? 'Current event'
        : appState.eventName.trim();
    final subtitle = appState.organizationName.trim().isEmpty
        ? 'Current event analytics'
        : appState.organizationName.trim();

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
              ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            Text(
              subtitle,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: Colors.grey[700]),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _statusChip(
                  label: appState.isOnline ? 'Online' : 'Offline',
                  color: appState.isOnline
                      ? FSYScannerApp.accentGreen.withValues(alpha: 0.2)
                      : Colors.red.withValues(alpha: 0.16),
                  textColor: appState.isOnline
                      ? Colors.green.shade900
                      : Colors.red.shade900,
                ),
                _statusChip(
                  label: appState.printerConnected
                      ? 'Printer connected'
                      : 'Printer not ready',
                  color: appState.printerConnected
                      ? FSYScannerApp.primaryBlue.withValues(alpha: 0.15)
                      : FSYScannerApp.accentGold.withValues(alpha: 0.2),
                  textColor: appState.printerConnected
                      ? FSYScannerApp.primaryBlue
                      : Colors.black87,
                ),
                _statusChip(
                  label: analytics.pendingSyncTaskCount == 0
                      ? 'Sync queue clear'
                      : '${analytics.pendingSyncTaskCount} sync tasks pending',
                  color: analytics.pendingSyncTaskCount == 0
                      ? FSYScannerApp.accentGreen.withValues(alpha: 0.2)
                      : FSYScannerApp.accentGold.withValues(alpha: 0.2),
                  textColor: analytics.pendingSyncTaskCount == 0
                      ? Colors.green.shade900
                      : Colors.black87,
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              'Participant, assignment, and demographic analytics reflect the latest synced event roster across devices. Printer queue, print attempts, and sync backlog remain local to this device.',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: Colors.grey[700]),
            ),
            const SizedBox(height: 16),
            const Text(
              'Committee view',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _CommitteeView.values
                  .map(
                    (view) => ChoiceChip(
                      label: Text(_committeeLabel(view)),
                      selected: _committeeView == view,
                      onSelected: (_) {
                        setState(() {
                          _committeeView = view;
                        });
                      },
                    ),
                  )
                  .toList(),
            ),
            const SizedBox(height: 16),
            const Text(
              'Saved views',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            LayoutBuilder(
              builder: (context, constraints) {
                final dropdown = DropdownButtonFormField<int?>(
                  initialValue: _selectedSavedViewId,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    isDense: true,
                    hintText: 'Choose a saved view',
                  ),
                  items: [
                    const DropdownMenuItem<int?>(
                      child: Text('Current unsaved view'),
                    ),
                    ..._savedViews.map(
                      (view) => DropdownMenuItem<int?>(
                        value: view.id,
                        child: Text(
                          view.isDefault ? '${view.name} (Default)' : view.name,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                  ],
                  onChanged: (value) {
                    if (value == null) {
                      setState(() {
                        _selectedSavedViewId = null;
                      });
                      return;
                    }
                    _applySavedViewById(value);
                  },
                );
                final actions = Wrap(
                  spacing: 4,
                  children: [
                    IconButton(
                      onPressed: _saveCurrentView,
                      tooltip: 'Save current view',
                      icon: const Icon(Icons.bookmark_add_outlined),
                    ),
                    IconButton(
                      onPressed: _selectedSavedViewId == null
                          ? null
                          : _deleteSelectedView,
                      tooltip: 'Delete selected view',
                      icon: const Icon(Icons.delete_outline),
                    ),
                  ],
                );

                if (constraints.maxWidth < 520) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [dropdown, const SizedBox(height: 8), actions],
                  );
                }

                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: dropdown),
                    const SizedBox(width: 8),
                    actions,
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildSectionList(
    AppState appState,
    _AnalyticsSnapshot analytics,
  ) {
    final sections = <Widget>[
      _buildHeader(appState, analytics),
      const SizedBox(height: 12),
      _buildSectionHeader(
        'People and Attendance',
        'Prioritize who is on site, how far verification has progressed, and what attendees need next.',
      ),
      const SizedBox(height: 12),
      _buildLiveAttendanceCard(analytics),
      const SizedBox(height: 12),
      _buildProgressCard(analytics),
      const SizedBox(height: 12),
      _buildSummaryGrid(appState, analytics),
      const SizedBox(height: 12),
    ];

    switch (_committeeView) {
      case _CommitteeView.all:
        sections.addAll([
          _buildSectionHeader(
            'Assignments and Committees',
            'Track readiness by room, table, stake, ward, and committee-facing participant mix.',
          ),
          const SizedBox(height: 12),
          _buildAssignmentReadinessCard(analytics),
          const SizedBox(height: 12),
          _buildGroupProgressCard(analytics),
          const SizedBox(height: 12),
          _buildDemographicsCard(analytics),
          const SizedBox(height: 12),
          _buildTimelineCard(analytics),
          const SizedBox(height: 12),
          _buildTrendCard(analytics),
          const SizedBox(height: 12),
          _buildSectionHeader(
            'Technical and Audit',
            'Use these operational details to resolve printer, sync, and audit issues after reviewing people data.',
          ),
          const SizedBox(height: 12),
          _buildDataScopeCard(appState),
          const SizedBox(height: 12),
          _buildOperationsCommandCard(appState, analytics),
          const SizedBox(height: 12),
          _buildAuditTrailCard(appState, analytics),
          const SizedBox(height: 12),
          _buildExceptionsCard(appState, analytics),
        ]);
        break;
      case _CommitteeView.registration:
        sections.addAll([
          _buildSectionHeader(
            'Assignments and Movement',
            'See which attendees and groups are ready to move on after registration and receipt confirmation.',
          ),
          const SizedBox(height: 12),
          _buildAssignmentReadinessCard(analytics),
          const SizedBox(height: 12),
          _buildGroupProgressCard(analytics),
          const SizedBox(height: 12),
          _buildTimelineCard(analytics),
          const SizedBox(height: 12),
          _buildSectionHeader(
            'Technical and Audit',
            'Use technical metrics only after confirming participant progress and readiness.',
          ),
          const SizedBox(height: 12),
          _buildDataScopeCard(appState),
          const SizedBox(height: 12),
          _buildAuditTrailCard(appState, analytics),
          const SizedBox(height: 12),
          _buildExceptionsCard(appState, analytics),
        ]);
        break;
      case _CommitteeView.hotel:
        sections.addAll([
          _buildSectionHeader(
            'Assignments and Movement',
            'Focus on room readiness, table readiness, and who is already on site.',
          ),
          const SizedBox(height: 12),
          _buildAssignmentReadinessCard(analytics),
          const SizedBox(height: 12),
          _buildGroupProgressCard(analytics),
          const SizedBox(height: 12),
          _buildTimelineCard(analytics),
          const SizedBox(height: 12),
          _buildSectionHeader(
            'Technical and Audit',
            'Technical metrics stay below the people-facing readiness information.',
          ),
          const SizedBox(height: 12),
          _buildDataScopeCard(appState),
          const SizedBox(height: 12),
          _buildExceptionsCard(appState, analytics),
        ]);
        break;
      case _CommitteeView.activity:
        sections.addAll([
          _buildSectionHeader(
            'Assignments and Participation Mix',
            'Focus on tables, attendance mix, and activity-facing readiness.',
          ),
          const SizedBox(height: 12),
          _buildAssignmentReadinessCard(analytics),
          const SizedBox(height: 12),
          _buildDemographicsCard(analytics),
          const SizedBox(height: 12),
          _buildTimelineCard(analytics),
          const SizedBox(height: 12),
          _buildTrendCard(analytics),
          const SizedBox(height: 12),
          _buildSectionHeader(
            'Technical and Audit',
            'Technical detail remains available, but below the participant-focused view.',
          ),
          const SizedBox(height: 12),
          _buildDataScopeCard(appState),
        ]);
        break;
      case _CommitteeView.food:
        sections.addAll([
          _buildSectionHeader(
            'Attendance Mix and Coverage',
            'Focus on who is actually on site and the participant characteristics that affect planning.',
          ),
          const SizedBox(height: 12),
          _buildDemographicsCard(analytics),
          const SizedBox(height: 12),
          _buildGroupProgressCard(analytics),
          const SizedBox(height: 12),
          _buildTimelineCard(analytics),
          const SizedBox(height: 12),
          _buildSectionHeader(
            'Technical and Audit',
            'Technical information stays below the attendee and demographic view.',
          ),
          const SizedBox(height: 12),
          _buildDataScopeCard(appState),
        ]);
        break;
      case _CommitteeView.leaders:
        sections.addAll([
          _buildSectionHeader(
            'Assignments and Demographics',
            'Leadership sees participant movement, group readiness, and attendee mix before device-local technical metrics.',
          ),
          const SizedBox(height: 12),
          _buildAssignmentReadinessCard(analytics),
          const SizedBox(height: 12),
          _buildDemographicsCard(analytics),
          const SizedBox(height: 12),
          _buildTimelineCard(analytics),
          const SizedBox(height: 12),
          _buildSectionHeader(
            'Technical and Audit',
            'Use this section for operational blockers, queue health, and device-local print reliability.',
          ),
          const SizedBox(height: 12),
          _buildDataScopeCard(appState),
          const SizedBox(height: 12),
          _buildOperationsCommandCard(appState, analytics),
          const SizedBox(height: 12),
          _buildExceptionsCard(appState, analytics),
        ]);
        break;
      case _CommitteeView.operations:
        sections.addAll([
          _buildSectionHeader(
            'Assignments and Event Flow',
            'Operations still starts with participant movement and readiness before drilling into printer and sync diagnostics.',
          ),
          const SizedBox(height: 12),
          _buildAssignmentReadinessCard(analytics),
          const SizedBox(height: 12),
          _buildTimelineCard(analytics),
          const SizedBox(height: 12),
          _buildSectionHeader(
            'Technical and Audit',
            'Device-local health, printer truth, and sync backlog live here.',
          ),
          const SizedBox(height: 12),
          _buildDataScopeCard(appState),
          const SizedBox(height: 12),
          _buildOperationsCommandCard(appState, analytics),
          const SizedBox(height: 12),
          _buildAuditTrailCard(appState, analytics),
          const SizedBox(height: 12),
          _buildExceptionsCard(appState, analytics),
        ]);
        break;
    }

    return sections;
  }

  Widget _buildSectionHeader(String title, String subtitle) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 4),
          Text(subtitle, style: TextStyle(color: Colors.grey[700])),
        ],
      ),
    );
  }

  String _committeeLabel(_CommitteeView view) {
    switch (view) {
      case _CommitteeView.all:
        return 'All';
      case _CommitteeView.registration:
        return 'Registration';
      case _CommitteeView.hotel:
        return 'Hotel';
      case _CommitteeView.activity:
        return 'Activity';
      case _CommitteeView.food:
        return 'Food';
      case _CommitteeView.leaders:
        return 'Leaders';
      case _CommitteeView.operations:
        return 'Operations';
    }
  }

  String _committeeViewKey(_CommitteeView view) {
    return view.name;
  }

  _CommitteeView _committeeViewFromKey(String key) {
    return _CommitteeView.values.firstWhere(
      (view) => view.name == key,
      orElse: () => _CommitteeView.all,
    );
  }

  T? _firstWhereOrNull<T>(Iterable<T> values, bool Function(T value) test) {
    for (final value in values) {
      if (test(value)) {
        return value;
      }
    }
    return null;
  }

  _AnalyticsSnapshot _currentAnalyticsSnapshot() {
    return _AnalyticsSnapshot.fromData(
      participants: _participants,
      syncTasks: _syncTasks,
      printJobs: _printJobs,
      printAttempts: _printAttempts,
    );
  }

  Future<void> _handleAnalyticsAction(String action) async {
    switch (action) {
      case 'save_view':
        await _saveCurrentView();
        break;
      case 'export_summary':
        await _exportBriefingSummary();
        break;
      case 'print_summary':
        await _printBriefingSummary();
        break;
    }
  }

  Future<void> _refreshEventWideData() async {
    final appState = context.read<AppState>();
    final success = await SyncEngine.performFullSync(appState);
    await _load(showSpinner: false);
    if (!mounted) {
      return;
    }
    _showMessage(
      success
          ? 'Event-wide roster refreshed from the latest synced sheet data.'
          : 'Used the latest local data. Full event-wide refresh did not complete.',
    );
  }

  Future<void> _applySavedViewById(int id) async {
    final view = _firstWhereOrNull(_savedViews, (entry) => entry.id == id);
    if (view == null) {
      return;
    }
    setState(() {
      _selectedSavedViewId = view.id;
      _committeeView = _committeeViewFromKey(view.committeeView);
    });
  }

  Future<void> _saveCurrentView() async {
    final existing = _selectedSavedViewId == null
        ? null
        : _firstWhereOrNull(
            _savedViews,
            (view) => view.id == _selectedSavedViewId,
          );
    final controller = TextEditingController(
      text: existing?.name ?? '${_committeeLabel(_committeeView)} View',
    );
    var markDefault = existing?.isDefault ?? _savedViews.isEmpty;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setStateDialog) => AlertDialog(
          title: Text(existing == null ? 'Save view' : 'Update view'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: controller,
                decoration: const InputDecoration(
                  labelText: 'View name',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              SwitchListTile(
                value: markDefault,
                contentPadding: EdgeInsets.zero,
                title: const Text('Set as default view'),
                onChanged: (value) {
                  setStateDialog(() {
                    markDefault = value;
                  });
                },
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );

    if (confirmed != true) {
      return;
    }

    final name = controller.text.trim();
    if (name.isEmpty) {
      _showMessage('Enter a name before saving the view.');
      return;
    }

    final saved = await AnalyticsSavedViewsService.saveView(
      id: existing?.id,
      name: name,
      committeeView: _committeeViewKey(_committeeView),
      isDefault: markDefault,
    );
    await _load(showSpinner: false);
    if (!mounted) {
      return;
    }
    setState(() {
      _selectedSavedViewId = saved.id;
    });
    _showMessage('Saved view "$name".');
  }

  Future<void> _deleteSelectedView() async {
    final selected = _selectedSavedViewId == null
        ? null
        : _firstWhereOrNull(
            _savedViews,
            (view) => view.id == _selectedSavedViewId,
          );
    if (selected == null) {
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete saved view?'),
        content: Text('Remove "${selected.name}" from saved analytics views?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true) {
      return;
    }

    await AnalyticsSavedViewsService.deleteView(selected.id);
    setState(() {
      _selectedSavedViewId = null;
    });
    await _load(showSpinner: false);
    if (!mounted) {
      return;
    }
    _showMessage('Deleted saved view "${selected.name}".');
  }

  Future<void> _exportBriefingSummary() async {
    final appState = context.read<AppState>();
    final analytics = _currentAnalyticsSnapshot();
    final result = await AnalyticsExportService.exportTextReport(
      baseName:
          '${appState.eventName.isEmpty ? 'event' : appState.eventName}_${_committeeViewKey(_committeeView)}_briefing',
      content: _buildBriefingText(appState, analytics),
    );
    if (!mounted) {
      return;
    }
    _showMessage(
      'Briefing summary exported to ${result.filePath} (${result.byteCount} bytes).',
    );
  }

  Future<void> _printBriefingSummary() async {
    final appState = context.read<AppState>();
    final analytics = _currentAnalyticsSnapshot();
    var result = await PrinterService.printSummaryReport(
      title: _buildBriefingTitle(appState),
      bodyLines: _buildBriefingLines(appState, analytics),
      requireOperatorConfirmation: true,
    );
    if (result.requiresOperatorConfirmation && mounted) {
      result = await _confirmSummaryPrintedOutput();
    }
    if (!mounted) {
      return;
    }
    _showMessage(result.message);
  }

  Future<PrintReceiptResult> _confirmSummaryPrintedOutput() async {
    final printed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Confirm Summary Output'),
        content: const Text(
          'Did the summary actually come out of the printer?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('No'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Yes, Printed'),
          ),
        ],
      ),
    );

    if (printed == true) {
      return PrinterService.confirmSummaryPrintDelivery();
    }
    return PrinterService.rejectSummaryPrintDelivery();
  }

  String _buildBriefingTitle(AppState appState) {
    final eventTitle = appState.eventName.trim().isEmpty
        ? 'FSY Event'
        : appState.eventName.trim();
    return '$eventTitle ${_committeeLabel(_committeeView)} Briefing';
  }

  String _buildBriefingText(AppState appState, _AnalyticsSnapshot analytics) {
    final lines = _buildBriefingLines(appState, analytics);
    return lines.join('\n');
  }

  List<String> _buildBriefingLines(
    AppState appState,
    _AnalyticsSnapshot analytics,
  ) {
    final lines = <String>[
      _buildBriefingTitle(appState),
      if (appState.organizationName.trim().isNotEmpty)
        appState.organizationName.trim(),
      'Generated: ${DateFormat('dd MMM yyyy h:mm a').format(DateTime.now())}',
      'View: ${_committeeLabel(_committeeView)}',
      'Event-wide participant data comes from the latest synced roster.',
      'Printer queue and sync backlog are local to this device.',
      '',
      'Registration/Verification Operations',
      'Attending now: ${analytics.checkedInCount}/${analytics.totalParticipants}',
      'Fully verified: ${analytics.fullyVerifiedCount}',
      'Partially verified: ${analytics.partiallyVerifiedCount}',
      'Pending: ${analytics.pendingCount}',
      '',
      'Current Attendance',
      'Active tables: ${analytics.activeTableCount}',
      'Ready tables: ${analytics.completedTableCount}',
      'Active rooms: ${analytics.activeRoomCount}',
      'Ready rooms: ${analytics.completedRoomCount}',
      'Medical flags: ${analytics.checkedInMedicalFlagCount} checked in',
      '',
    ];

    switch (_committeeView) {
      case _CommitteeView.registration:
        _appendBreakdownSection(
          lines,
          'Stakes by attendees on site',
          analytics.stakeAttendingRows,
        );
        _appendBreakdownSection(
          lines,
          'Wards by attendees on site',
          analytics.wardAttendingRows,
        );
        lines.addAll([
          '',
          'Local device operations',
          'Queued print jobs: ${analytics.staleQueuedPrintCount} stale of ${_printJobs.where((job) => job.status == 'queued').length}',
          'Pending sync tasks: ${analytics.pendingSyncTaskCount}',
        ]);
        break;
      case _CommitteeView.hotel:
        _appendBreakdownSection(
          lines,
          'Rooms with attendees on site',
          analytics.roomRows,
        );
        _appendBreakdownSection(
          lines,
          'Rooms fully assembled',
          analytics.readyRoomRows,
        );
        lines.addAll([
          '',
          'Unresolved assignments',
          'Missing room assignments among checked in: ${analytics.missingRoomAmongCheckedInCount}',
          'Missing table assignments among checked in: ${analytics.missingTableAmongCheckedInCount}',
        ]);
        break;
      case _CommitteeView.activity:
        _appendBreakdownSection(
          lines,
          'Tables with attendees',
          analytics.tableRows,
        );
        _appendBreakdownSection(
          lines,
          'Tables fully assembled',
          analytics.readyTableRows,
        );
        _appendBreakdownSection(lines, 'Age bands', analytics.ageRows);
        break;
      case _CommitteeView.food:
        _appendBreakdownSection(lines, 'Shirt sizes', analytics.shirtSizeRows);
        _appendBreakdownSection(
          lines,
          'Medical classifications',
          analytics.medicalCategoryRows,
        );
        _appendBreakdownSection(lines, 'Stakes', analytics.stakeAttendingRows);
        break;
      case _CommitteeView.leaders:
        _appendBreakdownSection(lines, 'Stakes', analytics.stakeAttendingRows);
        _appendBreakdownSection(lines, 'Wards', analytics.wardAttendingRows);
        _appendAttemptSummary(lines, analytics);
        break;
      case _CommitteeView.operations:
        _appendAttemptSummary(lines, analytics);
        lines.addAll([
          '',
          'Queue health',
          'Oldest queued print age: ${analytics.oldestQueuedPrintAgeMinutes.toStringAsFixed(1)} min',
          'Pending sync tasks: ${analytics.pendingSyncTaskCount}',
          'Retrying sync tasks: ${analytics.retryingSyncTaskCount}',
        ]);
        break;
      case _CommitteeView.all:
        _appendBreakdownSection(
          lines,
          'Top stakes',
          analytics.stakeAttendingRows,
        );
        _appendBreakdownSection(
          lines,
          'Top wards',
          analytics.wardAttendingRows,
        );
        _appendBreakdownSection(
          lines,
          'Tables with attendees',
          analytics.tableRows,
        );
        _appendBreakdownSection(
          lines,
          'Rooms with attendees',
          analytics.roomRows,
        );
        _appendAttemptSummary(lines, analytics);
        break;
    }

    return lines;
  }

  void _appendBreakdownSection(
    List<String> lines,
    String title,
    List<_BreakdownRow> rows,
  ) {
    lines.add(title);
    if (rows.isEmpty) {
      lines.add('- No data available');
      lines.add('');
      return;
    }
    for (final row in rows.take(6)) {
      lines.add(
        '- ${row.label}: ${row.checkedIn}/${row.total} on site, ${row.printed} fully verified',
      );
    }
    lines.add('');
  }

  void _appendAttemptSummary(List<String> lines, _AnalyticsSnapshot analytics) {
    lines.addAll([
      'Local printer and sync operations',
      'Print attempts: ${analytics.totalPrintAttemptCount}',
      'Print success rate: ${analytics.printSuccessRate.toStringAsFixed(1)}%',
      'Retry success rate: ${analytics.retrySuccessRate.toStringAsFixed(1)}%',
      'Last-hour print failures: ${analytics.printFailuresLastHour}',
      'Average attempt time: ${analytics.averagePrintAttemptSeconds.toStringAsFixed(1)} sec',
      '',
    ]);
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Widget _buildSummaryGrid(AppState appState, _AnalyticsSnapshot analytics) {
    final cards = [
      _MetricCardData(
        label: 'Attending now',
        value: '${analytics.checkedInCount}',
        helper:
            '${analytics.liveAttendanceRate.toStringAsFixed(1)}% of roster checked in',
        icon: Icons.groups_2,
        color: FSYScannerApp.primaryBlue,
      ),
      _MetricCardData(
        label: 'Fully verified',
        value: '${analytics.fullyVerifiedCount}',
        helper:
            '${analytics.fullVerificationRate.toStringAsFixed(1)}% fully verified',
        icon: Icons.how_to_reg,
        color: FSYScannerApp.accentGreen,
      ),
      _MetricCardData(
        label: 'Partial',
        value: '${analytics.partiallyVerifiedCount}',
        helper: analytics.partiallyVerifiedCount == 0
            ? 'No receipt backlog'
            : 'Verified but awaiting print success',
        icon: Icons.pending_actions,
        color: FSYScannerApp.accentGold,
      ),
      _MetricCardData(
        label: 'Pending',
        value: '${analytics.pendingCount}',
        helper: analytics.pendingCount == 0
            ? 'Everyone has started verification'
            : 'Still waiting to arrive',
        icon: Icons.hourglass_bottom,
        color: Colors.grey.shade700,
      ),
      _MetricCardData(
        label: 'Print queue',
        value: '${appState.printerFailedJobCount}',
        helper:
            '${analytics.staleQueuedPrintCount} stale • ${appState.printerActiveJobCount} active',
        icon: Icons.local_printshop_outlined,
        color: FSYScannerApp.primaryBlue,
      ),
      _MetricCardData(
        label: 'Sync queue',
        value: '${analytics.pendingSyncTaskCount}',
        helper: analytics.pendingSyncTaskCount == 0
            ? 'No sync backlog'
            : '${analytics.retryingSyncTaskCount} retries in queue',
        icon: Icons.sync,
        color: analytics.pendingSyncTaskCount == 0
            ? FSYScannerApp.accentGreen
            : FSYScannerApp.accentGold,
      ),
      _MetricCardData(
        label: 'Recent hour',
        value: '${analytics.recentHourCount}',
        helper: '${analytics.recent15MinuteCount} in the last 15 min',
        icon: Icons.timeline,
        color: FSYScannerApp.primaryBlue,
      ),
      _MetricCardData(
        label: 'Exceptions',
        value: '${analytics.exceptionCount}',
        helper:
            '${analytics.partiallyVerifiedCount} partially verified participants',
        icon: Icons.warning_amber_rounded,
        color: analytics.exceptionCount == 0
            ? FSYScannerApp.primaryBlue
            : Colors.redAccent,
      ),
      _MetricCardData(
        label: 'Active tables',
        value: '${analytics.activeTableCount}',
        helper: '${analytics.completedTableCount} tables fully assembled',
        icon: Icons.table_restaurant,
        color: FSYScannerApp.primaryBlue,
      ),
      _MetricCardData(
        label: 'Active rooms',
        value: '${analytics.activeRoomCount}',
        helper: '${analytics.completedRoomCount} rooms ready',
        icon: Icons.meeting_room,
        color: FSYScannerApp.accentGreen,
      ),
      _MetricCardData(
        label: 'Medical flags',
        value: '${analytics.medicalFlagCount}',
        helper:
            '${analytics.checkedInMedicalFlagCount} checked in • ${analytics.noteCount} notes',
        icon: Icons.medical_information,
        color: analytics.medicalFlagCount == 0
            ? FSYScannerApp.primaryBlue
            : Colors.redAccent,
      ),
    ];

    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: cards
          .map((card) => SizedBox(width: 170, child: _buildMetricCard(card)))
          .toList(),
    );
  }

  Widget _buildDataScopeCard(AppState appState) {
    final syncedLabel = appState.lastSyncedAt == null
        ? 'No successful sync recorded yet'
        : 'Last successful sync: ${DateFormat('dd MMM h:mm a').format(appState.lastSyncedAt!)}';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Data Scope',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Text(syncedLabel, style: TextStyle(color: Colors.grey[700])),
            const SizedBox(height: 12),
            const Text(
              'Event-wide: attendance, verification, demographics, stake, ward, room, and table analytics use the synced event roster across devices.',
            ),
            const SizedBox(height: 8),
            const Text(
              'This device only: printer queues, print attempts, and sync backlog reflect the current scanner and its selected printer.',
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMetricCard(_MetricCardData data) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(data.icon, color: data.color),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    data.label,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              data.value,
              style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 6),
            Text(
              data.helper,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: Colors.grey[700]),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildProgressCard(_AnalyticsSnapshot analytics) {
    final completed = analytics.checkedInCount.toDouble();
    final remaining = analytics.pendingCount.toDouble();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Registration/Verification Operations',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 16),
            LayoutBuilder(
              builder: (context, constraints) {
                final summary = Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${analytics.checkedInCount} live attendees',
                      style: const TextStyle(
                        fontSize: 30,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${analytics.liveAttendanceRate.toStringAsFixed(1)}% of the roster is now on site',
                      style: TextStyle(color: Colors.grey[700]),
                    ),
                    const SizedBox(height: 20),
                    _buildProgressRow(
                      label: 'Checked in / attending',
                      value: analytics.completionRate / 100,
                      color: FSYScannerApp.accentGreen,
                      trailing:
                          '${analytics.checkedInCount}/${analytics.totalParticipants}',
                    ),
                    const SizedBox(height: 12),
                    _buildProgressRow(
                      label: 'Fully verified',
                      value: analytics.fullVerificationRate / 100,
                      color: FSYScannerApp.primaryBlue,
                      trailing:
                          '${analytics.fullyVerifiedCount}/${analytics.totalParticipants}',
                    ),
                    const SizedBox(height: 12),
                    _buildProgressRow(
                      label: 'Receipt completion after check-in',
                      value: analytics.printCoverageRate / 100,
                      color: FSYScannerApp.accentGold,
                      trailing:
                          '${analytics.printedCount}/${analytics.checkedInCount}',
                    ),
                  ],
                );
                final chart = SizedBox(
                  height: 120,
                  child: PieChart(
                    PieChartData(
                      sectionsSpace: 2,
                      centerSpaceRadius: 34,
                      sections: [
                        PieChartSectionData(
                          value: completed <= 0 ? 0.001 : completed,
                          color: FSYScannerApp.accentGreen,
                          title: '',
                          radius: 18,
                        ),
                        PieChartSectionData(
                          value: remaining <= 0 ? 0.001 : remaining,
                          color: Colors.grey.shade300,
                          title: '',
                          radius: 18,
                        ),
                      ],
                    ),
                  ),
                );

                if (constraints.maxWidth < 720) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      summary,
                      const SizedBox(height: 16),
                      Center(child: SizedBox(width: 180, child: chart)),
                    ],
                  );
                }

                return Row(
                  children: [
                    Expanded(flex: 3, child: summary),
                    const SizedBox(width: 12),
                    Expanded(flex: 2, child: chart),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLiveAttendanceCard(_AnalyticsSnapshot analytics) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Current Attendance',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            Text(
              'This section prioritizes participants actually on site right now.',
              style: TextStyle(color: Colors.grey[700]),
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                _buildReliabilityStat(
                  'On site',
                  '${analytics.checkedInCount}',
                  '${analytics.liveAttendanceRate.toStringAsFixed(1)}% of roster',
                  FSYScannerApp.primaryBlue,
                ),
                _buildReliabilityStat(
                  'Partial',
                  '${analytics.partiallyVerifiedCount}',
                  '${analytics.partiallyVerifiedRate.toStringAsFixed(1)}% of attendees',
                  FSYScannerApp.accentGold,
                ),
                _buildReliabilityStat(
                  'Ready tables',
                  '${analytics.completedTableCount}',
                  '${analytics.activeTableCount} with attendees',
                  FSYScannerApp.accentGreen,
                ),
                _buildReliabilityStat(
                  'Ready rooms',
                  '${analytics.completedRoomCount}',
                  '${analytics.activeRoomCount} with attendees',
                  FSYScannerApp.accentGreen,
                ),
              ],
            ),
            const SizedBox(height: 18),
            const Text(
              'Top stakes by attendees on site',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            ...analytics.stakeAttendingRows.take(5).map(_buildLiveBreakdownRow),
            const SizedBox(height: 18),
            const Text(
              'Top wards by attendees on site',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            ...analytics.wardAttendingRows.take(5).map(_buildLiveBreakdownRow),
          ],
        ),
      ),
    );
  }

  Widget _buildProgressRow({
    required String label,
    required double value,
    required Color color,
    required String trailing,
  }) {
    final safeValue = value.clamp(0.0, 1.0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                trailing,
                textAlign: TextAlign.right,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(999),
          child: LinearProgressIndicator(
            value: safeValue,
            minHeight: 12,
            valueColor: AlwaysStoppedAnimation<Color>(color),
            backgroundColor: Colors.grey.shade200,
          ),
        ),
      ],
    );
  }

  Widget _buildOperationsCommandCard(
    AppState appState,
    _AnalyticsSnapshot analytics,
  ) {
    return Column(
      children: [
        _buildOpsHealthCard(appState, analytics),
        const SizedBox(height: 12),
        _buildPrinterReliabilityCard(analytics),
      ],
    );
  }

  Widget _buildOpsHealthCard(AppState appState, _AnalyticsSnapshot analytics) {
    final oldestTaskLabel = analytics.oldestPendingTask == null
        ? 'No queued sync tasks'
        : 'Oldest queue item ${_formatRelativeTime(analytics.oldestPendingTask!)}';

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Operations Health',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 14),
            _buildHealthRow(
              icon: appState.isOnline ? Icons.cloud_done : Icons.cloud_off,
              label: 'Connectivity',
              value: appState.isOnline ? 'Online' : 'Offline',
              detail: appState.syncError ?? 'Sync engine ready',
              color: appState.isOnline
                  ? FSYScannerApp.accentGreen
                  : Colors.redAccent,
            ),
            _buildHealthRow(
              icon: appState.printerConnected
                  ? Icons.print
                  : Icons.print_disabled,
              label: 'Printer',
              value: appState.printerStateLabel,
              detail:
                  '${appState.printerStatusMessage} • ${appState.printerFailedJobCount} queued • ${appState.printerActiveJobCount} active',
              color: appState.printerConnected
                  ? FSYScannerApp.primaryBlue
                  : appState.printerFailedJobCount > 0
                      ? Colors.redAccent
                      : FSYScannerApp.accentGold,
            ),
            _buildHealthRow(
              icon: Icons.sync,
              label: 'Sync backlog',
              value: '${analytics.pendingSyncTaskCount} queued',
              detail:
                  '$oldestTaskLabel • ${analytics.retryingSyncTaskCount} retrying',
              color: analytics.pendingSyncTaskCount == 0
                  ? FSYScannerApp.accentGreen
                  : FSYScannerApp.accentGold,
            ),
            _buildHealthRow(
              icon: Icons.speed,
              label: 'Throughput',
              value: '${analytics.recentHourCount} in the last hour',
              detail:
                  '${analytics.recent15MinuteCount} in 15 min • peak ${analytics.peakHourCount} per hour',
              color: FSYScannerApp.primaryBlue,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHealthRow({
    required IconData icon,
    required String label,
    required String value,
    required String detail,
    required Color color,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: color),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: Colors.black54,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  value,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(detail, style: TextStyle(color: Colors.grey[700])),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAssignmentReadinessCard(_AnalyticsSnapshot analytics) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Assignment Readiness',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            Text(
              'Useful for registration, hotel, logistics, and activity committees.',
              style: TextStyle(color: Colors.grey[700]),
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                _buildReliabilityStat(
                  'Missing rooms',
                  '${analytics.missingRoomAmongCheckedInCount}',
                  'Checked-in attendees still unassigned',
                  analytics.missingRoomAmongCheckedInCount == 0
                      ? FSYScannerApp.accentGreen
                      : Colors.redAccent,
                ),
                _buildReliabilityStat(
                  'Missing tables',
                  '${analytics.missingTableAmongCheckedInCount}',
                  'Checked-in attendees still unassigned',
                  analytics.missingTableAmongCheckedInCount == 0
                      ? FSYScannerApp.accentGreen
                      : Colors.redAccent,
                ),
                _buildReliabilityStat(
                  'Avg verify to print',
                  analytics.averageVerifyToPrintMinutes == 0
                      ? '-'
                      : '${analytics.averageVerifyToPrintMinutes.toStringAsFixed(1)}m',
                  'Average delay from check-in to print success',
                  FSYScannerApp.primaryBlue,
                ),
                _buildReliabilityStat(
                  'Oldest print queue',
                  analytics.oldestQueuedPrintAgeMinutes == 0
                      ? '0m'
                      : '${analytics.oldestQueuedPrintAgeMinutes.toStringAsFixed(1)}m',
                  '${analytics.staleQueuedPrintCount} jobs waiting over 15 min',
                  analytics.staleQueuedPrintCount == 0
                      ? FSYScannerApp.accentGreen
                      : Colors.redAccent,
                ),
              ],
            ),
            const SizedBox(height: 18),
            const Text(
              'Tables with most attendees on site',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            if (analytics.tableRows.isEmpty)
              Text(
                'No table assignments found.',
                style: TextStyle(color: Colors.grey[700]),
              )
            else
              ...analytics.tableRows.take(6).map(_buildLiveBreakdownRow),
            const SizedBox(height: 18),
            const Text(
              'Tables fully assembled',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            if (analytics.readyTableRows.isEmpty)
              Text(
                'No tables are fully assembled yet.',
                style: TextStyle(color: Colors.grey[700]),
              )
            else
              ...analytics.readyTableRows.take(6).map(_buildReadyBreakdownRow),
            const SizedBox(height: 18),
            const Text(
              'Rooms with most attendees on site',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            if (analytics.roomRows.isEmpty)
              Text(
                'No room assignments found.',
                style: TextStyle(color: Colors.grey[700]),
              )
            else
              ...analytics.roomRows.take(6).map(_buildLiveBreakdownRow),
            const SizedBox(height: 18),
            const Text(
              'Rooms fully assembled',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            if (analytics.readyRoomRows.isEmpty)
              Text(
                'No rooms are fully assembled yet.',
                style: TextStyle(color: Colors.grey[700]),
              )
            else
              ...analytics.readyRoomRows.take(6).map(_buildReadyBreakdownRow),
          ],
        ),
      ),
    );
  }

  Widget _buildExceptionsCard(AppState appState, _AnalyticsSnapshot analytics) {
    final items = [
      _ExceptionData(
        label: 'Partial verification',
        value: analytics.partiallyVerifiedCount,
        color: analytics.partiallyVerifiedCount == 0
            ? FSYScannerApp.accentGreen
            : Colors.redAccent,
      ),
      _ExceptionData(
        label: 'Missing room assignment',
        value: analytics.missingRoomCount,
        color: analytics.missingRoomCount == 0
            ? FSYScannerApp.primaryBlue
            : Colors.redAccent,
      ),
      _ExceptionData(
        label: 'Missing table assignment',
        value: analytics.missingTableCount,
        color: analytics.missingTableCount == 0
            ? FSYScannerApp.primaryBlue
            : Colors.redAccent,
      ),
      _ExceptionData(
        label: 'Retrying sync tasks',
        value: analytics.retryingSyncTaskCount,
        color: analytics.retryingSyncTaskCount == 0
            ? FSYScannerApp.accentGreen
            : FSYScannerApp.accentGold,
      ),
      _ExceptionData(
        label: 'Printer failed jobs',
        value: appState.printerFailedJobCount,
        color: appState.printerFailedJobCount == 0
            ? FSYScannerApp.accentGreen
            : Colors.redAccent,
      ),
      _ExceptionData(
        label: 'Medical flags',
        value: analytics.medicalFlagCount,
        color: analytics.medicalFlagCount == 0
            ? FSYScannerApp.primaryBlue
            : Colors.redAccent,
      ),
    ];

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Exceptions And Risks',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: items
                  .map(
                    (item) => Container(
                      width: 170,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: item.color.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${item.value}',
                            style: TextStyle(
                              fontSize: 26,
                              fontWeight: FontWeight.w800,
                              color: item.color,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            item.label,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ],
                      ),
                    ),
                  )
                  .toList(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGroupProgressCard(_AnalyticsSnapshot analytics) {
    return Column(
      children: [
        _buildStakeCard(analytics),
        const SizedBox(height: 12),
        _buildOperationalMixCard(analytics),
      ],
    );
  }

  Widget _buildPrinterReliabilityCard(_AnalyticsSnapshot analytics) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Printer Reliability',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            Text(
              'Immutable attempt history from the print ledger',
              style: TextStyle(color: Colors.grey[700]),
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                _buildReliabilityStat(
                  'Attempts',
                  '${analytics.totalPrintAttemptCount}',
                  '${analytics.printSuccessRate.toStringAsFixed(1)}% success',
                  FSYScannerApp.primaryBlue,
                ),
                _buildReliabilityStat(
                  'Failures',
                  '${analytics.failedPrintAttemptCount}',
                  '${analytics.cancelledPrintAttemptCount} cancelled',
                  analytics.failedPrintAttemptCount == 0
                      ? FSYScannerApp.accentGreen
                      : Colors.redAccent,
                ),
                _buildReliabilityStat(
                  'Retries',
                  '${analytics.retryAttemptCount}',
                  '${analytics.retrySuccessRate.toStringAsFixed(1)}% retry success',
                  FSYScannerApp.accentGold,
                ),
                _buildReliabilityStat(
                  'Attempt time',
                  analytics.averagePrintAttemptSeconds == 0
                      ? '-'
                      : '${analytics.averagePrintAttemptSeconds.toStringAsFixed(1)}s',
                  '${analytics.printAttemptsLastHour} attempts in the last hour',
                  FSYScannerApp.primaryBlue,
                ),
                _buildReliabilityStat(
                  'Last hour failures',
                  '${analytics.printFailuresLastHour}',
                  '${analytics.printSuccessesLastHour} successes in the last hour',
                  analytics.printFailuresLastHour == 0
                      ? FSYScannerApp.accentGreen
                      : Colors.redAccent,
                ),
                _buildReliabilityStat(
                  'Printers seen',
                  '${analytics.uniquePrinterCount}',
                  analytics.averageAttemptsPerSuccessfulJob == 0
                      ? 'No successful jobs yet'
                      : '${analytics.averageAttemptsPerSuccessfulJob.toStringAsFixed(2)} avg attempts per success',
                  FSYScannerApp.accentGreen,
                ),
              ],
            ),
            const SizedBox(height: 18),
            const Text(
              'Top failure codes',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            if (analytics.failureCodeRows.isEmpty)
              Text(
                'No failed attempts recorded in the ledger.',
                style: TextStyle(color: Colors.grey[700]),
              )
            else
              ...analytics.failureCodeRows.map(_buildAttemptBreakdownRow),
            const SizedBox(height: 18),
            const Text(
              'Printer reliability by device',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            if (analytics.printerRows.isEmpty)
              Text(
                'No printer addresses recorded yet.',
                style: TextStyle(color: Colors.grey[700]),
              )
            else
              ...analytics.printerRows.map(_buildAttemptBreakdownRow),
          ],
        ),
      ),
    );
  }

  Widget _buildTimelineCard(_AnalyticsSnapshot analytics) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Event Timeline',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            Text(
              'Day-by-day activity from recorded check-in and print timestamps.',
              style: TextStyle(color: Colors.grey[700]),
            ),
            const SizedBox(height: 14),
            if (analytics.dailyActivityRows.isEmpty)
              Text(
                'No dated activity has been recorded yet.',
                style: TextStyle(color: Colors.grey[700]),
              )
            else
              ...analytics.dailyActivityRows.map(_buildDailyActivityRow),
          ],
        ),
      ),
    );
  }

  Widget _buildTrendCard(_AnalyticsSnapshot analytics) {
    if (analytics.activityBuckets.isEmpty) {
      return const SizedBox.shrink();
    }

    final maxCount = analytics.activityBuckets.fold<int>(
      0,
      (current, bucket) => math.max(current, bucket.count),
    );

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Check-In Trend',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            Text(
              'Hourly check-ins over the last 8 hours',
              style: TextStyle(color: Colors.grey[700]),
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: 220,
              child: BarChart(
                BarChartData(
                  maxY: math.max(4, maxCount).toDouble() * 1.25,
                  gridData: FlGridData(
                    drawVerticalLine: false,
                    horizontalInterval: math
                        .max(1, (math.max(4, maxCount) / 4).ceil())
                        .toDouble(),
                  ),
                  borderData: FlBorderData(show: false),
                  titlesData: FlTitlesData(
                    topTitles: const AxisTitles(),
                    rightTitles: const AxisTitles(),
                    leftTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 28,
                        interval: math
                            .max(1, (math.max(4, maxCount) / 4).ceil())
                            .toDouble(),
                      ),
                    ),
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 28,
                        getTitlesWidget: (value, meta) {
                          final index = value.toInt();
                          if (index < 0 ||
                              index >= analytics.activityBuckets.length) {
                            return const SizedBox.shrink();
                          }
                          return Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text(
                              DateFormat('ha')
                                  .format(
                                    analytics.activityBuckets[index].start,
                                  )
                                  .toLowerCase(),
                              style: const TextStyle(fontSize: 11),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                  barGroups: List.generate(
                    analytics.activityBuckets.length,
                    (index) => BarChartGroupData(
                      x: index,
                      barRods: [
                        BarChartRodData(
                          toY:
                              analytics.activityBuckets[index].count.toDouble(),
                          color: FSYScannerApp.accentGold,
                          width: 18,
                          borderRadius: const BorderRadius.vertical(
                            top: Radius.circular(4),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStakeCard(_AnalyticsSnapshot analytics) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Stake Completion',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            Text(
              'Top stakes by participant count and completion',
              style: TextStyle(color: Colors.grey[700]),
            ),
            const SizedBox(height: 14),
            ...analytics.topStakeRows.map(_buildBreakdownRow),
          ],
        ),
      ),
    );
  }

  Widget _buildOperationalMixCard(_AnalyticsSnapshot analytics) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Operational Mix',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 14),
            const Text(
              'Stakes with the largest partial verification backlog',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 10),
            ...analytics.topStakePartialRows.map(_buildPendingBreakdownRow),
            const SizedBox(height: 18),
            const Text(
              'Wards with the biggest pending backlog',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 10),
            ...analytics.topWardPendingRows.map(_buildPendingBreakdownRow),
            const SizedBox(height: 18),
            const Text(
              'Rooms with the highest occupancy',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 10),
            ...analytics.topRoomRows.map(_buildLiveBreakdownRow),
          ],
        ),
      ),
    );
  }

  Widget _buildDemographicsCard(_AnalyticsSnapshot analytics) {
    final genderSections = analytics.genderRows.isEmpty
        ? <PieChartSectionData>[
            PieChartSectionData(
              value: 1,
              color: Colors.grey.shade300,
              title: '',
              radius: 22,
            ),
          ]
        : analytics.genderRows.asMap().entries.map((entry) {
            final colors = [
              FSYScannerApp.primaryBlue,
              FSYScannerApp.accentGold,
              FSYScannerApp.accentGreen,
              Colors.purple,
            ];
            return PieChartSectionData(
              value: math.max(0.001, entry.value.checkedIn.toDouble()),
              color: colors[entry.key % colors.length],
              title: '',
              radius: 22,
            );
          }).toList();

    final maxAgeValue = analytics.ageRows.fold<int>(
      0,
      (current, row) => math.max(current, row.checkedIn),
    );

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Attendance Mix',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 16),
            LayoutBuilder(
              builder: (context, constraints) {
                final genderCard = Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Gender',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      height: 180,
                      child: PieChart(
                        PieChartData(
                          sectionsSpace: 2,
                          centerSpaceRadius: 32,
                          sections: genderSections,
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    ...analytics.genderRows.map(
                      (row) => Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                row.label,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text('${row.checkedIn}/${row.total}'),
                          ],
                        ),
                      ),
                    ),
                  ],
                );
                final ageCard = Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Age bands',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      height: 220,
                      child: BarChart(
                        BarChartData(
                          maxY: math.max(4, maxAgeValue).toDouble() * 1.25,
                          gridData: FlGridData(
                            drawVerticalLine: false,
                            horizontalInterval: math
                                .max(1, (math.max(4, maxAgeValue) / 4).ceil())
                                .toDouble(),
                          ),
                          borderData: FlBorderData(show: false),
                          titlesData: FlTitlesData(
                            topTitles: const AxisTitles(),
                            rightTitles: const AxisTitles(),
                            leftTitles: AxisTitles(
                              sideTitles: SideTitles(
                                showTitles: true,
                                reservedSize: 28,
                                interval: math
                                    .max(
                                      1,
                                      (math.max(4, maxAgeValue) / 4).ceil(),
                                    )
                                    .toDouble(),
                              ),
                            ),
                            bottomTitles: AxisTitles(
                              sideTitles: SideTitles(
                                showTitles: true,
                                reservedSize: 28,
                                getTitlesWidget: (value, meta) {
                                  final index = value.toInt();
                                  if (index < 0 ||
                                      index >= analytics.ageRows.length) {
                                    return const SizedBox.shrink();
                                  }
                                  return Padding(
                                    padding: const EdgeInsets.only(top: 8),
                                    child: Text(
                                      analytics.ageRows[index].label,
                                      style: const TextStyle(fontSize: 11),
                                    ),
                                  );
                                },
                              ),
                            ),
                          ),
                          barGroups: List.generate(
                            analytics.ageRows.length,
                            (index) => BarChartGroupData(
                              x: index,
                              barRods: [
                                BarChartRodData(
                                  toY: analytics.ageRows[index].checkedIn
                                      .toDouble(),
                                  color: FSYScannerApp.primaryBlue,
                                  width: 22,
                                  borderRadius: const BorderRadius.vertical(
                                    top: Radius.circular(4),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                );

                if (constraints.maxWidth < 720) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [genderCard, const SizedBox(height: 20), ageCard],
                  );
                }

                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: genderCard),
                    const SizedBox(width: 12),
                    Expanded(child: ageCard),
                  ],
                );
              },
            ),
            const SizedBox(height: 18),
            const Text(
              'Shirt sizes',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            ...analytics.shirtSizeRows.take(6).map(_buildLiveBreakdownRow),
            const SizedBox(height: 18),
            const Text(
              'Medical classifications',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            if (analytics.medicalCategoryRows.isEmpty)
              Text(
                'No medical information classified in local data.',
                style: TextStyle(color: Colors.grey[700]),
              )
            else
              ...analytics.medicalCategoryRows.map(_buildLiveBreakdownRow),
            const SizedBox(height: 18),
            const Text(
              'Gender verification progress',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            ...analytics.genderRows.take(6).map(_buildLiveBreakdownRow),
          ],
        ),
      ),
    );
  }

  Widget _buildAuditTrailCard(AppState appState, _AnalyticsSnapshot analytics) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Audit Trail',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            Text(
              'Recent check-ins and current sync activity',
              style: TextStyle(color: Colors.grey[700]),
            ),
            const SizedBox(height: 16),
            const Text(
              'Recent check-ins',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            if (analytics.recentCheckIns.isEmpty)
              Text(
                'No recent check-ins recorded in local data.',
                style: TextStyle(color: Colors.grey[700]),
              )
            else
              ...analytics.recentCheckIns.map(_buildRecentCheckInTile),
            const SizedBox(height: 18),
            const Text(
              'Sync queue by action',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            if (analytics.pendingSyncTaskCount == 0)
              Text(
                'The sync queue is currently clear.',
                style: TextStyle(color: Colors.grey[700]),
              )
            else ...[
              ...analytics.syncTypeRows.map(
                (row) => Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    children: [
                      Expanded(child: Text(row.label)),
                      Text(
                        '${row.total}',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                '${appState.recentScans.length} recent scans kept in memory for undo support',
                style: TextStyle(color: Colors.grey[700]),
              ),
            ],
            const SizedBox(height: 18),
            const Text(
              'Recent print jobs',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            if (analytics.recentPrintJobs.isEmpty)
              Text(
                'No print job history recorded yet.',
                style: TextStyle(color: Colors.grey[700]),
              )
            else
              ...analytics.recentPrintJobs.map(_buildRecentPrintJobTile),
            const SizedBox(height: 18),
            const Text(
              'Recent print attempts',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            if (analytics.recentPrintAttempts.isEmpty)
              Text(
                'No immutable print attempts recorded yet.',
                style: TextStyle(color: Colors.grey[700]),
              )
            else
              ...analytics.recentPrintAttempts.map(
                _buildRecentPrintAttemptTile,
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildBreakdownRow(_BreakdownRow row) {
    final progress = row.total == 0 ? 0.0 : row.checkedIn / row.total;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  row.label,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              Text('${row.checkedIn}/${row.total}'),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 10,
              valueColor: AlwaysStoppedAnimation<Color>(
                progress >= 1
                    ? FSYScannerApp.accentGreen
                    : FSYScannerApp.accentGold,
              ),
              backgroundColor: Colors.grey.shade200,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '${row.pending} pending',
            style: TextStyle(color: Colors.grey[700], fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _buildLiveBreakdownRow(_BreakdownRow row) {
    final attendanceShare = row.total == 0 ? 0.0 : row.checkedIn / row.total;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  row.label,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  '${row.checkedIn}/${row.total} on site',
                  textAlign: TextAlign.right,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: attendanceShare,
              minHeight: 10,
              valueColor: const AlwaysStoppedAnimation<Color>(
                FSYScannerApp.primaryBlue,
              ),
              backgroundColor: Colors.grey.shade200,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '${row.printed} fully verified • ${row.partial} awaiting print',
            style: TextStyle(color: Colors.grey[700], fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _buildReadyBreakdownRow(_BreakdownRow row) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          Expanded(
            child: Text(
              row.label,
              style: const TextStyle(fontWeight: FontWeight.w600),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              '${row.checkedIn}/${row.total} ready',
              textAlign: TextAlign.right,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontWeight: FontWeight.w700,
                color: FSYScannerApp.accentGreen,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPendingBreakdownRow(_BreakdownRow row) {
    final progress = row.total == 0 ? 0.0 : row.pending / row.total;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  row.label,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  '${row.pending} pending',
                  textAlign: TextAlign.right,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 10,
              valueColor: const AlwaysStoppedAnimation<Color>(
                FSYScannerApp.accentGold,
              ),
              backgroundColor: Colors.grey.shade200,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '${row.checkedIn}/${row.total} checked in',
            style: TextStyle(color: Colors.grey[700], fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _buildRecentCheckInTile(Participant participant) {
    final verifiedAt = participant.verifiedAt;
    final subtitleParts = <String>[
      if (_hasValue(participant.stake)) participant.stake!.trim(),
      if (_hasValue(participant.ward)) participant.ward!.trim(),
      if (_hasValue(participant.roomNumber))
        'Room ${participant.roomNumber!.trim()}',
      if (_hasValue(participant.tableNumber))
        'Table ${participant.tableNumber!.trim()}',
      participant.verificationLabel,
    ];

    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      leading: CircleAvatar(
        radius: 18,
        backgroundColor: FSYScannerApp.accentGreen.withValues(alpha: 0.14),
        child: const Icon(Icons.check, color: FSYScannerApp.accentGreen),
      ),
      title: Text(participant.fullName),
      subtitle: Text(
        subtitleParts.isEmpty ? 'Checked in' : subtitleParts.join(' • '),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Text(
        verifiedAt == null
            ? '-'
            : DateFormat(
                'h:mm a',
              ).format(DateTime.fromMillisecondsSinceEpoch(verifiedAt)),
      ),
      minVerticalPadding: 8,
    );
  }

  Widget _buildRecentPrintJobTile(PrinterQueuedJob job) {
    final color = switch (job.status) {
      'success' => FSYScannerApp.accentGreen,
      'cancelled' => Colors.redAccent,
      _ => FSYScannerApp.accentGold,
    };
    final icon = switch (job.status) {
      'success' => Icons.check_circle,
      'cancelled' => Icons.cancel,
      _ => Icons.schedule,
    };
    final when = job.printedAt ?? job.lastAttemptAt ?? job.queuedAt;

    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      leading: CircleAvatar(
        radius: 18,
        backgroundColor: color.withValues(alpha: 0.14),
        child: Icon(icon, color: color),
      ),
      title: Text(job.participantName),
      subtitle: Text(
        '${job.isReprint ? 'Reprint' : 'Initial print'} • ${job.status} • attempts ${job.attemptCount}',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Text(
        DateFormat('h:mm a').format(DateTime.fromMillisecondsSinceEpoch(when)),
      ),
      minVerticalPadding: 8,
    );
  }

  Widget _buildRecentPrintAttemptTile(PrinterJobAttempt attempt) {
    final color = switch (attempt.outcome) {
      'success' => FSYScannerApp.accentGreen,
      'cancelled' => Colors.redAccent,
      _ => FSYScannerApp.accentGold,
    };
    final icon = switch (attempt.outcome) {
      'success' => Icons.check_circle,
      'cancelled' => Icons.cancel,
      _ => Icons.error_outline,
    };
    final subtitleParts = <String>[
      if (attempt.isReprint) 'Reprint' else 'Initial print',
      'Attempt ${attempt.attemptNumber}',
      if ((attempt.printerAddress ?? '').trim().isNotEmpty)
        attempt.printerAddress!,
      if ((attempt.failureCode ?? '').trim().isNotEmpty) attempt.failureCode!,
    ];

    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      leading: CircleAvatar(
        radius: 18,
        backgroundColor: color.withValues(alpha: 0.14),
        child: Icon(icon, color: color),
      ),
      title: Text(
        attempt.participantName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        subtitleParts.join(' • '),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Text(
        DateFormat(
          'h:mm a',
        ).format(DateTime.fromMillisecondsSinceEpoch(attempt.finishedAt)),
      ),
      minVerticalPadding: 8,
    );
  }

  Widget _buildReliabilityStat(
    String label,
    String value,
    String helper,
    Color color,
  ) {
    return Container(
      width: 170,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w800,
              color: color,
            ),
          ),
          const SizedBox(height: 4),
          Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text(helper, style: TextStyle(color: Colors.grey[700])),
        ],
      ),
    );
  }

  Widget _buildAttemptBreakdownRow(_AttemptBreakdownRow row) {
    final failureShare = row.total == 0 ? 0.0 : row.failures / row.total;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  row.label,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              Text('${row.failures}/${row.total} failures'),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: failureShare,
              minHeight: 10,
              valueColor: const AlwaysStoppedAnimation<Color>(Colors.redAccent),
              backgroundColor: Colors.grey.shade200,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '${row.successes} success • ${row.cancelled} cancelled',
            style: TextStyle(color: Colors.grey[700], fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _buildDailyActivityRow(_DailyActivityRow row) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(row.label, style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Wrap(
            spacing: 12,
            runSpacing: 6,
            children: [
              Text('Checked in: ${row.checkedIn}'),
              Text('Fully verified: ${row.fullyVerified}'),
              Text('Print attempts: ${row.printAttempts}'),
              Text('Print failures: ${row.printFailures}'),
            ],
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
        style: TextStyle(color: textColor, fontWeight: FontWeight.w700),
      ),
    );
  }

  String _formatRelativeTime(int timestamp) {
    final difference = DateTime.now().difference(
      DateTime.fromMillisecondsSinceEpoch(timestamp),
    );
    if (difference.inMinutes < 1) {
      return 'was just queued';
    }
    if (difference.inHours < 1) {
      return '${difference.inMinutes} min ago';
    }
    if (difference.inDays < 1) {
      return '${difference.inHours} hr ago';
    }
    return '${difference.inDays} day ago';
  }

  bool _hasValue(String? value) {
    if (value == null) {
      return false;
    }
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      return false;
    }
    final lower = trimmed.toLowerCase();
    return lower != 'none' && lower != 'n/a' && lower != 'null';
  }
}

class _AnalyticsSnapshot {
  final int totalParticipants;
  final int checkedInCount;
  final int pendingCount;
  final int partiallyVerifiedCount;
  final int fullyVerifiedCount;
  final int printedCount;
  final int checkedInNotPrintedCount;
  final int medicalFlagCount;
  final int checkedInMedicalFlagCount;
  final int noteCount;
  final int missingRoomCount;
  final int missingTableCount;
  final int missingRoomAmongCheckedInCount;
  final int missingTableAmongCheckedInCount;
  final int recent15MinuteCount;
  final int recentHourCount;
  final int peakHourCount;
  final int pendingSyncTaskCount;
  final int retryingSyncTaskCount;
  final int exceptionCount;
  final int? oldestPendingTask;
  final double completionRate;
  final double fullVerificationRate;
  final double printCoverageRate;
  final List<_BreakdownRow> topStakeRows;
  final List<_BreakdownRow> stakeAttendingRows;
  final List<_BreakdownRow> topStakePartialRows;
  final List<_BreakdownRow> wardAttendingRows;
  final List<_BreakdownRow> topWardPendingRows;
  final List<_BreakdownRow> topRoomRows;
  final List<_BreakdownRow> tableRows;
  final List<_BreakdownRow> roomRows;
  final List<_BreakdownRow> readyTableRows;
  final List<_BreakdownRow> readyRoomRows;
  final List<_BreakdownRow> genderRows;
  final List<_BreakdownRow> ageRows;
  final List<_BreakdownRow> shirtSizeRows;
  final List<_BreakdownRow> medicalCategoryRows;
  final List<_BreakdownRow> syncTypeRows;
  final List<_ActivityBucket> activityBuckets;
  final List<_DailyActivityRow> dailyActivityRows;
  final List<Participant> recentCheckIns;
  final List<PrinterQueuedJob> recentPrintJobs;
  final List<PrinterJobAttempt> recentPrintAttempts;
  final int totalPrintAttemptCount;
  final int successfulPrintAttemptCount;
  final int failedPrintAttemptCount;
  final int cancelledPrintAttemptCount;
  final int retryAttemptCount;
  final int retrySuccessCount;
  final int reprintAttemptCount;
  final int uniquePrinterCount;
  final int activeTableCount;
  final int completedTableCount;
  final int activeRoomCount;
  final int completedRoomCount;
  final int staleQueuedPrintCount;
  final double averageAttemptsPerSuccessfulJob;
  final double averageVerifyToPrintMinutes;
  final double oldestQueuedPrintAgeMinutes;
  final double averagePrintAttemptSeconds;
  final int printAttemptsLastHour;
  final int printFailuresLastHour;
  final int printSuccessesLastHour;
  final List<_AttemptBreakdownRow> failureCodeRows;
  final List<_AttemptBreakdownRow> printerRows;

  const _AnalyticsSnapshot({
    required this.totalParticipants,
    required this.checkedInCount,
    required this.pendingCount,
    required this.partiallyVerifiedCount,
    required this.fullyVerifiedCount,
    required this.printedCount,
    required this.checkedInNotPrintedCount,
    required this.medicalFlagCount,
    required this.checkedInMedicalFlagCount,
    required this.noteCount,
    required this.missingRoomCount,
    required this.missingTableCount,
    required this.missingRoomAmongCheckedInCount,
    required this.missingTableAmongCheckedInCount,
    required this.recent15MinuteCount,
    required this.recentHourCount,
    required this.peakHourCount,
    required this.pendingSyncTaskCount,
    required this.retryingSyncTaskCount,
    required this.exceptionCount,
    required this.oldestPendingTask,
    required this.completionRate,
    required this.fullVerificationRate,
    required this.printCoverageRate,
    required this.topStakeRows,
    required this.stakeAttendingRows,
    required this.topStakePartialRows,
    required this.wardAttendingRows,
    required this.topWardPendingRows,
    required this.topRoomRows,
    required this.tableRows,
    required this.roomRows,
    required this.readyTableRows,
    required this.readyRoomRows,
    required this.genderRows,
    required this.ageRows,
    required this.shirtSizeRows,
    required this.medicalCategoryRows,
    required this.syncTypeRows,
    required this.activityBuckets,
    required this.dailyActivityRows,
    required this.recentCheckIns,
    required this.recentPrintJobs,
    required this.recentPrintAttempts,
    required this.totalPrintAttemptCount,
    required this.successfulPrintAttemptCount,
    required this.failedPrintAttemptCount,
    required this.cancelledPrintAttemptCount,
    required this.retryAttemptCount,
    required this.retrySuccessCount,
    required this.reprintAttemptCount,
    required this.uniquePrinterCount,
    required this.activeTableCount,
    required this.completedTableCount,
    required this.activeRoomCount,
    required this.completedRoomCount,
    required this.staleQueuedPrintCount,
    required this.averageAttemptsPerSuccessfulJob,
    required this.averageVerifyToPrintMinutes,
    required this.oldestQueuedPrintAgeMinutes,
    required this.averagePrintAttemptSeconds,
    required this.printAttemptsLastHour,
    required this.printFailuresLastHour,
    required this.printSuccessesLastHour,
    required this.failureCodeRows,
    required this.printerRows,
  });

  factory _AnalyticsSnapshot.fromData({
    required List<Participant> participants,
    required List<_SyncTaskEntry> syncTasks,
    required List<PrinterQueuedJob> printJobs,
    required List<PrinterJobAttempt> printAttempts,
  }) {
    final checkedIn = participants.where((p) => p.verifiedAt != null).toList();
    final partiallyVerified =
        checkedIn.where((p) => p.printedAt == null).toList();
    final fullyVerified = checkedIn.where((p) => p.printedAt != null).toList();
    final printed = participants.where((p) => p.printedAt != null).length;
    final pending = participants.length - checkedIn.length;
    final checkedInNotPrinted = partiallyVerified.length;
    final medicalFlags =
        participants.where((p) => _hasText(p.medicalInfo)).length;
    final checkedInMedicalFlags =
        checkedIn.where((p) => _hasText(p.medicalInfo)).length;
    final notes = participants.where((p) => _hasText(p.note)).length;
    final missingRooms =
        participants.where((p) => !_hasText(p.roomNumber)).length;
    final missingTables =
        participants.where((p) => !_hasText(p.tableNumber)).length;
    final missingRoomAmongCheckedIn =
        checkedIn.where((p) => !_hasText(p.roomNumber)).length;
    final missingTableAmongCheckedIn =
        checkedIn.where((p) => !_hasText(p.tableNumber)).length;

    final now = DateTime.now().millisecondsSinceEpoch;
    final recent15Minutes = checkedIn
        .where(
          (p) =>
              now - (p.verifiedAt ?? 0) <=
              const Duration(minutes: 15).inMilliseconds,
        )
        .length;
    final recentHour = checkedIn
        .where(
          (p) =>
              now - (p.verifiedAt ?? 0) <=
              const Duration(hours: 1).inMilliseconds,
        )
        .length;

    final activityBuckets = _buildActivityBuckets(checkedIn);
    final dailyActivityRows = _buildDailyActivityRows(
      participants: participants,
      printAttempts: printAttempts,
    );
    final peakHour = activityBuckets.fold<int>(
      0,
      (current, bucket) => math.max(current, bucket.count),
    );

    final stakeRows = _buildBreakdown(
      participants,
      (participant) => _normalizeLabel(participant.stake, 'Unknown stake'),
    )..sort((a, b) => b.total.compareTo(a.total));
    final stakeAttendingRows = [...stakeRows]..sort(_sortByCheckedInThenTotal);
    final stakePartialRows = [...stakeRows]
      ..sort((a, b) => b.partial.compareTo(a.partial));

    final wardRows = _buildBreakdown(
      participants,
      (participant) => _normalizeLabel(participant.ward, 'Unknown ward'),
    )..sort((a, b) => b.pending.compareTo(a.pending));
    final wardAttendingRows = [...wardRows]..sort(_sortByCheckedInThenTotal);

    final roomRows = _buildBreakdown(
      participants,
      (participant) => _normalizeLabel(participant.roomNumber, 'No room'),
    )..sort(_sortByCheckedInThenTotal);
    final activeRoomRows = roomRows
        .where((row) => row.label != 'No room' && row.checkedIn > 0)
        .toList();
    final readyRoomRows = roomRows
        .where(
          (row) =>
              row.label != 'No room' &&
              row.total > 0 &&
              row.checkedIn == row.total,
        )
        .toList()
      ..sort(_sortByCheckedInThenTotal);

    final tableRows = _buildBreakdown(
      participants,
      (participant) => _normalizeLabel(participant.tableNumber, 'No table'),
    )..sort(_sortByCheckedInThenTotal);
    final activeTableRows = tableRows
        .where((row) => row.label != 'No table' && row.checkedIn > 0)
        .toList();
    final readyTableRows = tableRows
        .where(
          (row) =>
              row.label != 'No table' &&
              row.total > 0 &&
              row.checkedIn == row.total,
        )
        .toList()
      ..sort(_sortByCheckedInThenTotal);

    final genderRows = _buildBreakdown(
      participants,
      (participant) => _normalizeLabel(participant.gender, 'Unknown'),
    )..sort((a, b) => b.total.compareTo(a.total));

    final ageRows = _buildAgeBreakdown(participants);
    final shirtSizeRows = _buildBreakdown(
      participants,
      (participant) => _normalizeLabel(participant.tshirtSize, 'Unknown size'),
    )..sort((a, b) => b.total.compareTo(a.total));
    final medicalCategoryRows = _buildMedicalBreakdown(participants);
    final syncTypeRows = _buildSyncBreakdown(syncTasks);
    final retryingSyncCount =
        syncTasks.where((task) => task.attempts > 0).length;
    final oldestPendingTask = syncTasks.isEmpty
        ? null
        : syncTasks.map((task) => task.createdAt).reduce(math.min);
    final recentCheckIns = [...checkedIn]
      ..sort((a, b) => (b.verifiedAt ?? 0).compareTo(a.verifiedAt ?? 0));
    final recentPrintAttempts = [...printAttempts]
      ..sort((a, b) => b.finishedAt.compareTo(a.finishedAt));
    final successfulAttempts =
        printAttempts.where((attempt) => attempt.outcome == 'success').length;
    final failedAttempts =
        printAttempts.where((attempt) => attempt.outcome == 'failed').length;
    final cancelledAttempts =
        printAttempts.where((attempt) => attempt.outcome == 'cancelled').length;
    final retryAttempts =
        printAttempts.where((attempt) => attempt.attemptNumber > 1).length;
    final retrySuccesses = printAttempts
        .where(
          (attempt) =>
              attempt.attemptNumber > 1 && attempt.outcome == 'success',
        )
        .length;
    final reprintAttempts =
        printAttempts.where((attempt) => attempt.isReprint).length;
    final uniquePrinterCount = printAttempts
        .map((attempt) => attempt.printerAddress?.trim() ?? '')
        .where((address) => address.isNotEmpty)
        .toSet()
        .length;
    final queuedPrintJobs =
        printJobs.where((job) => job.status == 'queued').toList();
    final staleQueuedPrintCount = queuedPrintJobs
        .where(
          (job) =>
              now - job.queuedAt > const Duration(minutes: 15).inMilliseconds,
        )
        .length;
    final oldestQueuedPrintAgeMinutes = queuedPrintJobs.isEmpty
        ? 0.0
        : (now - queuedPrintJobs.map((job) => job.queuedAt).reduce(math.min)) /
            const Duration(minutes: 1).inMilliseconds;
    final printedParticipants = participants
        .where((p) => p.verifiedAt != null && p.printedAt != null)
        .toList();
    final averageVerifyToPrintMinutes = printedParticipants.isEmpty
        ? 0.0
        : printedParticipants
                .map((p) => (p.printedAt! - p.verifiedAt!).toDouble())
                .reduce((left, right) => left + right) /
            printedParticipants.length /
            const Duration(minutes: 1).inMilliseconds;
    final successfulJobs = printJobs
        .where((job) => job.status == 'success' && job.attemptCount > 0)
        .toList();
    final averageAttemptsPerSuccessfulJob = successfulJobs.isEmpty
        ? 0.0
        : successfulJobs
                .map((job) => job.attemptCount)
                .reduce((left, right) => left + right) /
            successfulJobs.length;
    final failureCodeRows = _buildAttemptBreakdown(
      printAttempts.where((attempt) => attempt.outcome == 'failed'),
      (attempt) =>
          _normalizeAttemptLabel(attempt.failureCode, 'Unknown failure'),
    );
    final printerRows = _buildAttemptBreakdown(
      printAttempts,
      (attempt) =>
          _normalizeAttemptLabel(attempt.printerAddress, 'Unknown printer'),
    );
    final averagePrintAttemptSeconds = printAttempts.isEmpty
        ? 0.0
        : printAttempts
                .map(
                  (attempt) =>
                      (attempt.finishedAt - attempt.startedAt).toDouble(),
                )
                .reduce((left, right) => left + right) /
            printAttempts.length /
            1000;
    final printAttemptsLastHour = printAttempts
        .where(
          (attempt) =>
              now - attempt.finishedAt <=
              const Duration(hours: 1).inMilliseconds,
        )
        .length;
    final printFailuresLastHour = printAttempts
        .where(
          (attempt) =>
              attempt.outcome == 'failed' &&
              now - attempt.finishedAt <=
                  const Duration(hours: 1).inMilliseconds,
        )
        .length;
    final printSuccessesLastHour = printAttempts
        .where(
          (attempt) =>
              attempt.outcome == 'success' &&
              now - attempt.finishedAt <=
                  const Duration(hours: 1).inMilliseconds,
        )
        .length;

    final exceptionCount = checkedInNotPrinted +
        missingRoomAmongCheckedIn +
        missingTableAmongCheckedIn +
        retryingSyncCount +
        medicalFlags +
        syncTasks.length +
        staleQueuedPrintCount;

    return _AnalyticsSnapshot(
      totalParticipants: participants.length,
      checkedInCount: checkedIn.length,
      pendingCount: pending,
      partiallyVerifiedCount: partiallyVerified.length,
      fullyVerifiedCount: fullyVerified.length,
      printedCount: printed,
      checkedInNotPrintedCount: checkedInNotPrinted,
      medicalFlagCount: medicalFlags,
      checkedInMedicalFlagCount: checkedInMedicalFlags,
      noteCount: notes,
      missingRoomCount: missingRooms,
      missingTableCount: missingTables,
      missingRoomAmongCheckedInCount: missingRoomAmongCheckedIn,
      missingTableAmongCheckedInCount: missingTableAmongCheckedIn,
      recent15MinuteCount: recent15Minutes,
      recentHourCount: recentHour,
      peakHourCount: peakHour,
      pendingSyncTaskCount: syncTasks.length,
      retryingSyncTaskCount: retryingSyncCount,
      exceptionCount: exceptionCount,
      oldestPendingTask: oldestPendingTask,
      completionRate: participants.isEmpty
          ? 0
          : checkedIn.length / participants.length * 100,
      fullVerificationRate: participants.isEmpty
          ? 0
          : fullyVerified.length / participants.length * 100,
      printCoverageRate:
          checkedIn.isEmpty ? 0 : printed / checkedIn.length * 100,
      topStakeRows: stakeRows.take(6).toList(),
      stakeAttendingRows: stakeAttendingRows,
      topStakePartialRows: stakePartialRows.take(6).toList(),
      wardAttendingRows: wardAttendingRows,
      topWardPendingRows: wardRows.take(6).toList(),
      topRoomRows: roomRows.take(6).toList(),
      tableRows: activeTableRows,
      roomRows: activeRoomRows,
      readyTableRows: readyTableRows,
      readyRoomRows: readyRoomRows,
      genderRows: genderRows,
      ageRows: ageRows,
      shirtSizeRows: shirtSizeRows,
      medicalCategoryRows: medicalCategoryRows,
      syncTypeRows: syncTypeRows,
      activityBuckets: activityBuckets,
      dailyActivityRows: dailyActivityRows,
      recentCheckIns: recentCheckIns.take(8).toList(),
      recentPrintJobs: printJobs.take(8).toList(),
      recentPrintAttempts: recentPrintAttempts.take(8).toList(),
      totalPrintAttemptCount: printAttempts.length,
      successfulPrintAttemptCount: successfulAttempts,
      failedPrintAttemptCount: failedAttempts,
      cancelledPrintAttemptCount: cancelledAttempts,
      retryAttemptCount: retryAttempts,
      retrySuccessCount: retrySuccesses,
      reprintAttemptCount: reprintAttempts,
      uniquePrinterCount: uniquePrinterCount,
      activeTableCount: activeTableRows.length,
      completedTableCount: readyTableRows.length,
      activeRoomCount: activeRoomRows.length,
      completedRoomCount: readyRoomRows.length,
      staleQueuedPrintCount: staleQueuedPrintCount,
      averageAttemptsPerSuccessfulJob: averageAttemptsPerSuccessfulJob,
      averageVerifyToPrintMinutes: averageVerifyToPrintMinutes,
      oldestQueuedPrintAgeMinutes: oldestQueuedPrintAgeMinutes,
      averagePrintAttemptSeconds: averagePrintAttemptSeconds,
      printAttemptsLastHour: printAttemptsLastHour,
      printFailuresLastHour: printFailuresLastHour,
      printSuccessesLastHour: printSuccessesLastHour,
      failureCodeRows: failureCodeRows.take(6).toList(),
      printerRows: printerRows.take(6).toList(),
    );
  }

  double get liveAttendanceRate => completionRate;

  double get partiallyVerifiedRate {
    if (checkedInCount == 0) {
      return 0;
    }
    return partiallyVerifiedCount / checkedInCount * 100;
  }

  double get printSuccessRate {
    if (totalPrintAttemptCount == 0) {
      return 0;
    }
    return successfulPrintAttemptCount / totalPrintAttemptCount * 100;
  }

  double get retrySuccessRate {
    if (retryAttemptCount == 0) {
      return 0;
    }
    return retrySuccessCount / retryAttemptCount * 100;
  }

  static List<_BreakdownRow> _buildBreakdown(
    List<Participant> participants,
    String Function(Participant participant) labelOf,
  ) {
    final grouped = <String, _BreakdownAccumulator>{};
    for (final participant in participants) {
      final label = labelOf(participant);
      final accumulator = grouped.putIfAbsent(label, _BreakdownAccumulator.new);
      accumulator.total++;
      if (participant.verifiedAt != null) {
        accumulator.checkedIn++;
      }
      if (participant.verifiedAt != null && participant.printedAt == null) {
        accumulator.partial++;
      }
      if (participant.printedAt != null) {
        accumulator.printed++;
      }
    }

    return grouped.entries
        .map(
          (entry) => _BreakdownRow(
            label: entry.key,
            total: entry.value.total,
            checkedIn: entry.value.checkedIn,
            partial: entry.value.partial,
            printed: entry.value.printed,
          ),
        )
        .toList();
  }

  static List<_BreakdownRow> _buildAgeBreakdown(
    List<Participant> participants,
  ) {
    const order = ['13-14', '15-16', '17-19', '20+'];
    final grouped = <String, _BreakdownAccumulator>{
      for (final label in order) label: _BreakdownAccumulator(),
    };

    for (final participant in participants) {
      final age = participant.age;
      if (age == null) {
        continue;
      }
      final label = age <= 14
          ? '13-14'
          : age <= 16
              ? '15-16'
              : age <= 19
                  ? '17-19'
                  : '20+';
      final accumulator = grouped[label]!;
      accumulator.total++;
      if (participant.verifiedAt != null) {
        accumulator.checkedIn++;
      }
      if (participant.verifiedAt != null && participant.printedAt == null) {
        accumulator.partial++;
      }
      if (participant.printedAt != null) {
        accumulator.printed++;
      }
    }

    return order
        .map(
          (label) => _BreakdownRow(
            label: label,
            total: grouped[label]!.total,
            checkedIn: grouped[label]!.checkedIn,
            partial: grouped[label]!.partial,
            printed: grouped[label]!.printed,
          ),
        )
        .toList();
  }

  static List<_BreakdownRow> _buildMedicalBreakdown(
    List<Participant> participants,
  ) {
    final grouped = <String, _BreakdownAccumulator>{};
    for (final participant in participants) {
      if (!_hasText(participant.medicalInfo)) {
        continue;
      }
      final label = _classifyMedicalInfo(participant.medicalInfo!);
      final accumulator = grouped.putIfAbsent(label, _BreakdownAccumulator.new);
      accumulator.total++;
      if (participant.verifiedAt != null) {
        accumulator.checkedIn++;
      }
      if (participant.verifiedAt != null && participant.printedAt == null) {
        accumulator.partial++;
      }
      if (participant.printedAt != null) {
        accumulator.printed++;
      }
    }

    final rows = grouped.entries
        .map(
          (entry) => _BreakdownRow(
            label: entry.key,
            total: entry.value.total,
            checkedIn: entry.value.checkedIn,
            partial: entry.value.partial,
            printed: entry.value.printed,
          ),
        )
        .toList()
      ..sort((a, b) => b.total.compareTo(a.total));
    return rows.take(6).toList();
  }

  static List<_BreakdownRow> _buildSyncBreakdown(
    List<_SyncTaskEntry> syncTasks,
  ) {
    final grouped = <String, _BreakdownAccumulator>{};
    for (final task in syncTasks) {
      final accumulator = grouped.putIfAbsent(
        task.displayType,
        _BreakdownAccumulator.new,
      );
      accumulator.total++;
      if (task.attempts > 0) {
        accumulator.checkedIn++;
      }
    }

    final rows = grouped.entries
        .map(
          (entry) => _BreakdownRow(
            label: entry.key,
            total: entry.value.total,
            checkedIn: entry.value.checkedIn,
            partial: 0,
            printed: 0,
          ),
        )
        .toList();
    rows.sort((a, b) => b.total.compareTo(a.total));
    return rows;
  }

  static List<_AttemptBreakdownRow> _buildAttemptBreakdown(
    Iterable<PrinterJobAttempt> attempts,
    String Function(PrinterJobAttempt attempt) labelOf,
  ) {
    final grouped = <String, _AttemptBreakdownAccumulator>{};
    for (final attempt in attempts) {
      final label = labelOf(attempt);
      final accumulator = grouped.putIfAbsent(
        label,
        _AttemptBreakdownAccumulator.new,
      );
      accumulator.total++;
      switch (attempt.outcome) {
        case 'success':
          accumulator.successes++;
          break;
        case 'cancelled':
          accumulator.cancelled++;
          break;
        default:
          accumulator.failures++;
          break;
      }
    }

    final rows = grouped.entries
        .map(
          (entry) => _AttemptBreakdownRow(
            label: entry.key,
            total: entry.value.total,
            successes: entry.value.successes,
            failures: entry.value.failures,
            cancelled: entry.value.cancelled,
          ),
        )
        .toList();
    rows.sort((a, b) => b.total.compareTo(a.total));
    return rows;
  }

  static int _sortByCheckedInThenTotal(
    _BreakdownRow left,
    _BreakdownRow right,
  ) {
    final checkedInCompare = right.checkedIn.compareTo(left.checkedIn);
    if (checkedInCompare != 0) {
      return checkedInCompare;
    }
    return right.total.compareTo(left.total);
  }

  static List<_ActivityBucket> _buildActivityBuckets(
    List<Participant> checkedIn,
  ) {
    final now = DateTime.now();
    final start = DateTime(
      now.year,
      now.month,
      now.day,
      now.hour,
    ).subtract(const Duration(hours: 7));
    final buckets = List.generate(
      8,
      (index) =>
          _ActivityBucket(start: start.add(Duration(hours: index)), count: 0),
    );

    for (final participant in checkedIn) {
      final verifiedAt = participant.verifiedAt;
      if (verifiedAt == null) {
        continue;
      }
      final time = DateTime.fromMillisecondsSinceEpoch(verifiedAt);
      final bucketIndex = time.difference(start).inHours;
      if (bucketIndex >= 0 && bucketIndex < buckets.length) {
        buckets[bucketIndex] = _ActivityBucket(
          start: buckets[bucketIndex].start,
          count: buckets[bucketIndex].count + 1,
        );
      }
    }

    return buckets;
  }

  static List<_DailyActivityRow> _buildDailyActivityRows({
    required List<Participant> participants,
    required List<PrinterJobAttempt> printAttempts,
  }) {
    final rows = <String, _DailyActivityAccumulator>{};

    for (final participant in participants) {
      if (participant.verifiedAt != null) {
        final dayKey = _dayKey(
          DateTime.fromMillisecondsSinceEpoch(participant.verifiedAt!),
        );
        final row = rows.putIfAbsent(
          dayKey,
          () => _DailyActivityAccumulator(dayKey),
        );
        row.checkedIn++;
      }
      if (participant.printedAt != null) {
        final dayKey = _dayKey(
          DateTime.fromMillisecondsSinceEpoch(participant.printedAt!),
        );
        final row = rows.putIfAbsent(
          dayKey,
          () => _DailyActivityAccumulator(dayKey),
        );
        row.fullyVerified++;
      }
    }

    for (final attempt in printAttempts) {
      final dayKey = _dayKey(
        DateTime.fromMillisecondsSinceEpoch(attempt.finishedAt),
      );
      final row = rows.putIfAbsent(
        dayKey,
        () => _DailyActivityAccumulator(dayKey),
      );
      row.printAttempts++;
      if (attempt.outcome == 'failed') {
        row.printFailures++;
      }
    }

    final result = rows.values.map((row) => row.toRow()).toList();
    result.sort((a, b) => b.date.compareTo(a.date));
    return result.take(7).toList();
  }

  static String _normalizeLabel(String? raw, String fallback) {
    if (!_hasText(raw)) {
      return fallback;
    }
    return raw!.trim();
  }

  static String _normalizeAttemptLabel(String? raw, String fallback) {
    if (raw == null) {
      return fallback;
    }
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      return fallback;
    }
    return trimmed;
  }

  static DateTime _startOfDay(DateTime value) {
    return DateTime(value.year, value.month, value.day);
  }

  static String _dayKey(DateTime value) {
    final day = _startOfDay(value);
    return DateFormat('yyyy-MM-dd').format(day);
  }

  static bool _hasText(String? value) {
    if (value == null) {
      return false;
    }
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      return false;
    }
    final lower = trimmed.toLowerCase();
    return lower != 'none' && lower != 'n/a' && lower != 'null';
  }

  static String _classifyMedicalInfo(String value) {
    final normalized = value.toLowerCase();
    if (normalized.contains('allerg')) {
      return 'Allergies';
    }
    if (normalized.contains('asthma') ||
        normalized.contains('inhaler') ||
        normalized.contains('respir')) {
      return 'Respiratory';
    }
    if (normalized.contains('diet') ||
        normalized.contains('gluten') ||
        normalized.contains('lactose') ||
        normalized.contains('food')) {
      return 'Dietary';
    }
    if (normalized.contains('med') || normalized.contains('medicine')) {
      return 'Medication';
    }
    return 'Other medical';
  }
}

class _MetricCardData {
  final String label;
  final String value;
  final String helper;
  final IconData icon;
  final Color color;

  const _MetricCardData({
    required this.label,
    required this.value,
    required this.helper,
    required this.icon,
    required this.color,
  });
}

class _ExceptionData {
  final String label;
  final int value;
  final Color color;

  const _ExceptionData({
    required this.label,
    required this.value,
    required this.color,
  });
}

class _BreakdownRow {
  final String label;
  final int total;
  final int checkedIn;
  final int partial;
  final int printed;

  const _BreakdownRow({
    required this.label,
    required this.total,
    required this.checkedIn,
    required this.partial,
    required this.printed,
  });

  int get pending => total - checkedIn;
}

class _BreakdownAccumulator {
  int total = 0;
  int checkedIn = 0;
  int partial = 0;
  int printed = 0;
}

class _AttemptBreakdownRow {
  final String label;
  final int total;
  final int successes;
  final int failures;
  final int cancelled;

  const _AttemptBreakdownRow({
    required this.label,
    required this.total,
    required this.successes,
    required this.failures,
    required this.cancelled,
  });
}

class _AttemptBreakdownAccumulator {
  int total = 0;
  int successes = 0;
  int failures = 0;
  int cancelled = 0;
}

class _ActivityBucket {
  final DateTime start;
  final int count;

  const _ActivityBucket({required this.start, required this.count});
}

class _DailyActivityRow {
  final DateTime date;
  final String label;
  final int checkedIn;
  final int fullyVerified;
  final int printAttempts;
  final int printFailures;

  const _DailyActivityRow({
    required this.date,
    required this.label,
    required this.checkedIn,
    required this.fullyVerified,
    required this.printAttempts,
    required this.printFailures,
  });
}

class _DailyActivityAccumulator {
  final String key;
  int checkedIn = 0;
  int fullyVerified = 0;
  int printAttempts = 0;
  int printFailures = 0;

  _DailyActivityAccumulator(this.key);

  _DailyActivityRow toRow() {
    final date = DateTime.parse(key);
    return _DailyActivityRow(
      date: date,
      label: DateFormat('EEE, MMM d').format(date),
      checkedIn: checkedIn,
      fullyVerified: fullyVerified,
      printAttempts: printAttempts,
      printFailures: printFailures,
    );
  }
}

class _SyncTaskEntry {
  final int id;
  final String type;
  final String status;
  final int attempts;
  final String? lastError;
  final int createdAt;
  final Map<String, dynamic> payload;

  const _SyncTaskEntry({
    required this.id,
    required this.type,
    required this.status,
    required this.attempts,
    required this.lastError,
    required this.createdAt,
    required this.payload,
  });

  factory _SyncTaskEntry.fromRow(Map<String, Object?> row) {
    Map<String, dynamic> payload = const {};
    final rawPayload = row['payload'] as String? ?? '{}';
    try {
      payload = Map<String, dynamic>.from(jsonDecode(rawPayload));
    } catch (_) {
      payload = const {};
    }

    return _SyncTaskEntry(
      id: row['id'] as int? ?? 0,
      type: row['type'] as String? ?? 'unknown',
      status: row['status'] as String? ?? 'pending',
      attempts: row['attempts'] as int? ?? 0,
      lastError: row['last_error'] as String?,
      createdAt: row['created_at'] as int? ?? 0,
      payload: payload,
    );
  }

  String get displayType {
    switch (type) {
      case 'mark_registered':
        return 'Check-in sync';
      case 'mark_printed':
        return 'Print sync';
      case 'mark_unverified':
        return 'Undo sync';
      default:
        return type;
    }
  }
}
