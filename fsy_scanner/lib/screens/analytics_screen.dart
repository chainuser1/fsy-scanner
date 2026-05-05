import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';

import '../app.dart';
import '../db/database_helper.dart';
import '../db/participants_dao.dart';
import '../models/participant.dart';
import '../print/printer_service.dart';
import '../providers/app_state.dart';
import '../services/analytics_export_service.dart';
import '../sync/sync_engine.dart';

enum _CommitteeView {
  comprehensiveSummary,
  registration,
  logistics,
  food,
  medical,
  admin,
  activities,
  developers,
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
  bool _loading = true;
  String? _error;
  int _requestId = 0;
  _CommitteeView _committeeView = _CommitteeView.comprehensiveSummary;
  int? _recentScanMarker;
  int? _pendingTaskMarker;
  int? _failedPrintMarker;
  PendingSummaryConfirmation? _pendingSummaryConfirmation;
  int? _lastPulledAt;
  String _dbVersion = 'Unknown';
  String _appVersion = 'Unknown';
  String _appBuildNumber = 'Unknown';

  final Map<String, int> _breakdownPage = {};
  final Map<String, int> _participantListPage = {};
  _AnalyticsSnapshot? _previousSnapshot;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final appState = context.watch<AppState>();
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
        WHERE status IN ('pending', 'in_progress', 'failed')
        ORDER BY created_at DESC
        LIMIT 300
      ''');
      final printJobsFuture = PrinterService.getRecentPrintJobs(limit: 500);
      final printAttemptsFuture = PrinterService.getRecentPrintAttempts(
        limit: 1000,
      );
      final pendingSummaryFuture =
          PrinterService.getPendingSummaryConfirmation();
      final settingsFuture = db.query(
        'app_settings',
        where: 'key IN (?, ?)',
        whereArgs: ['last_pulled_at', 'db_version'],
      );
      final packageInfoFuture = PackageInfo.fromPlatform();

      final participants = await participantsFuture;
      final taskRows = await syncTasksFuture;
      final printJobs = await printJobsFuture;
      final printAttempts = await printAttemptsFuture;
      final pendingSummary = await pendingSummaryFuture;
      final settingsRows = await settingsFuture;
      final packageInfo = await packageInfoFuture;
      final settingsMap = {
        for (final row in settingsRows)
          row['key'] as String: row['value'] as String? ?? '',
      };

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
        _pendingSummaryConfirmation = pendingSummary;
        _lastPulledAt = int.tryParse(settingsMap['last_pulled_at'] ?? '');
        _dbVersion = settingsMap['db_version']?.trim().isNotEmpty == true
            ? settingsMap['db_version']!
            : 'Unknown';
        _appVersion = packageInfo.version;
        _appBuildNumber = packageInfo.buildNumber;
        _loading = false;
        _error = null;
      });
    } catch (error) {
      if (!mounted || requestId != _requestId) {
        return;
      }
      setState(() {
        _loading = false;
        _error = 'Unable to load need-based analytics: $error';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final previous = _previousSnapshot;
    final analytics = _AnalyticsSnapshot.fromData(
      participants: _participants,
      syncTasks: _syncTasks,
      printJobs: _printJobs,
      printAttempts: _printAttempts,
    );
    // Store for next build so metric cards can show deltas.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _previousSnapshot = analytics;
    });

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
                value: 'export_summary',
                child: Text('Export text summary'),
              ),
              PopupMenuItem(
                value: 'save_pdf_as',
                child: Text('Save PDF as...'),
              ),
              PopupMenuItem(
                value: 'export_pdf',
                child: Text('Export PDF summary'),
              ),
              PopupMenuItem(
                value: 'share_pdf',
                child: Text('Share PDF summary'),
              ),
              PopupMenuItem(
                value: 'print_summary',
                child: Text('Print thermal summary'),
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
                    children: _buildSelectedView(appState, analytics, previous),
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
            FilledButton.icon(
              onPressed: _load,
              icon: const Icon(Icons.refresh),
              label: const Text('Try again'),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildSelectedView(
    AppState appState,
    _AnalyticsSnapshot analytics,
    _AnalyticsSnapshot? previous,
  ) {
    final widgets = <Widget>[
      _buildHeader(appState, analytics),
      const SizedBox(height: 12),
      if (_pendingSummaryConfirmation != null) ...[
        _buildPendingSummaryConfirmationCard(),
        const SizedBox(height: 12),
      ],
    ];

    switch (_committeeView) {
      case _CommitteeView.comprehensiveSummary:
        widgets.addAll(
            _buildComprehensiveSummaryView(appState, analytics, previous));
        break;
      case _CommitteeView.registration:
        widgets.addAll(_buildRegistrationView(appState, analytics, previous));
        break;
      case _CommitteeView.logistics:
        widgets.addAll(_buildLogisticsView(appState, analytics, previous));
        break;
      case _CommitteeView.food:
        widgets.addAll(_buildFoodView(appState, analytics, previous));
        break;
      case _CommitteeView.medical:
        widgets.addAll(_buildMedicalView(appState, analytics, previous));
        break;
      case _CommitteeView.admin:
        widgets.addAll(_buildAdminView(appState, analytics, previous));
        break;
      case _CommitteeView.activities:
        widgets.addAll(_buildActivitiesView(appState, analytics, previous));
        break;
      case _CommitteeView.developers:
        widgets.addAll(_buildDevelopersView(appState, analytics, previous));
        break;
    }
    return widgets;
  }

  Widget _buildHeader(AppState appState, _AnalyticsSnapshot analytics) {
    final eventTitle = appState.eventName.trim().isEmpty
        ? 'Current Event'
        : appState.eventName.trim();
    final organizationTitle = appState.organizationName.trim();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              eventTitle,
              style: Theme.of(
                context,
              ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
            ),
            if (organizationTitle.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                organizationTitle,
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(color: Colors.grey[700]),
              ),
            ],
            const SizedBox(height: 12),
            Text(
              _viewSubtitle(analytics),
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: Colors.grey[800]),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _statusChip(
                  label: appState.isOnline ? 'Online' : 'Offline',
                  color: appState.isOnline
                      ? FSYScannerApp.accentGreen.withValues(alpha: 0.18)
                      : Colors.red.withValues(alpha: 0.14),
                  textColor: appState.isOnline
                      ? Colors.green.shade900
                      : Colors.red.shade900,
                ),
                _statusChip(
                  label: appState.printerConnected
                      ? 'Printer ready'
                      : 'Printer needs attention',
                  color: appState.printerConnected
                      ? FSYScannerApp.primaryBlue.withValues(alpha: 0.14)
                      : FSYScannerApp.accentGold.withValues(alpha: 0.18),
                  textColor: appState.printerConnected
                      ? FSYScannerApp.primaryBlue
                      : Colors.black87,
                ),
                _statusChip(
                  label: analytics.pendingSyncTaskCount == 0
                      ? 'Sync queue clear'
                      : '${analytics.pendingSyncTaskCount} sync tasks pending',
                  color: analytics.pendingSyncTaskCount == 0
                      ? FSYScannerApp.accentGreen.withValues(alpha: 0.18)
                      : FSYScannerApp.accentGold.withValues(alpha: 0.18),
                  textColor: analytics.pendingSyncTaskCount == 0
                      ? Colors.green.shade900
                      : Colors.black87,
                ),
              ],
            ),
            const SizedBox(height: 16),
            const Text(
              'Select view',
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
                          _breakdownPage.clear();
                          _participantListPage.clear();
                        });
                      },
                    ),
                  )
                  .toList(),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildComprehensiveSummaryView(
    AppState appState,
    _AnalyticsSnapshot analytics,
    _AnalyticsSnapshot? previous,
  ) {
    final topTshirtSummary = analytics.tshirtRows.isEmpty
        ? 'No t-shirt sizes are recorded yet.'
        : '${analytics.tshirtRows.first.trailing} participants need ${analytics.tshirtRows.first.label} shirts, the largest recorded size group.';
    final topGenderSummary = analytics.genderRows.isEmpty
        ? 'Gender data is not recorded yet.'
        : '${analytics.genderRows.first.trailing} participants are in the largest recorded gender group.';

    return [
      _buildBriefingCard(
        title: 'Comprehensive Summary',
        subtitle:
            "Use this as the leadership handoff: one scrollable report with each committee's headline, operational numbers, and current device status.",
        children: [
          _buildSentenceList([
            'Generated ${DateFormat('dd MMM yyyy h:mm a').format(DateTime.now())}.',
            '${analytics.checkedInCount} of ${analytics.totalParticipants} participants have arrived so far.',
            '${analytics.pendingCount} are still not checked in, ${analytics.partiallyVerifiedCount} are still finishing registration, and ${analytics.checkedInMedicalFlagCount} on site have medical flags.',
            'This device currently shows ${analytics.pendingSyncTaskCount} pending sync tasks, ${analytics.failedSyncTaskCount} failed sync tasks, and ${analytics.queuedPrintCount} queued prints.',
            analytics.estimatedCompletionLabel,
            analytics.velocityTrendLabel,
          ]),
        ],
      ),
      const SizedBox(height: 12),
      _buildCriticalBlockersCard(analytics),
      const SizedBox(height: 12),
      _buildProgressCard(
        title: 'Overall Event Progress',
        headline:
            '${analytics.checkedInCount} of ${analytics.totalParticipants} participants have arrived',
        current: analytics.checkedInCount,
        total: analytics.totalParticipants,
        subtitle:
            '${analytics.fullyVerifiedCount} are fully complete and ${analytics.printedCount} have confirmed print output.',
      ),
      const SizedBox(height: 12),
      _buildMetricGrid([
        _MetricCardData(
          label: 'No-Shows',
          value: '${analytics.pendingCount}',
          helper: 'Still not checked in',
          icon: Icons.person_off_outlined,
          color: Colors.grey.shade700,
        ),
        _MetricCardData(
          label: 'Food Attention',
          value: '${analytics.dietAttentionOnSiteCount}',
          helper: 'Checked-in participants with restriction notes',
          icon: Icons.no_meals_outlined,
          color: FSYScannerApp.accentGold,
        ),
        _MetricCardData(
          label: 'Medical Review',
          value: '${analytics.urgentMedicalOnSiteCount}',
          helper:
              '${analytics.checkedInMedicalFlagCount} on site have medical notes',
          icon: Icons.medical_information_outlined,
          color: Colors.redAccent,
        ),
        _MetricCardData(
          label: 'Top Scanner',
          value: '${analytics.topCheckInDeviceCount}',
          helper: analytics.topCheckInDeviceLabel,
          icon: Icons.qr_code_scanner_outlined,
          color: FSYScannerApp.primaryBlue,
        ),
      ]),
      const SizedBox(height: 12),
      _buildSectionSummaryCard(
        title: 'Registration & Check-In',
        subtitle: 'Arrival progress, pace, and unresolved check-in work.',
        lines: [
          '${analytics.checkedInCount} of ${analytics.totalParticipants} participants have arrived.',
          '${analytics.approvedCount} are approved in the roster and ${analytics.notApprovedCount} still need admin readiness attention.',
          '${analytics.recentHourCount} check-ins happened in the last hour and ${analytics.recent15MinuteCount} in the last 15 minutes.',
          '${analytics.pendingCount} participants still have no QR/check-in recorded.',
          'Top scanner: ${analytics.topCheckInDeviceLabel} with ${analytics.topCheckInDeviceCount} check-ins.',
        ],
      ),
      const SizedBox(height: 12),
      _buildSectionSummaryCard(
        title: 'Logistics',
        subtitle: 'Materials, transport grouping, and on-site assignment gaps.',
        lines: [
          '${analytics.checkedInCount} participants are currently confirmed on site for materials planning.',
          '${analytics.checkedInMissingRoomCount} attendees still need a room and ${analytics.checkedInMissingTableCount} still need a group.',
          topTshirtSummary,
          '${analytics.pendingCount} no-shows currently affect transport and supply planning.',
        ],
      ),
      const SizedBox(height: 12),
      _buildSectionSummaryCard(
        title: 'Food',
        subtitle: 'Meal count and restriction follow-up.',
        lines: [
          '${analytics.checkedInCount} plates are the current on-site serving estimate.',
          '${analytics.dietAttentionOnSiteCount} checked-in participants are explicitly marked for food attention or have matching restriction notes.',
          '${analytics.noRestrictionOnSiteCount} checked-in participants currently show no restriction recorded.',
          '${analytics.foodOnlyOnSiteCount} are food-only, while ${analytics.medicalAndFoodOnSiteCount} have both medical and food attention.',
          'Meal grouping can use assigned groups when needed.',
        ],
      ),
      const SizedBox(height: 12),
      _buildSectionSummaryCard(
        title: 'Medical / Health',
        subtitle: 'Who needs awareness or follow-up.',
        lines: [
          '${analytics.checkedInMedicalFlagCount} checked-in participants have medical attention flags.',
          '${analytics.urgentMedicalOnSiteCount} appear to need priority review and ${analytics.generalMedicalAwarenessOnSiteCount} are general awareness cases.',
          '${analytics.medicalNotArrivedCount} participants with medical notes have not arrived yet.',
          '${analytics.medicalOnlyOnSiteCount} are medical-only and ${analytics.medicalAndFoodOnSiteCount} have both medical and food follow-up.',
          '${analytics.medicalWithoutLocationCount} medical-flagged attendees are harder to locate because room or group data is missing.',
        ],
      ),
      const SizedBox(height: 12),
      _buildSectionSummaryCard(
        title: 'Admin',
        subtitle: 'Leadership headlines and operational risk.',
        lines: [
          '${analytics.fullyVerifiedCount} participants are fully complete.',
          '${analytics.approvedCount} are approved and ${analytics.notApprovedCount} still need approval or online registration follow-up.',
          '${analytics.printedCount} have printed receipts and ${analytics.notPrintedCount} checked-in participants are still missing confirmed print output.',
          '${analytics.pendingSyncTaskCount} pending sync tasks and ${analytics.failedSyncTaskCount} failed tasks affect device confidence.',
          _formatLastSync(appState.lastSyncedAt),
        ],
      ),
      const SizedBox(height: 12),
      _buildSectionSummaryCard(
        title: 'Operations / Activities',
        subtitle: 'Grouping, group readiness, and attendance.',
        lines: [
          '${analytics.fullyVerifiedCount} participants are fully ready for activities.',
          '${analytics.completedTableCount} groups are fully ready and ${analytics.activeTableCount} groups have assigned participants.',
          '${analytics.checkedInMissingTableCount} checked-in participants still need a group assignment.',
          topGenderSummary,
        ],
      ),
      const SizedBox(height: 12),
      _buildSectionSummaryCard(
        title: 'Developers',
        subtitle: 'Software, sync, print, and build health on this device.',
        lines: [
          '${analytics.pendingSyncTaskCount} pending sync tasks, ${analytics.failedSyncTaskCount} failed sync tasks, and ${analytics.syncErrorSampleCount} tasks with error text are in the local sample.',
          '${analytics.printFailuresLastHour} print failures happened in the last hour and ${analytics.queuedPrintCount} print jobs are still queued.',
          'App version $_appVersion ($_appBuildNumber), database version $_dbVersion.',
          'Last roster pull: ${_formatOptionalTimestamp(_lastPulledAt)}.',
        ],
      ),
      const SizedBox(height: 12),
      _buildAttentionCard(
        title: 'Cross-Committee Attention Needed',
        items: [
          _AttentionItem(
            label: 'Participants blocked from full completion',
            value:
                '${analytics.partiallyVerifiedCount} partial, ${analytics.pendingConfirmationCount} waiting for operator confirmation',
          ),
          _AttentionItem(
            label: 'Assignment gaps',
            value:
                '${analytics.checkedInMissingRoomCount} missing room, ${analytics.checkedInMissingTableCount} missing group among checked-in participants',
          ),
          _AttentionItem(
            label: 'Device-local backlog',
            value:
                '${analytics.queuedPrintCount} queued print jobs, ${analytics.pendingSyncTaskCount} pending sync tasks, ${analytics.failedSyncTaskCount} failed sync tasks',
          ),
          _AttentionItem(
            label: 'Food and medical review',
            value:
                '${analytics.dietAttentionOnSiteCount} food-related attention flags and ${analytics.urgentMedicalOnSiteCount} urgent-looking medical flags are on site',
          ),
        ],
      ),
      const SizedBox(height: 12),
      _buildBreakdownCard(
        title: 'Check-In Activity Timeline',
        subtitle:
            'Latest hourly check-in pace for leadership and registration.',
        rows: analytics.hourlyCheckInRows,
        pageKey: 'comp_hourly_checkin',
      ),
      const SizedBox(height: 12),
      _buildBreakdownCard(
        title: 'Registration Source Summary',
        subtitle:
            'Shows how many participants are online-only, printed-only, or have both registration paths recorded.',
        rows: analytics.registrationSourceRows,
        pageKey: 'comp_reg_source',
      ),
      const SizedBox(height: 12),
      _buildBreakdownCard(
        title: 'Approval Status Summary',
        subtitle:
            'Useful for leadership and admin follow-up before all participants are fully ready.',
        rows: analytics.statusRows,
        pageKey: 'comp_status',
      ),
      const SizedBox(height: 12),
      _buildBreakdownCard(
        title: 'Stake Attendance Summary',
        subtitle:
            'Useful when leadership wants to see where attendee volume is concentrated right now.',
        rows: analytics.stakeRows,
        pageKey: 'comp_stake',
      ),
      const SizedBox(height: 12),
      _buildBreakdownCard(
        title: 'Room And Group Readiness',
        subtitle:
            'Shows where participants are gathering and how close those groups are to being fully ready.',
        rows: analytics.locationReadinessRows,
        pageKey: 'comp_location_readiness',
      ),
      const SizedBox(height: 12),
      _buildGapNoteCard(
        title: 'Current Data Gaps',
        gaps: [
          'Late-arrival analytics cannot be exact yet because the roster does not include an expected arrival time field.',
          'Emergency contact awareness cannot be flagged yet because the current participant model has no emergency contact field.',
          'Per-device last successful sync time is not stored yet, so developer reporting uses the latest app-wide sync timestamp instead.',
        ],
      ),
      const SizedBox(height: 12),
      _buildDeviceScopeCard(appState, analytics),
    ];
  }

  List<Widget> _buildRegistrationView(
    AppState appState,
    _AnalyticsSnapshot analytics,
    _AnalyticsSnapshot? previous,
  ) {
    return [
      _buildBriefingCard(
        title: 'Registration & Check-In',
        subtitle:
            'Use arrival language here: who has arrived, how quickly check-ins are moving, which scanner is busiest, and who still has no QR/check-in recorded.',
        children: [
          _buildSentenceList([
            '${analytics.checkedInCount} of ${analytics.totalParticipants} participants have arrived.',
            '${analytics.recentHourCount} checked in during the last hour, and ${analytics.recent15MinuteCount} arrived in the last 15 minutes.',
            '${analytics.pendingCount} participants still have no QR scan/check-in recorded.',
            '${analytics.notApprovedCount} still need approval or online-registration follow-up.',
            analytics.estimatedCompletionLabel,
            analytics.velocityTrendLabel,
          ]),
        ],
      ),
      const SizedBox(height: 12),
      _buildProgressCard(
        title: 'Arrival Progress',
        headline:
            '${analytics.checkedInCount} of ${analytics.totalParticipants} participants have arrived',
        current: analytics.checkedInCount,
        total: analytics.totalParticipants,
        subtitle:
            '${analytics.fullyVerifiedCount} are fully complete and ${analytics.partiallyVerifiedCount} are still finishing the process.',
      ),
      const SizedBox(height: 12),
      _buildMetricGrid([
        _MetricCardData(
          label: 'Arrived',
          value: '${analytics.checkedInCount}',
          helper: '${analytics.pendingCount} still not arrived',
          icon: Icons.how_to_reg_outlined,
          color: FSYScannerApp.primaryBlue,
          delta: previous == null
              ? null
              : analytics.checkedInCount - previous.checkedInCount,
        ),
        _MetricCardData(
          label: 'Last Hour',
          value: '${analytics.recentHourCount}',
          helper:
              '${analytics.recent15MinuteCount} in last 15 min • ${analytics.velocityShortLabel}',
          icon: Icons.schedule_outlined,
          color: FSYScannerApp.accentGreen,
        ),
        _MetricCardData(
          label: 'Top Scanner',
          value: '${analytics.topCheckInDeviceCount}',
          helper: analytics.topCheckInDeviceLabel,
          icon: Icons.qr_code_scanner_outlined,
          color: FSYScannerApp.accentGold,
        ),
        _MetricCardData(
          label: 'Still Partial',
          value: '${analytics.partiallyVerifiedCount}',
          helper:
              '${analytics.pendingConfirmationCount} awaiting print confirmation',
          icon: Icons.receipt_long_outlined,
          color: Colors.orangeAccent,
          delta: previous == null
              ? null
              : analytics.partiallyVerifiedCount -
                  previous.partiallyVerifiedCount,
        ),
      ]),
      const SizedBox(height: 12),
      _buildBreakdownCard(
        title: 'Check-Ins Per Hour',
        subtitle:
            'Pace over time so the team can see whether arrivals are accelerating or slowing.',
        rows: analytics.hourlyCheckInRows,
        pageKey: 'reg_hourly_checkin',
      ),
      const SizedBox(height: 12),
      _buildBreakdownCard(
        title: 'Peak Check-In Times',
        subtitle: 'The busiest check-in windows from the current data sample.',
        rows: analytics.peakCheckInRows,
        pageKey: 'reg_peak_checkin',
      ),
      const SizedBox(height: 12),
      _buildBreakdownCard(
        title: 'Registration Source',
        subtitle:
            'Shows how many participants are online only, printed only, or recorded in both channels.',
        rows: analytics.registrationSourceRows,
        pageKey: 'reg_source',
      ),
      const SizedBox(height: 12),
      _buildBreakdownCard(
        title: 'Signed By',
        subtitle:
            'Useful when registration needs to follow up on unsigned forms or no printed copy cases.',
        rows: analytics.signedByRows,
        pageKey: 'reg_signed_by',
      ),
      const SizedBox(height: 12),
      _buildBreakdownCard(
        title: 'Scanner Activity',
        subtitle:
            'Which device or scanner has handled the most completed check-ins.',
        rows: analytics.deviceCheckInRows,
        pageKey: 'reg_scanner_activity',
      ),
      const SizedBox(height: 12),
      _buildParticipantListCard(
        title: 'Participants Still Waiting For Full Completion',
        subtitle:
            'These participants have arrived but registration is still waiting on final print confirmation or output.',
        items: analytics.partialParticipantAlerts,
        emptyMessage:
            'No checked-in participant is currently waiting for final registration completion.',
        pageKey: 'reg_partial',
      ),
      const SizedBox(height: 12),
      _buildParticipantListCard(
        title: 'Participants With No QR Scan Yet',
        subtitle:
            'These participants still have no recorded check-in and may still be arriving or need follow-up.',
        items: analytics.noShowAlerts,
        emptyMessage: 'Every participant currently has a recorded check-in.',
        pageKey: 'reg_no_show',
      ),
      const SizedBox(height: 12),
      _buildGapNoteCard(
        title: 'Current Data Gap',
        gaps: [
          "Late-arrival reporting is not exact yet because the roster does not store each participant's expected arrival time.",
        ],
      ),
    ];
  }

  List<Widget> _buildLogisticsView(
    AppState appState,
    _AnalyticsSnapshot analytics,
    _AnalyticsSnapshot? previous,
  ) {
    return [
      _buildBriefingCard(
        title: 'Logistics',
        subtitle:
            'Use this for materials, transport grouping, and assignment cleanup. Speak in counts the logistics team can act on immediately.',
        children: [
          _buildSentenceList([
            '${analytics.checkedInCount} participants are currently confirmed on site for materials planning.',
            '${analytics.pendingCount} participants are still absent, which affects unused supplies and transport plans.',
            '${analytics.missingAssignmentCount} checked-in participants still need room or group follow-up.',
          ]),
        ],
      ),
      const SizedBox(height: 12),
      _buildMetricGrid([
        _MetricCardData(
          label: 'Confirmed Headcount',
          value: '${analytics.checkedInCount}',
          helper: 'Current on-site count for supplies',
          icon: Icons.groups_2_outlined,
          color: FSYScannerApp.accentGreen,
        ),
        _MetricCardData(
          label: 'No-Shows',
          value: '${analytics.pendingCount}',
          helper: 'Still not checked in',
          icon: Icons.person_off_outlined,
          color: FSYScannerApp.primaryBlue,
        ),
        _MetricCardData(
          label: 'Missing Room',
          value: '${analytics.checkedInMissingRoomCount}',
          helper: 'Attendees who still need lodging placement',
          icon: Icons.location_off_outlined,
          color: FSYScannerApp.accentGold,
        ),
        _MetricCardData(
          label: 'Missing Group',
          value: '${analytics.checkedInMissingTableCount}',
          helper: 'Attendees who still need activity grouping',
          icon: Icons.grid_off_outlined,
          color: Colors.orangeAccent,
        ),
      ]),
      const SizedBox(height: 12),
      _buildBreakdownCard(
        title: 'T-Shirt Size Breakdown',
        subtitle:
            'Use this to order or stage shirt sizes in the language logistics needs.',
        rows: analytics.tshirtRows,
        pageKey: 'log_tshirt',
      ),
      const SizedBox(height: 12),
      _buildBreakdownCard(
        title: 'Participants By Stake',
        subtitle: 'Helpful when transport or movement is grouped by stake.',
        rows: analytics.stakeRows,
        pageKey: 'log_stake',
      ),
      const SizedBox(height: 12),
      _buildBreakdownCard(
        title: 'Participants By Ward',
        subtitle:
            'Useful for transport grouping, supplies handoff, and localized follow-up.',
        rows: analytics.wardRows,
        maxItems: 19,
        pageKey: 'log_ward',
      ),
      const SizedBox(height: 12),
      _buildBreakdownCard(
        title: 'Gender Breakdown',
        subtitle:
            'For gender-specific supply planning when it is operationally relevant.',
        rows: analytics.genderRows,
        pageKey: 'log_gender',
      ),
      const SizedBox(height: 12),
      _buildParticipantListCard(
        title: 'Participants Missing Room Assignment',
        subtitle:
            'These attendees are already on site but still need a room assignment for logistics follow-through.',
        items: analytics.missingRoomAlerts,
        emptyMessage: 'No checked-in participant is missing a room assignment.',
        pageKey: 'log_missing_room',
      ),
      const SizedBox(height: 12),
      _buildParticipantListCard(
        title: 'Participants Missing Group Assignment',
        subtitle:
            'These attendees are already on site but still need a group assignment for movement and coordination.',
        items: analytics.missingTableAlerts,
        emptyMessage:
            'No checked-in participant is missing a group assignment.',
        pageKey: 'log_missing_group',
      ),
      const SizedBox(height: 12),
      _buildBreakdownCard(
        title: 'Room Assignments',
        subtitle:
            'Shows room concentration so logistics can see where people are being placed.',
        rows: analytics.roomRows,
        pageKey: 'log_rooms',
      ),
      const SizedBox(height: 12),
      _buildBreakdownCard(
        title: 'Group Assignments',
        subtitle:
            'Useful when logistics also supports group-based group movement or materials distribution.',
        rows: analytics.tableRows,
        pageKey: 'log_tables',
      ),
      const SizedBox(height: 12),
      _buildParticipantListCard(
        title: 'No-Shows',
        subtitle:
            'These participants have not arrived yet and may affect transport loads or unused materials.',
        items: analytics.noShowAlerts,
        emptyMessage: 'No no-shows are currently recorded.',
        pageKey: 'log_no_show',
      ),
      const SizedBox(height: 12),
      // NEW: Groups ready for hotel check-in card
      _buildGroupsReadyForCheckInCard(),
    ];
  }

  // ---------------------------------------------------------------------------
  // NEW CARD: Groups Ready for Hotel Check‑in (Logistics view)
  // ---------------------------------------------------------------------------
  Widget _buildGroupsReadyForCheckInCard() {
    // Compute groups that are fully ready: all assigned participants are fully verified.
    final Map<String, List<String>> groupRooms = {};
    final Map<String, int> groupAssigned = {};
    final Map<String, int> groupFullyReady = {};
    for (final p in _participants) {
      final group = p.tableNumber?.trim();
      if (group == null || group.isEmpty) continue;
      groupAssigned[group] = (groupAssigned[group] ?? 0) + 1;
      if (p.isFullyVerified) {
        groupFullyReady[group] = (groupFullyReady[group] ?? 0) + 1;
        if (p.roomNumber != null && p.roomNumber!.trim().isNotEmpty) {
          groupRooms.putIfAbsent(group, () => <String>[]);
          if (!groupRooms[group]!.contains(p.roomNumber!.trim())) {
            groupRooms[group]!.add(p.roomNumber!.trim());
          }
        }
      }
    }

    final readyGroups = <String>[];
    for (final entry in groupAssigned.entries) {
      if ((groupFullyReady[entry.key] ?? 0) == entry.value) {
        readyGroups.add(entry.key);
      }
    }
    readyGroups.sort((a, b) =>
        int.tryParse(a)?.compareTo(int.tryParse(b) ?? 0) ?? a.compareTo(b));

    if (readyGroups.isEmpty) {
      return const SizedBox.shrink();
    }

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side:
            BorderSide(color: FSYScannerApp.primaryBlue.withValues(alpha: 0.3)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.meeting_room,
                    size: 20, color: FSYScannerApp.primaryBlue),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Groups Ready for Hotel Check‑in',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            ...readyGroups.map(
              (group) {
                final rooms = groupRooms[group] ?? [];
                return Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Padding(
                        padding: EdgeInsets.only(top: 6),
                        child: Icon(Icons.circle, size: 6, color: Colors.grey),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Group $group',
                              style:
                                  const TextStyle(fontWeight: FontWeight.w700),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 4),
                            if (rooms.isNotEmpty)
                              Wrap(
                                spacing: 6,
                                runSpacing: 4,
                                children: rooms
                                    .map(
                                      (room) => Container(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 8, vertical: 4),
                                        decoration: BoxDecoration(
                                          color: FSYScannerApp.primaryBlue
                                              .withValues(alpha: 0.1),
                                          borderRadius:
                                              BorderRadius.circular(12),
                                        ),
                                        child: Text(
                                          'Room $room',
                                          style: const TextStyle(
                                            fontSize: 12,
                                            fontWeight: FontWeight.w600,
                                            color: FSYScannerApp.primaryBlue,
                                          ),
                                        ),
                                      ),
                                    )
                                    .toList(),
                              )
                            else
                              Text(
                                'No rooms assigned',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.grey.shade600,
                                  fontStyle: FontStyle.italic,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildFoodView(AppState appState, _AnalyticsSnapshot analytics,
      _AnalyticsSnapshot? previous) {
    return [
      _buildBriefingCard(
        title: 'Food',
        subtitle:
            'Use this for meal counts and restrictions. The wording here aims to help the food team act, not interpret generic charts.',
        children: [
          _buildSentenceList([
            '${analytics.checkedInCount} participants are currently on site and are the best available estimate for immediate plates needed.',
            '${analytics.dietAttentionOnSiteCount} checked-in participants are marked for food attention.',
            '${analytics.foodOnlyOnSiteCount} are food-only restrictions and ${analytics.medicalAndFoodOnSiteCount} are shared with the medical team.',
          ]),
        ],
      ),
      const SizedBox(height: 12),
      _buildMetricGrid([
        _MetricCardData(
          label: 'Plates To Prepare',
          value: '${analytics.checkedInCount}',
          helper: 'Best current count from checked-in participants',
          icon: Icons.restaurant_outlined,
          color: FSYScannerApp.primaryBlue,
        ),
        _MetricCardData(
          label: 'Restrictions',
          value: '${analytics.dietAttentionOnSiteCount}',
          helper:
              '${analytics.foodOnlyOnSiteCount} food-only, ${analytics.medicalAndFoodOnSiteCount} shared with medical',
          icon: Icons.no_meals_outlined,
          color: FSYScannerApp.accentGold,
        ),
        _MetricCardData(
          label: 'No Restrictions',
          value: '${analytics.noRestrictionOnSiteCount}',
          helper: 'Checked-in participants with none/nil/no recorded',
          icon: Icons.check_circle_outline,
          color: FSYScannerApp.accentGreen,
        ),
        _MetricCardData(
          label: 'Meal Groups',
          value: '${analytics.activeTableCount}',
          helper: 'Assigned groups available for group serving',
          icon: Icons.table_restaurant_outlined,
          color: Colors.redAccent,
        ),
      ]),
      const SizedBox(height: 12),
      _buildParticipantListCard(
        title: 'Restriction List',
        subtitle:
            'Review these participants first when meals have allergy, restriction, or diet concerns.',
        items: analytics.foodAttentionAlerts,
        emptyMessage:
            'No checked-in participant is currently marked for food attention.',
        pageKey: 'food_restriction_list',
      ),
      const SizedBox(height: 12),
      _buildBreakdownCard(
        title: 'Restriction Categories',
        subtitle:
            'Counts grouped from the structured medical/food category plus available detail notes.',
        rows: analytics.foodCategoryRows,
        pageKey: 'food_categories',
      ),
      const SizedBox(height: 12),
      _buildBreakdownCard(
        title: 'Meal Groups By Group',
        subtitle:
            'Use assigned groups when meal release or seating is organized by group.',
        rows: analytics.tablePresenceRows,
        pageKey: 'food_table_presence',
      ),
      const SizedBox(height: 12),
      _buildBreakdownCard(
        title: 'Serving Load By Stake',
        subtitle: 'Helpful when meal flow is coordinated at a group level.',
        rows: analytics.stakeRows,
        pageKey: 'food_stake',
      ),
      const SizedBox(height: 12),
    ];
  }

  List<Widget> _buildMedicalView(
    AppState appState,
    _AnalyticsSnapshot analytics,
    _AnalyticsSnapshot? previous,
  ) {
    return [
      _buildBriefingCard(
        title: 'Medical / Health',
        subtitle:
            'Use this for health awareness, first-aid readiness, and follow-up on participants who may need extra attention during the event.',
        children: [
          _buildSentenceList([
            '${analytics.checkedInMedicalFlagCount} checked-in participants have medical information recorded.',
            '${analytics.urgentMedicalOnSiteCount} look like priority review cases and ${analytics.generalMedicalAwarenessOnSiteCount} are general awareness cases.',
            '${analytics.medicalNotArrivedCount} participants with medical notes have not arrived yet and may need welfare follow-up.',
            '${analytics.medicalOnlyOnSiteCount} are medical-only cases and ${analytics.medicalAndFoodOnSiteCount} overlap with food follow-up.',
          ]),
        ],
      ),
      const SizedBox(height: 12),
      _buildMetricGrid([
        _MetricCardData(
          label: 'Medical Flags',
          value: '${analytics.totalMedicalFlagCount}',
          helper: 'Total in roster',
          icon: Icons.medical_services_outlined,
          color: Colors.redAccent,
        ),
        _MetricCardData(
          label: 'Need Attention',
          value: '${analytics.urgentMedicalOnSiteCount}',
          helper: 'Priority review from stronger detail keywords',
          icon: Icons.priority_high_outlined,
          color: FSYScannerApp.primaryBlue,
        ),
        _MetricCardData(
          label: 'General Awareness',
          value: '${analytics.generalMedicalAwarenessOnSiteCount}',
          helper: 'Medical notes that still need awareness',
          icon: Icons.visibility_outlined,
          color: FSYScannerApp.accentGold,
        ),
        _MetricCardData(
          label: 'Not Arrived',
          value: '${analytics.medicalNotArrivedCount}',
          helper: 'Medical-flagged participants still absent',
          icon: Icons.person_search_outlined,
          color: Colors.orangeAccent,
        ),
      ]),
      const SizedBox(height: 12),
      _buildParticipantListCard(
        title: 'Urgent-Looking Medical Cases On Site',
        subtitle:
            'These participants matched stronger medical detail keywords and should be reviewed first by the health team.',
        items: analytics.urgentMedicalAlerts,
        emptyMessage:
            'No checked-in participant currently matches urgent medical attention signals.',
        pageKey: 'med_urgent',
      ),
      const SizedBox(height: 12),
      _buildParticipantListCard(
        title: 'Participants With Medical Notes On Site',
        subtitle:
            'Use this list for general awareness, follow-up, and local coordination.',
        items: analytics.medicalOnSiteAlerts,
        emptyMessage: 'No checked-in participant currently has medical notes.',
        pageKey: 'med_on_site',
      ),
      const SizedBox(height: 12),
      _buildParticipantListCard(
        title: 'Participants With Medical Notes Not Yet Arrived',
        subtitle:
            'These participants may need welfare follow-up if arrival is delayed.',
        items: analytics.medicalNotArrivedAlerts,
        emptyMessage:
            'Every participant with medical notes has already arrived.',
        pageKey: 'med_not_arrived',
      ),
      const SizedBox(height: 12),
      _buildBreakdownCard(
        title: 'Medical Categories',
        subtitle:
            'A practical grouping using the structured medical category and the available note detail.',
        rows: analytics.medicalCategoryRows,
        pageKey: 'med_categories',
      ),
      const SizedBox(height: 12),
      _buildParticipantListCard(
        title: 'Medical Participants Without Room or Group',
        subtitle:
            'These on-site participants have medical flags but are harder to locate because room or group assignment is missing.',
        items: analytics.medicalWithoutLocationAlerts,
        emptyMessage:
            'All on-site medical-flagged participants currently have a room and group assigned.',
        pageKey: 'med_without_location',
      ),
      const SizedBox(height: 12),
      _buildGapNoteCard(
        title: 'Current Data Gap',
        gaps: [
          'Emergency contact awareness cannot be flagged yet because the participant data model does not include emergency contact details.',
        ],
      ),
    ];
  }

  List<Widget> _buildAdminView(AppState appState, _AnalyticsSnapshot analytics,
      _AnalyticsSnapshot? previous) {
    return [
      _buildBriefingCard(
        title: 'Admin',
        subtitle:
            'Use this for event oversight and leadership reporting. Keep it headline-driven and action-oriented.',
        children: [
          _buildSentenceList([
            '${analytics.checkedInCount} of ${analytics.totalParticipants} participants have arrived so far.',
            '${analytics.approvedCount} are approved and ${analytics.notApprovedCount} still need roster follow-up.',
            '${analytics.exceptionCount} active issues need oversight across registration, logistics, medical, or device operations.',
            _formatLastSync(appState.lastSyncedAt),
          ]),
        ],
      ),
      const SizedBox(height: 12),
      _buildProgressCard(
        title: 'Event Progress',
        headline:
            '${analytics.checkedInCount} of ${analytics.totalParticipants} participants have arrived',
        current: analytics.checkedInCount,
        total: analytics.totalParticipants,
        subtitle:
            '${analytics.fullyVerifiedCount} are fully complete, ${analytics.pendingCount} are still absent.',
      ),
      const SizedBox(height: 12),
      _buildCriticalBlockersCard(analytics),
      const SizedBox(height: 12),
      _buildMetricGrid([
        _MetricCardData(
          label: 'Approved',
          value: '${analytics.approvedCount}',
          helper: '${analytics.notApprovedCount} still not approved',
          icon: Icons.verified_outlined,
          color: FSYScannerApp.accentGreen,
          delta: previous == null
              ? null
              : analytics.approvedCount - previous.approvedCount,
        ),
        _MetricCardData(
          label: 'Sync Queue',
          value: '${analytics.pendingSyncTaskCount}',
          helper: '${analytics.failedSyncTaskCount} failed tasks need review',
          icon: Icons.sync_problem_outlined,
          color: FSYScannerApp.accentGold,
          delta: previous == null
              ? null
              : analytics.pendingSyncTaskCount - previous.pendingSyncTaskCount,
        ),
        _MetricCardData(
          label: 'Top Scanner',
          value: '${analytics.topCheckInDeviceCount}',
          helper: analytics.topCheckInDeviceLabel,
          icon: Icons.qr_code_scanner_outlined,
          color: FSYScannerApp.primaryBlue,
        ),
        _MetricCardData(
          label: 'Open Issues',
          value: '${analytics.exceptionCount}',
          helper: 'Cross-committee issues requiring attention',
          icon: Icons.crisis_alert_outlined,
          color: Colors.redAccent,
          delta: previous == null
              ? null
              : analytics.exceptionCount - previous.exceptionCount,
        ),
      ]),
      const SizedBox(height: 12),
      _buildAttentionCard(
        title: 'Admin Oversight Priorities',
        items: [
          _AttentionItem(
            label: 'Registration completion gap',
            value:
                '${analytics.partiallyVerifiedCount} partial, ${analytics.pendingCount} pending, ${analytics.notApprovedCount} still needing roster follow-up',
          ),
          _AttentionItem(
            label: 'Assignment follow-up',
            value:
                '${analytics.checkedInMissingRoomCount} missing room and ${analytics.checkedInMissingTableCount} missing group among attendees on site',
          ),
          _AttentionItem(
            label: 'Health awareness',
            value:
                '${analytics.checkedInMedicalFlagCount} medical-flagged attendees already on site',
          ),
          _AttentionItem(
            label: 'Local device risk',
            value:
                '${analytics.staleQueuedPrintCount} stale queued print jobs, ${analytics.printFailuresLastHour} print failures in the last hour, ${analytics.failedSyncTaskCount} failed sync tasks',
          ),
        ],
      ),
      const SizedBox(height: 12),
      _buildBreakdownCard(
        title: 'Check-In Timeline',
        subtitle:
            'Headline timeline of check-in movement for leadership updates.',
        rows: analytics.hourlyCheckInRows,
        pageKey: 'admin_hourly_checkin',
      ),
      const SizedBox(height: 12),
      _buildBreakdownCard(
        title: 'Approval Status',
        subtitle:
            'Useful when leadership needs a quick view of readiness before arrival and check-in are complete.',
        rows: analytics.statusRows,
        pageKey: 'admin_status',
      ),
      const SizedBox(height: 12),
      _buildBreakdownCard(
        title: 'Registration Source',
        subtitle:
            'Shows how many participants are online-only, printed-only, or have both sources recorded.',
        rows: analytics.registrationSourceRows,
        pageKey: 'admin_reg_source',
      ),
      const SizedBox(height: 12),
      _buildBreakdownCard(
        title: 'Attendance By Stake',
        subtitle:
            'Useful for seeing which groups have already arrived and how heavily each stake is represented on site.',
        rows: analytics.stakeRows,
        pageKey: 'admin_stake',
      ),
      const SizedBox(height: 12),
      _buildBreakdownCard(
        title: 'Attendance By Ward',
        subtitle:
            'Helpful for oversight when specific wards need additional follow-up or coordination.',
        rows: analytics.wardRows,
        maxItems: 19,
        pageKey: 'admin_ward',
      ),
      const SizedBox(height: 12),
      _buildBreakdownCard(
        title: 'Device Activity Summary',
        subtitle:
            'Shows which scanners have recorded the most check-ins in the latest data sample.',
        rows: analytics.deviceCheckInRows,
        pageKey: 'admin_device_activity',
      ),
      const SizedBox(height: 12),
      _buildParticipantListCard(
        title: 'No-Shows List',
        subtitle:
            'These participants are still absent and may need follow-up before the reporting deadline.',
        items: analytics.noShowAlerts,
        emptyMessage: 'No no-shows are currently recorded.',
        pageKey: 'admin_no_show',
      ),
      const SizedBox(height: 12),
      _buildDeviceScopeCard(appState, analytics),
    ];
  }

  List<Widget> _buildActivitiesView(
    AppState appState,
    _AnalyticsSnapshot analytics,
    _AnalyticsSnapshot? previous,
  ) {
    return [
      _buildBriefingCard(
        title: 'Operations / Activities',
        subtitle:
            'Use this for groups, grouping, and who is physically present and ready for activities.',
        children: [
          _buildSentenceList([
            '${analytics.checkedInCount} participants are physically present on site.',
            '${analytics.fullyVerifiedCount} are fully cleared and easiest to move into classes or activities.',
            '${analytics.checkedInMissingTableCount} checked-in participants still need a group assignment.',
          ]),
        ],
      ),
      const SizedBox(height: 12),
      _buildMetricGrid([
        _MetricCardData(
          label: 'Present',
          value: '${analytics.checkedInCount}',
          helper: 'Participants physically on site',
          icon: Icons.how_to_reg_outlined,
          color: FSYScannerApp.primaryBlue,
        ),
        _MetricCardData(
          label: 'Activity Ready',
          value: '${analytics.fullyVerifiedCount}',
          helper: 'Fully verified participants',
          icon: Icons.directions_run_outlined,
          color: FSYScannerApp.accentGreen,
        ),
        _MetricCardData(
          label: 'Groups Ready',
          value: '${analytics.completedTableCount}',
          helper: '${analytics.activeTableCount} active groups total',
          icon: Icons.table_bar_outlined,
          color: FSYScannerApp.primaryBlue,
        ),
        _MetricCardData(
          label: 'No Group',
          value: '${analytics.checkedInMissingTableCount}',
          helper: 'Participants needing activity grouping',
          icon: Icons.grid_off_outlined,
          color: Colors.orangeAccent,
        ),
      ]),
      const SizedBox(height: 12),
      _buildBreakdownCard(
        title: 'Group Assignments',
        subtitle:
            'Group-by-group summary for games, classes, and release sequencing.',
        rows: analytics.tablePresenceRows,
        pageKey: 'act_table_presence',
      ),
      const SizedBox(height: 12),
      _buildBreakdownCard(
        title: 'Group / Stake Breakdown',
        subtitle: 'Useful when forming teams or activity groups by stake.',
        rows: analytics.stakeRows,
        pageKey: 'act_stake',
      ),
      const SizedBox(height: 12),
      _buildBreakdownCard(
        title: 'Gender Mix',
        subtitle:
            'Use only when it is operationally relevant for group balancing or space planning.',
        rows: analytics.genderRows,
        pageKey: 'act_gender',
      ),
      const SizedBox(height: 12),
      _buildParticipantListCard(
        title: 'Participants Without Group Assignment',
        subtitle:
            'These participants are present but still need group placement for activity grouping.',
        items: analytics.missingTableAlerts,
        emptyMessage:
            'Every checked-in participant currently has a group assignment.',
        pageKey: 'act_missing_group',
      ),
    ];
  }

  List<Widget> _buildDevelopersView(
    AppState appState,
    _AnalyticsSnapshot analytics,
    _AnalyticsSnapshot? previous,
  ) {
    return [
      _buildBriefingCard(
        title: 'Developers',
        subtitle:
            'Use this for software, sync, printing, and raw device health. This view stays technical on purpose.',
        children: [
          _buildSentenceList([
            'Participant counts remain event-wide from the latest synced roster, but printer queue and sync backlog in this view are local to this device.',
            '${analytics.totalPrintAttemptCount} print attempts are available in the current local history sample.',
            'Last roster pull: ${_formatOptionalTimestamp(_lastPulledAt)}.',
          ]),
        ],
      ),
      const SizedBox(height: 12),
      _buildMetricGrid([
        _MetricCardData(
          label: 'Pending Sync',
          value: '${analytics.pendingSyncTaskCount}',
          helper: '${analytics.retryingSyncTaskCount} already retried',
          icon: Icons.sync_outlined,
          color: FSYScannerApp.primaryBlue,
        ),
        _MetricCardData(
          label: 'Failed Sync',
          value: '${analytics.failedSyncTaskCount}',
          helper: '${analytics.syncErrorSampleCount} tasks have error text',
          icon: Icons.sync_problem_outlined,
          color: FSYScannerApp.accentGold,
        ),
        _MetricCardData(
          label: 'Queued Prints',
          value: '${analytics.queuedPrintCount}',
          helper:
              '${analytics.staleQueuedPrintCount} stale, ${analytics.pendingConfirmationCount} awaiting confirmation',
          icon: Icons.local_printshop_outlined,
          color: Colors.orangeAccent,
        ),
        _MetricCardData(
          label: 'Roster Records',
          value: '${analytics.totalParticipants}',
          helper:
              '${analytics.uniqueRegisteredDeviceCount} device IDs have recorded check-ins',
          icon: Icons.storage_outlined,
          color: FSYScannerApp.accentGreen,
        ),
      ]),
      const SizedBox(height: 12),
      _buildAttentionCard(
        title: 'Local Device Diagnostics',
        items: [
          _AttentionItem(
            label: 'App build',
            value:
                'Version $_appVersion ($_appBuildNumber), database version $_dbVersion',
          ),
          _AttentionItem(
            label: 'API and roster refresh',
            value:
                '${_formatLastSync(appState.lastSyncedAt)} Last roster pull ${_formatOptionalTimestamp(_lastPulledAt)}.',
          ),
          _AttentionItem(
            label: 'Printer state',
            value: appState.printerStatusMessage,
          ),
          _AttentionItem(
            label: 'Oldest queued print age',
            value: analytics.oldestQueuedPrintAgeMinutes == 0
                ? 'No queued print jobs'
                : '${analytics.oldestQueuedPrintAgeMinutes.toStringAsFixed(1)} minutes',
          ),
          _AttentionItem(
            label: 'Average attempt duration',
            value:
                '${analytics.averagePrintAttemptSeconds.toStringAsFixed(1)} seconds',
          ),
          _AttentionItem(
            label: 'Recent sync health',
            value:
                '${analytics.pendingSyncTaskCount} pending tasks, ${analytics.failedSyncTaskCount} failed tasks, ${analytics.syncErrorSampleCount} tasks with last_error text',
          ),
          _AttentionItem(
            label: 'Oldest pending sync task age',
            value: analytics.oldestSyncTaskAgeMinutes == 0
                ? 'No pending sync tasks'
                : '${analytics.oldestSyncTaskAgeMinutes.toStringAsFixed(1)} minutes old — tasks stuck this long may need manual review.',
          ),
          _AttentionItem(
            label: 'Print success rate trend',
            value: analytics.printSuccessRateTrendLabel,
          ),
        ],
      ),
      const SizedBox(height: 12),
      _buildBreakdownCard(
        title: 'Device IDs And Check-In Counts',
        subtitle:
            'Shows which scanner IDs have been associated with completed check-ins.',
        rows: analytics.deviceCheckInRows,
        pageKey: 'dev_device_ids',
      ),
      const SizedBox(height: 12),
      _buildBreakdownCard(
        title: 'Pending Sync Tasks By Type',
        subtitle: 'Shows which local writes are waiting to leave the device.',
        rows: analytics.syncTypeRows,
        pageKey: 'dev_sync_types',
      ),
      const SizedBox(height: 12),
      _buildBreakdownCard(
        title: 'Recent Print Failure Reasons',
        subtitle:
            'Grouped from recent failed print attempts to make recurring hardware or transport issues easier to spot.',
        rows: analytics.printFailureReasonRows,
        pageKey: 'dev_print_failures',
      ),
      const SizedBox(height: 12),
      _buildParticipantListCard(
        title: 'Recent Sync Or Print Exceptions',
        subtitle:
            'Quick local exception sample for technical triage on this device.',
        items: analytics.technicalExceptionAlerts,
        emptyMessage:
            'No recent local exception sample is currently available.',
        pageKey: 'dev_exceptions',
      ),
      const SizedBox(height: 12),
      _buildGapNoteCard(
        title: 'Current Data Gap',
        gaps: [
          'Per-device last successful sync timestamps are not stored yet, so this view uses the latest app-wide sync time and roster-pull time.',
        ],
      ),
      const SizedBox(height: 12),
      _buildDeviceScopeCard(appState, analytics),
    ];
  }

  Widget _buildPendingSummaryConfirmationCard() {
    final pending = _pendingSummaryConfirmation;
    if (pending == null) {
      return const SizedBox.shrink();
    }
    return Card(
      color: Colors.blueGrey.withValues(alpha: 0.08),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Pending Summary Confirmation',
              style: TextStyle(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 6),
            Text(
              'The last printed analytics summary "${pending.title}" still needs confirmation before it should be treated as successful.',
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: () => _resolvePendingSummaryConfirmation(true),
                  icon: const Icon(Icons.check_circle),
                  label: const Text('Confirm Printed'),
                ),
                OutlinedButton.icon(
                  onPressed: () => _resolvePendingSummaryConfirmation(false),
                  icon: const Icon(Icons.cancel_outlined),
                  label: const Text('Not Printed'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBriefingCard({
    required String title,
    required String subtitle,
    required List<Widget> children,
  }) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 6),
            Text(subtitle, style: TextStyle(color: Colors.grey[800])),
            const SizedBox(height: 12),
            ...children,
          ],
        ),
      ),
    );
  }

  Widget _buildSentenceList(List<String> lines) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: lines
          .map(
            (line) => Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(top: 4),
                    child: Icon(Icons.circle, size: 7),
                  ),
                  const SizedBox(width: 8),
                  Expanded(child: Text(line)),
                ],
              ),
            ),
          )
          .toList(),
    );
  }

  Widget _buildProgressCard({
    required String title,
    required String headline,
    required int current,
    required int total,
    required String subtitle,
  }) {
    final progress = total == 0 ? 0.0 : current / total;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            Text(
              headline,
              style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 10),
            LinearProgressIndicator(
              value: progress,
              minHeight: 10,
              borderRadius: BorderRadius.circular(999),
            ),
            const SizedBox(height: 8),
            Text(subtitle, style: TextStyle(color: Colors.grey[700])),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionSummaryCard({
    required String title,
    required String subtitle,
    required List<String> lines,
  }) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 6),
            Text(subtitle, style: TextStyle(color: Colors.grey[700])),
            const SizedBox(height: 12),
            _buildSentenceList(lines),
          ],
        ),
      ),
    );
  }

  Widget _buildMetricGrid(List<_MetricCardData> metrics) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final cardWidth = constraints.maxWidth < 500
            ? constraints.maxWidth
            : (constraints.maxWidth - 12) / 2;
        return Wrap(
          spacing: 12,
          runSpacing: 12,
          children: metrics
              .map(
                (metric) =>
                    SizedBox(width: cardWidth, child: _buildMetricCard(metric)),
              )
              .toList(),
        );
      },
    );
  }

  Widget _buildMetricCard(_MetricCardData data) {
    final hasDelta = data.delta != null && data.delta != 0;
    final deltaPositive = (data.delta ?? 0) > 0;
    final deltaLabel = deltaPositive ? '+${data.delta}' : '${data.delta}';
    final deltaColor =
        deltaPositive ? FSYScannerApp.accentGreen : Colors.redAccent;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(data.icon, color: data.color, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    data.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  data.value,
                  style: const TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                if (hasDelta) ...[
                  const SizedBox(width: 8),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 7, vertical: 3),
                      decoration: BoxDecoration(
                        color: deltaColor.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        deltaLabel,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                          color: deltaColor,
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 6),
            Text(
              data.helper,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: Colors.grey[700]),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAttentionCard({
    required String title,
    required List<_AttentionItem> items,
  }) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.orange.shade200, width: 1.5),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.warning_amber_rounded,
                    size: 20, color: Colors.orange.shade700),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'Attention',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            ...items.map(
              (item) => Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: Icon(Icons.circle, size: 6, color: Colors.grey),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: RichText(
                        text: TextSpan(
                          style: DefaultTextStyle.of(context)
                              .style
                              .copyWith(height: 1.4),
                          children: [
                            TextSpan(
                              text: '${item.label}: ',
                              style:
                                  const TextStyle(fontWeight: FontWeight.w700),
                            ),
                            TextSpan(text: item.value),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBreakdownCard({
    required String title,
    required String subtitle,
    required List<_BreakdownRow> rows,
    int maxItems = 8,
    required String pageKey,
  }) {
    final totalPages = rows.isEmpty ? 1 : (rows.length / maxItems).ceil();
    // ensure page is valid
    final currentPage = (_breakdownPage[pageKey] ?? 0).clamp(0, totalPages - 1);
    final start = currentPage * maxItems;
    final end = (start + maxItems).clamp(0, rows.length);
    final pageRows = rows.sublist(start, end);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style:
                    const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            const SizedBox(height: 6),
            Text(subtitle,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: Colors.grey[700])),
            const SizedBox(height: 12),
            if (rows.isEmpty)
              Text('No relevant data is available for this view yet.',
                  style: TextStyle(color: Colors.grey[700]))
            else ...[
              ...pageRows.map(_buildBreakdownRow),
              if (totalPages > 1) ...[
                const SizedBox(height: 8),
                _buildPaginationControls(
                  currentPage: currentPage,
                  totalPages: totalPages,
                  onPageChanged: (newPage) {
                    setState(() {
                      _breakdownPage[pageKey] = newPage;
                    });
                  },
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildPaginationControls({
    required int currentPage,
    required int totalPages,
    required ValueChanged<int> onPageChanged,
  }) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        IconButton(
          icon: const Icon(Icons.chevron_left),
          onPressed:
              currentPage > 0 ? () => onPageChanged(currentPage - 1) : null,
        ),
        Text('${currentPage + 1} of $totalPages'),
        IconButton(
          icon: const Icon(Icons.chevron_right),
          onPressed: currentPage < totalPages - 1
              ? () => onPageChanged(currentPage + 1)
              : null,
        ),
      ],
    );
  }

  Widget _buildBreakdownRow(_BreakdownRow row) {
    final hasCurrent = row.current != null && row.total > 0;
    final progress =
        hasCurrent ? (row.current! / row.total).clamp(0.0, 1.0) : 0.0;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  row.label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                row.trailing,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: row.highlightColor,
                ),
              ),
            ],
          ),
          if (hasCurrent) ...[
            const SizedBox(height: 6),
            LinearProgressIndicator(
              value: progress,
              minHeight: 6,
              borderRadius: BorderRadius.circular(999),
              color: row.highlightColor,
              backgroundColor: row.highlightColor.withValues(alpha: 0.15),
            ),
          ],
          const SizedBox(height: 4),
          Text(
            row.caption,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: Colors.grey[700]),
          ),
        ],
      ),
    );
  }

  Widget _buildParticipantListCard({
    required String title,
    required String subtitle,
    required List<_ParticipantAlert> items,
    required String emptyMessage,
    int maxItems = 8,
    required String pageKey,
  }) {
    final totalPages = items.isEmpty ? 1 : (items.length / maxItems).ceil();
    final currentPage =
        (_participantListPage[pageKey] ?? 0).clamp(0, totalPages - 1);
    final start = currentPage * maxItems;
    final end = (start + maxItems).clamp(0, items.length);
    final pageItems = items.sublist(start, end);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style:
                    const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            const SizedBox(height: 6),
            Text(subtitle,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: Colors.grey[700])),
            const SizedBox(height: 12),
            if (items.isEmpty)
              Text(emptyMessage, style: TextStyle(color: Colors.grey[700]))
            else ...[
              ...pageItems.map((item) => Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        CircleAvatar(
                          backgroundColor: item.color.withValues(alpha: 0.12),
                          foregroundColor: item.color,
                          child: Icon(item.icon, size: 12),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                item.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontWeight: FontWeight.w700),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                item.detail,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              if (item.trailing != null) ...[
                                const SizedBox(height: 4),
                                Text(
                                  item.trailing!,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),
                  )),
              if (totalPages > 1) ...[
                const SizedBox(height: 8),
                _buildPaginationControls(
                  currentPage: currentPage,
                  totalPages: totalPages,
                  onPageChanged: (newPage) {
                    setState(() {
                      _participantListPage[pageKey] = newPage;
                    });
                  },
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildCriticalBlockersCard(_AnalyticsSnapshot analytics) {
    final blockers = <String>[];
    if (analytics.checkedInMissingTableCount > 0) {
      blockers.add(
          '${analytics.checkedInMissingTableCount} arrived participants still need a group assignment.');
    }
    if (analytics.checkedInMissingRoomCount > 0) {
      blockers.add(
          '${analytics.checkedInMissingRoomCount} arrived participants still need a room assignment.');
    }
    if (analytics.failedSyncTaskCount > 0) {
      blockers.add(
          '${analytics.failedSyncTaskCount} sync tasks have failed and need review.');
    }
    if (analytics.staleQueuedPrintCount > 0) {
      blockers.add(
          '${analytics.staleQueuedPrintCount} print jobs have been queued for over 10 minutes.');
    }
    if (analytics.urgentMedicalOnSiteCount > 0) {
      blockers.add(
          '${analytics.urgentMedicalOnSiteCount} on-site participants need urgent medical review.');
    }
    if (analytics.medicalWithoutLocationCount > 0) {
      blockers.add(
          '${analytics.medicalWithoutLocationCount} medical-flagged participants have no room or group assigned.');
    }
    if (analytics.partiallyVerifiedCount > 0) {
      blockers.add(
          '${analytics.partiallyVerifiedCount} participants are partially registered and still not fully complete.');
    }
    if (blockers.isEmpty) {
      return Card(
        color: FSYScannerApp.accentGreen.withValues(alpha: 0.08),
        child: const Padding(
          padding: EdgeInsets.all(16),
          child: Row(
            children: [
              Icon(Icons.check_circle_outline,
                  color: FSYScannerApp.accentGreen),
              SizedBox(width: 12),
              Expanded(
                child: Text(
                  'No critical blockers right now.',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
        ),
      );
    }
    return Card(
      color: Colors.red.withValues(alpha: 0.06),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.crisis_alert_outlined,
                    color: Colors.redAccent),
                const SizedBox(width: 8),
                Text(
                  '${blockers.length} Critical Blocker${blockers.length == 1 ? '' : 's'}',
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w800),
                ),
              ],
            ),
            const SizedBox(height: 12),
            ...blockers.map(
              (b) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Padding(
                      padding: EdgeInsets.only(top: 4),
                      child: Icon(Icons.error_outline,
                          size: 14, color: Colors.redAccent),
                    ),
                    const SizedBox(width: 8),
                    Expanded(child: Text(b)),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGapNoteCard({
    required String title,
    required List<String> gaps,
  }) {
    return Card(
      color: Colors.blueGrey.withValues(alpha: 0.06),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            ...gaps.map(
              (gap) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Padding(
                      padding: EdgeInsets.only(top: 4),
                      child: Icon(Icons.info_outline, size: 16),
                    ),
                    const SizedBox(width: 8),
                    Expanded(child: Text(gap)),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDeviceScopeCard(
    AppState appState,
    _AnalyticsSnapshot analytics,
  ) {
    return Card(
      color: Colors.blueGrey.withValues(alpha: 0.05),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Data Scope For This View',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 10),
            Text(
              'Event-wide data: participant attendance, verification, wards, stakes, rooms, groups, gender, age, and note-derived welfare groupings use the latest synced roster across devices.',
              style: TextStyle(color: Colors.grey[800]),
            ),
            const SizedBox(height: 8),
            Text(
              'This device only: printer queue, print attempts, pending summary confirmation, and sync backlog describe only this scanner and its printer.',
              style: TextStyle(color: Colors.grey[800]),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                Text(_formatLastSync(appState.lastSyncedAt)),
                Text('Queued prints: ${analytics.queuedPrintCount}'),
                Text(
                    'Pending confirmations: ${analytics.pendingConfirmationCount}'),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _handleAnalyticsAction(String action) async {
    switch (action) {
      case 'export_summary':
        await _exportSelectedViewSummary();
        break;
      case 'save_pdf_as':
        await _saveSelectedViewPdfAs();
        break;
      case 'export_pdf':
        await _exportSelectedViewPdf();
        break;
      case 'share_pdf':
        await _shareSelectedViewPdf();
        break;
      case 'print_summary':
        await _printSelectedViewSummary();
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
          : 'Used the latest local data because full refresh did not complete.',
    );
  }

  Future<void> _exportSelectedViewSummary() async {
    final appState = context.read<AppState>();
    final analytics = _currentAnalyticsSnapshot();
    final result = await AnalyticsExportService.exportTextReport(
      baseName: _reportBaseName(appState),
      content: _buildBriefingText(appState, analytics),
    );
    if (!mounted) {
      return;
    }
    _showMessage(
      'Selected view exported to ${result.filePath} (${result.byteCount} bytes).',
    );
  }

  Future<void> _exportSelectedViewPdf() async {
    final appState = context.read<AppState>();
    final analytics = _currentAnalyticsSnapshot();
    final title = _buildBriefingTitle(appState);
    final result = await AnalyticsExportService.exportPdfReport(
      baseName: _reportBaseName(appState),
      title: title,
      content: _buildBriefingText(appState, analytics),
    );
    if (!mounted) {
      return;
    }
    _showMessage(
      'Selected view PDF exported to ${result.filePath} (${result.byteCount} bytes).',
    );
  }

  Future<void> _saveSelectedViewPdfAs() async {
    final appState = context.read<AppState>();
    final analytics = _currentAnalyticsSnapshot();
    final title = _buildBriefingTitle(appState);
    final result = await AnalyticsExportService.savePdfReportAs(
      suggestedBaseName: _reportBaseName(appState),
      title: title,
      content: _buildBriefingText(appState, analytics),
    );
    if (!mounted) {
      return;
    }
    if (result == null) {
      _showMessage('Save PDF cancelled.');
      return;
    }
    _showMessage(
      'Selected view PDF saved to ${result.filePath} (${result.byteCount} bytes).',
    );
  }

  Future<void> _shareSelectedViewPdf() async {
    final appState = context.read<AppState>();
    final analytics = _currentAnalyticsSnapshot();
    final title = _buildBriefingTitle(appState);
    await AnalyticsExportService.sharePdfReport(
      title: title,
      content: _buildBriefingText(appState, analytics),
    );
  }

  Future<void> _printSelectedViewSummary() async {
    final appState = context.read<AppState>();
    final analytics = _currentAnalyticsSnapshot();
    var result = await PrinterService.printSummaryReport(
      title: _buildBriefingTitle(appState),
      bodyLines: _buildBriefingLines(appState, analytics),
    );
    if (result.requiresOperatorConfirmation && mounted) {
      result = await _confirmSummaryPrintedOutput();
    }
    await _load(showSpinner: false);
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
          'Did the selected analytics summary actually come out of the printer?',
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

  Future<void> _resolvePendingSummaryConfirmation(bool printed) async {
    final result = printed
        ? await PrinterService.confirmSummaryPrintDelivery()
        : await PrinterService.rejectSummaryPrintDelivery();
    await _load(showSpinner: false);
    if (!mounted) {
      return;
    }
    _showMessage(result.message);
  }

  _AnalyticsSnapshot _currentAnalyticsSnapshot() {
    return _AnalyticsSnapshot.fromData(
      participants: _participants,
      syncTasks: _syncTasks,
      printJobs: _printJobs,
      printAttempts: _printAttempts,
    );
  }

  String _buildBriefingTitle(AppState appState) {
    final eventTitle = appState.eventName.trim().isEmpty
        ? 'FSY Event'
        : appState.eventName.trim();
    return '$eventTitle ${_committeeLabel(_committeeView)}';
  }

  String _reportBaseName(AppState appState) {
    return '${appState.eventName.isEmpty ? 'event' : appState.eventName}_${_committeeViewKey(_committeeView)}_briefing';
  }

  String _buildBriefingText(AppState appState, _AnalyticsSnapshot analytics) {
    return _buildBriefingLines(appState, analytics).join('\n');
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
      '',
    ];

    switch (_committeeView) {
      case _CommitteeView.comprehensiveSummary:
        lines.addAll([
          'Comprehensive summary',
          '- Arrived: ${analytics.checkedInCount} of ${analytics.totalParticipants}',
          '- Fully complete: ${analytics.fullyVerifiedCount}',
          '- Still absent: ${analytics.pendingCount}',
          '- Approved in roster: ${analytics.approvedCount}',
          '- Still needing roster follow-up: ${analytics.notApprovedCount}',
          '- Medical flags on site: ${analytics.checkedInMedicalFlagCount}',
          '- Food restriction review: ${analytics.dietAttentionOnSiteCount}',
          '- Local pending sync tasks: ${analytics.pendingSyncTaskCount}',
          '- Local failed sync tasks: ${analytics.failedSyncTaskCount}',
        ]);
        _appendBreakdown(
            lines, 'Check-in timeline', analytics.hourlyCheckInRows);
        break;
      case _CommitteeView.registration:
        lines.addAll([
          'Registration priorities',
          '- Arrived: ${analytics.checkedInCount} of ${analytics.totalParticipants}',
          '- Check-ins in the last hour: ${analytics.recentHourCount}',
          '- Check-ins in the last 15 minutes: ${analytics.recent15MinuteCount}',
          '- Participants with no QR/check-in yet: ${analytics.pendingCount}',
          '- Partial check-ins still waiting: ${analytics.partiallyVerifiedCount}',
          '- Roster follow-up still needed: ${analytics.notApprovedCount}',
          '- Top scanner: ${analytics.topCheckInDeviceLabel} (${analytics.topCheckInDeviceCount})',
        ]);
        _appendBreakdown(
            lines, 'Check-ins per hour', analytics.hourlyCheckInRows);
        break;
      case _CommitteeView.logistics:
        lines.addAll([
          'Logistics priorities',
          '- Confirmed headcount on site: ${analytics.checkedInCount}',
          '- No-shows: ${analytics.pendingCount}',
          '- Checked-in missing room: ${analytics.checkedInMissingRoomCount}',
          '- Checked-in missing group: ${analytics.checkedInMissingTableCount}',
        ]);
        _appendBreakdown(lines, 'T-shirt sizes', analytics.tshirtRows);
        break;
      case _CommitteeView.food:
        lines.addAll([
          'Food priorities',
          '- Plates to prepare now: ${analytics.checkedInCount}',
          '- Restriction review list: ${analytics.dietAttentionOnSiteCount}',
          '- No restrictions recorded on site: ${analytics.noRestrictionOnSiteCount}',
          '- Food-only restrictions on site: ${analytics.foodOnlyOnSiteCount}',
          '- Shared medical and food cases on site: ${analytics.medicalAndFoodOnSiteCount}',
          '- Group meal groups available: ${analytics.activeTableCount}',
        ]);
        _appendBreakdown(
            lines, 'Food attention categories', analytics.foodCategoryRows);
        break;
      case _CommitteeView.medical:
        lines.addAll([
          'Medical priorities',
          '- Medical flags in roster: ${analytics.totalMedicalFlagCount}',
          '- Need priority review on site: ${analytics.urgentMedicalOnSiteCount}',
          '- General awareness on site: ${analytics.generalMedicalAwarenessOnSiteCount}',
          '- Medical-only cases on site: ${analytics.medicalOnlyOnSiteCount}',
          '- Shared medical and food cases on site: ${analytics.medicalAndFoodOnSiteCount}',
          '- Medical participants not yet arrived: ${analytics.medicalNotArrivedCount}',
          '- Medical cases missing location: ${analytics.medicalWithoutLocationCount}',
        ]);
        _appendBreakdown(
            lines, 'Medical categories', analytics.medicalCategoryRows);
        break;
      case _CommitteeView.admin:
        lines.addAll([
          'Admin priorities',
          '- Arrived: ${analytics.checkedInCount} of ${analytics.totalParticipants}',
          '- Fully complete: ${analytics.fullyVerifiedCount}',
          '- Approved in roster: ${analytics.approvedCount}',
          '- Still needing roster follow-up: ${analytics.notApprovedCount}',
          '- Open issues: ${analytics.exceptionCount}',
          '- Printed receipts: ${analytics.printedCount}',
          '- Local pending sync tasks: ${analytics.pendingSyncTaskCount}',
          '- Local failed sync tasks: ${analytics.failedSyncTaskCount}',
          '- ${_formatLastSync(appState.lastSyncedAt)}',
        ]);
        _appendBreakdown(lines, 'Attendance by stake', analytics.stakeRows);
        break;
      case _CommitteeView.activities:
        lines.addAll([
          'Activities priorities',
          '- Present on site: ${analytics.checkedInCount}',
          '- Fully ready participants: ${analytics.fullyVerifiedCount}',
          '- Groups with assignments: ${analytics.activeTableCount}',
          '- Groups fully ready: ${analytics.completedTableCount}',
          '- Participants without group assignment: ${analytics.checkedInMissingTableCount}',
        ]);
        _appendBreakdown(
            lines, 'Group assignments', analytics.tablePresenceRows);
        break;
      case _CommitteeView.developers:
        lines.addAll([
          'Developer priorities',
          '- Pending sync tasks: ${analytics.pendingSyncTaskCount}',
          '- Failed sync tasks: ${analytics.failedSyncTaskCount}',
          '- Queued prints: ${analytics.queuedPrintCount}',
          '- Print failures in the last hour: ${analytics.printFailuresLastHour}',
          '- App version: $_appVersion ($_appBuildNumber)',
          '- Database version: $_dbVersion',
          '- ${_formatLastSync(appState.lastSyncedAt)}',
        ]);
        _appendBreakdown(lines, 'Device IDs and check-in counts',
            analytics.deviceCheckInRows);
        break;
    }

    return lines;
  }

  void _appendBreakdown(
    List<String> lines,
    String title,
    List<_BreakdownRow> rows,
  ) {
    lines.add('');
    lines.add(title);
    if (rows.isEmpty) {
      lines.add('- No data available');
      return;
    }
    for (final row in rows.take(6)) {
      lines.add('- ${row.label}: ${row.trailing} (${row.caption})');
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  String _viewSubtitle(_AnalyticsSnapshot analytics) {
    switch (_committeeView) {
      case _CommitteeView.comprehensiveSummary:
        return 'Leadership summary with committee headlines, attendance progress, welfare signals, and local device status in one view.';
      case _CommitteeView.registration:
        return '${analytics.checkedInCount} of ${analytics.totalParticipants} participants have arrived so far.';
      case _CommitteeView.logistics:
        return '${analytics.checkedInCount} confirmed on site, with ${analytics.pendingCount} no-shows currently affecting logistics planning.';
      case _CommitteeView.food:
        return '${analytics.dietAttentionOnSiteCount} checked-in participants currently need restriction review before meals are served.';
      case _CommitteeView.medical:
        return '${analytics.checkedInMedicalFlagCount} checked-in participants have medical flags and ${analytics.urgentMedicalOnSiteCount} need priority review.';
      case _CommitteeView.admin:
        return '${analytics.checkedInCount} of ${analytics.totalParticipants} participants have arrived, ${analytics.notApprovedCount} still need roster follow-up, and ${analytics.exceptionCount} issues need oversight.';
      case _CommitteeView.activities:
        return '${analytics.fullyVerifiedCount} participants are fully activity-ready and ${analytics.checkedInMissingTableCount} still need group placement.';
      case _CommitteeView.developers:
        return 'This device currently has ${analytics.pendingSyncTaskCount} pending sync tasks, ${analytics.failedSyncTaskCount} failed tasks, and ${analytics.queuedPrintCount} queued print jobs.';
    }
  }

  String _committeeLabel(_CommitteeView view) {
    switch (view) {
      case _CommitteeView.comprehensiveSummary:
        return 'Comprehensive Summary';
      case _CommitteeView.registration:
        return 'Registration';
      case _CommitteeView.logistics:
        return 'Logistics';
      case _CommitteeView.food:
        return 'Food';
      case _CommitteeView.medical:
        return 'Medical';
      case _CommitteeView.admin:
        return 'Admin';
      case _CommitteeView.activities:
        return 'Activities';
      case _CommitteeView.developers:
        return 'Developers';
    }
  }

  String _committeeViewKey(_CommitteeView view) {
    return view.name;
  }

  String _formatLastSync(DateTime? syncedAt) {
    if (syncedAt == null) {
      return 'No successful sync has been recorded yet.';
    }
    return 'Last successful sync: ${DateFormat('dd MMM h:mm a').format(syncedAt)}.';
  }

  String _formatOptionalTimestamp(int? timestamp) {
    if (timestamp == null || timestamp <= 0) {
      return 'Unknown';
    }
    return DateFormat(
      'dd MMM yyyy h:mm a',
    ).format(DateTime.fromMillisecondsSinceEpoch(timestamp));
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
}

// ---------------------------------------------------------------------------
// Helper model classes
// ---------------------------------------------------------------------------

class _AnalyticsSnapshot {
  final int totalParticipants;
  final int checkedInCount;
  final int fullyVerifiedCount;
  final int partiallyVerifiedCount;
  final int pendingCount;
  final int printedCount;
  final int notPrintedCount;
  final int recent15MinuteCount;
  final int recentHourCount;
  final int totalMedicalFlagCount;
  final int checkedInMedicalFlagCount;
  final int dietAttentionOnSiteCount;
  final int noRestrictionOnSiteCount;
  final int urgentMedicalOnSiteCount;
  final int generalMedicalAwarenessOnSiteCount;
  final int medicalNotArrivedCount;
  final int medicalWithoutLocationCount;
  final int checkedInMissingRoomCount;
  final int checkedInMissingTableCount;
  final int missingAssignmentCount;
  final int activeRoomCount;
  final int completedRoomCount;
  final int activeTableCount;
  final int completedTableCount;
  final int queuedPrintCount;
  final int staleQueuedPrintCount;
  final int pendingConfirmationCount;
  final int pendingSyncTaskCount;
  final int failedSyncTaskCount;
  final int retryingSyncTaskCount;
  final int approvedCount;
  final int notApprovedCount;
  final int foodOnlyOnSiteCount;
  final int medicalOnlyOnSiteCount;
  final int medicalAndFoodOnSiteCount;
  final int exceptionCount;
  final int totalPrintAttemptCount;
  final int printFailuresLastHour;
  final int syncErrorSampleCount;
  final int uniqueRegisteredDeviceCount;
  final String topCheckInDeviceLabel;
  final int topCheckInDeviceCount;
  final double liveAttendanceRate;
  final double fullVerificationRate;
  final double printSuccessRate;
  final double retrySuccessRate;
  final double oldestQueuedPrintAgeMinutes;
  final double averagePrintAttemptSeconds;
  final List<_BreakdownRow> stakeRows;
  final List<_BreakdownRow> wardRows;
  final List<_BreakdownRow> roomRows;
  final List<_BreakdownRow> tableRows;
  final List<_BreakdownRow> tablePresenceRows;
  final List<_BreakdownRow> locationReadinessRows;
  final List<_BreakdownRow> tshirtRows;
  final List<_BreakdownRow> deviceCheckInRows;
  final List<_BreakdownRow> hourlyCheckInRows;
  final List<_BreakdownRow> peakCheckInRows;
  final List<_BreakdownRow> ageRows;
  final List<_BreakdownRow> genderRows;
  final List<_BreakdownRow> registrationSourceRows;
  final List<_BreakdownRow> signedByRows;
  final List<_BreakdownRow> statusRows;
  final List<_BreakdownRow> medicalCategoryRows;
  final List<_BreakdownRow> foodCategoryRows;
  final List<_BreakdownRow> syncTypeRows;
  final List<_BreakdownRow> printFailureReasonRows;
  final List<_ParticipantAlert> partialParticipantAlerts;
  final List<_ParticipantAlert> noShowAlerts;
  final List<_ParticipantAlert> missingRoomAlerts;
  final List<_ParticipantAlert> missingTableAlerts;
  final List<_ParticipantAlert> foodAttentionAlerts;
  final List<_ParticipantAlert> urgentMedicalAlerts;
  final List<_ParticipantAlert> medicalOnSiteAlerts;
  final List<_ParticipantAlert> medicalNotArrivedAlerts;
  final List<_ParticipantAlert> technicalExceptionAlerts;
  final String estimatedCompletionLabel;
  final int recentVelocity;
  final int previousVelocity;
  final String velocityShortLabel;
  final String velocityTrendLabel;
  final List<_ParticipantAlert> medicalWithoutLocationAlerts;
  final double oldestSyncTaskAgeMinutes;
  final double printSuccessRateLastHour;
  final double printSuccessRatePreviousHour;
  final String printSuccessRateTrendLabel;

  const _AnalyticsSnapshot({
    required this.totalParticipants,
    required this.checkedInCount,
    required this.fullyVerifiedCount,
    required this.partiallyVerifiedCount,
    required this.pendingCount,
    required this.printedCount,
    required this.notPrintedCount,
    required this.recent15MinuteCount,
    required this.recentHourCount,
    required this.totalMedicalFlagCount,
    required this.checkedInMedicalFlagCount,
    required this.dietAttentionOnSiteCount,
    required this.noRestrictionOnSiteCount,
    required this.urgentMedicalOnSiteCount,
    required this.generalMedicalAwarenessOnSiteCount,
    required this.medicalNotArrivedCount,
    required this.medicalWithoutLocationCount,
    required this.checkedInMissingRoomCount,
    required this.checkedInMissingTableCount,
    required this.missingAssignmentCount,
    required this.activeRoomCount,
    required this.completedRoomCount,
    required this.activeTableCount,
    required this.completedTableCount,
    required this.queuedPrintCount,
    required this.staleQueuedPrintCount,
    required this.pendingConfirmationCount,
    required this.pendingSyncTaskCount,
    required this.failedSyncTaskCount,
    required this.retryingSyncTaskCount,
    required this.approvedCount,
    required this.notApprovedCount,
    required this.foodOnlyOnSiteCount,
    required this.medicalOnlyOnSiteCount,
    required this.medicalAndFoodOnSiteCount,
    required this.exceptionCount,
    required this.totalPrintAttemptCount,
    required this.printFailuresLastHour,
    required this.syncErrorSampleCount,
    required this.uniqueRegisteredDeviceCount,
    required this.topCheckInDeviceLabel,
    required this.topCheckInDeviceCount,
    required this.liveAttendanceRate,
    required this.fullVerificationRate,
    required this.printSuccessRate,
    required this.retrySuccessRate,
    required this.oldestQueuedPrintAgeMinutes,
    required this.averagePrintAttemptSeconds,
    required this.stakeRows,
    required this.wardRows,
    required this.roomRows,
    required this.tableRows,
    required this.tablePresenceRows,
    required this.locationReadinessRows,
    required this.tshirtRows,
    required this.deviceCheckInRows,
    required this.hourlyCheckInRows,
    required this.peakCheckInRows,
    required this.ageRows,
    required this.genderRows,
    required this.registrationSourceRows,
    required this.signedByRows,
    required this.statusRows,
    required this.medicalCategoryRows,
    required this.foodCategoryRows,
    required this.syncTypeRows,
    required this.printFailureReasonRows,
    required this.partialParticipantAlerts,
    required this.noShowAlerts,
    required this.missingRoomAlerts,
    required this.missingTableAlerts,
    required this.foodAttentionAlerts,
    required this.urgentMedicalAlerts,
    required this.medicalOnSiteAlerts,
    required this.medicalNotArrivedAlerts,
    required this.technicalExceptionAlerts,
    required this.estimatedCompletionLabel,
    required this.recentVelocity,
    required this.previousVelocity,
    required this.velocityShortLabel,
    required this.velocityTrendLabel,
    required this.medicalWithoutLocationAlerts,
    required this.oldestSyncTaskAgeMinutes,
    required this.printSuccessRateLastHour,
    required this.printSuccessRatePreviousHour,
    required this.printSuccessRateTrendLabel,
  });

  factory _AnalyticsSnapshot.fromData({
    required List<Participant> participants,
    required List<_SyncTaskEntry> syncTasks,
    required List<PrinterQueuedJob> printJobs,
    required List<PrinterJobAttempt> printAttempts,
  }) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final checkedIn = participants.where((p) => p.verifiedAt != null).toList();
    final fullyVerified = participants.where((p) => p.isFullyVerified).toList();
    final partiallyVerified =
        participants.where((p) => p.isPartiallyVerified).toList();
    final pending = participants.where((p) => p.verifiedAt == null).toList();
    final printed = participants.where((p) => p.printedAt != null).toList();
    final recent15MinutesAgo = now - const Duration(minutes: 15).inMilliseconds;
    final recentHourAgo = now - const Duration(hours: 1).inMilliseconds;
    final recent15MinuteCount = checkedIn
        .where((p) => (p.verifiedAt ?? 0) >= recent15MinutesAgo)
        .length;
    final recentHourCount =
        checkedIn.where((p) => (p.verifiedAt ?? 0) >= recentHourAgo).length;

    final medicalParticipants =
        participants.where(_isMedicalAttentionParticipant).toList();
    final medicalOnSite =
        checkedIn.where(_isMedicalAttentionParticipant).toList();
    final medicalNotArrived =
        pending.where(_isMedicalAttentionParticipant).toList();
    final dietAttentionOnSite =
        checkedIn.where(_isFoodAttentionParticipant).toList();
    final noRestrictionOnSite =
        checkedIn.where(_hasNoRecordedRestriction).toList();
    final urgentMedicalOnSite =
        checkedIn.where(_isUrgentMedicalParticipant).toList();
    final generalMedicalAwarenessOnSiteCount =
        medicalOnSite.length - urgentMedicalOnSite.length;
    final approvedCount = participants.where(_isApprovedParticipant).length;
    final notApprovedCount = participants.length - approvedCount;
    final foodOnlyOnSiteCount = checkedIn
        .where(
          (participant) =>
              _hasFoodCategory(participant.medicalInfo) &&
              !_hasMedicalCategory(participant.medicalInfo),
        )
        .length;
    final medicalOnlyOnSiteCount = checkedIn
        .where(
          (participant) =>
              _hasMedicalCategory(participant.medicalInfo) &&
              !_hasFoodCategory(participant.medicalInfo),
        )
        .length;
    final medicalAndFoodOnSiteCount = checkedIn
        .where(
          (participant) =>
              _hasMedicalCategory(participant.medicalInfo) &&
              _hasFoodCategory(participant.medicalInfo),
        )
        .length;
    final medicalWithoutLocationCount = medicalOnSite
        .where((p) => !_hasText(p.roomNumber) || !_hasText(p.tableNumber))
        .length;
    final checkedInMissingRoom =
        checkedIn.where((p) => !_hasText(p.roomNumber)).toList();
    final checkedInMissingTable =
        checkedIn.where((p) => !_hasText(p.tableNumber)).toList();
    final missingAssignmentCount = checkedIn
        .where((p) => !_hasText(p.roomNumber) || !_hasText(p.tableNumber))
        .length;

    final queuedPrints =
        printJobs.where((job) => job.status == 'queued').toList();
    final pendingConfirmations = printJobs
        .where((job) => job.status == 'awaiting_confirmation')
        .toList();
    final staleQueuedPrintCount = queuedPrints
        .where(
          (job) =>
              now - job.queuedAt > const Duration(minutes: 10).inMilliseconds,
        )
        .length;
    final oldestQueuedPrintAgeMinutes = queuedPrints.isEmpty
        ? 0.0
        : queuedPrints
            .map(
              (job) =>
                  (now - job.queuedAt) /
                  const Duration(minutes: 1).inMilliseconds,
            )
            .reduce((left, right) => left > right ? left : right);

    final activeSyncTasks = syncTasks
        .where(
            (task) => task.status == 'pending' || task.status == 'in_progress')
        .toList();
    final failedSyncTasks =
        syncTasks.where((task) => task.status == 'failed').toList();
    final pendingSyncTaskCount = activeSyncTasks.length;
    final failedSyncTaskCount = failedSyncTasks.length;
    final retryingSyncTaskCount =
        activeSyncTasks.where((task) => task.attempts > 0).length;
    final syncErrorSampleCount =
        syncTasks.where((task) => _hasText(task.lastError)).length;

    final totalPrintAttemptCount = printAttempts.length;
    final successfulPrintAttempts =
        printAttempts.where((attempt) => attempt.outcome == 'success').length;
    final retryAttempts =
        printAttempts.where((attempt) => attempt.attemptNumber > 1).toList();
    final retrySuccesses =
        retryAttempts.where((attempt) => attempt.outcome == 'success').length;
    final printFailuresLastHour = printAttempts
        .where(
          (attempt) =>
              attempt.outcome == 'failed' &&
              attempt.finishedAt >= recentHourAgo,
        )
        .length;
    final averagePrintAttemptSeconds = printAttempts.isEmpty
        ? 0.0
        : printAttempts
                .map(
                  (attempt) =>
                      (attempt.finishedAt - attempt.startedAt) /
                      const Duration(seconds: 1).inMilliseconds,
                )
                .fold<double>(0, (sum, value) => sum + value) /
            printAttempts.length;

    final roomRows = _buildLocationRows(
      participants: participants,
      selector: (participant) => participant.roomNumber,
      unknownLabel: 'No room',
    );
    final tableRows = _buildLocationRows(
      participants: participants,
      selector: (participant) => participant.tableNumber,
      unknownLabel: 'No group',
    );
    final stakeRows = _buildPresenceRows(
      participants: participants,
      selector: (participant) => participant.stake,
      unknownLabel: 'No stake',
    );
    final wardRows = _buildPresenceRows(
      participants: participants,
      selector: (participant) => participant.ward,
      unknownLabel: 'No ward',
    );
    final ageRows = _buildSimpleCountRows(_buildAgeCounts(participants));
    final genderRows = _buildSimpleCountRows(_buildGenderCounts(participants));
    final registrationSourceRows =
        _buildSimpleCountRows(_buildRegistrationSourceCounts(participants));
    final signedByRows =
        _buildSimpleCountRows(_buildSignedByCounts(participants));
    final statusRows = _buildSimpleCountRows(_buildStatusCounts(participants));
    final medicalCategoryRows =
        _buildSimpleCountRows(_buildMedicalCategoryCounts(medicalParticipants));
    final foodCategoryRows =
        _buildSimpleCountRows(_buildFoodCategoryCounts(dietAttentionOnSite));
    final syncTypeRows =
        _buildSimpleCountRows(_buildSyncTypeCounts(activeSyncTasks));
    final printFailureReasonRows = _buildSimpleCountRows(
      _buildPrintFailureReasonCounts(printAttempts),
    );
    final tshirtRows = _buildTshirtRows(participants);
    final deviceCheckInRows = _buildSimpleCountRows(
      _buildDeviceCheckInCounts(checkedIn),
    );
    final hourlyCheckInRows = _buildSimpleCountRows(
      _buildCheckInHourCounts(checkedIn),
    );
    final peakCheckInRows = [...hourlyCheckInRows]
      ..sort((left, right) => right.total.compareTo(left.total));
    final tablePresenceRows = _buildAssignedGroupPresenceRows(
      participants: participants,
      selector: (participant) => participant.tableNumber,
      unknownLabel: 'No group',
    );
    final activeRoomCount =
        roomRows.where((row) => row.label != 'No room').length;
    final completedRoomCount = roomRows
        .where(
          (row) =>
              row.label != 'No room' &&
              row.trailing.startsWith('${row.total}/'),
        )
        .length;
    final activeTableCount =
        tableRows.where((row) => row.label != 'No group').length;
    final completedTableCount = tableRows
        .where(
          (row) =>
              row.label != 'No group' &&
              row.trailing.startsWith('${row.total}/'),
        )
        .length;

    final locationReadinessRows = [
      _BreakdownRow(
        label: 'Rooms',
        trailing: '$completedRoomCount/$activeRoomCount ready',
        caption:
            '${participants.where((p) => _hasText(p.roomNumber)).length} assigned participants across populated rooms',
        total: activeRoomCount,
        highlightColor: FSYScannerApp.accentGreen,
      ),
      _BreakdownRow(
        label: 'Groups',
        trailing: '$completedTableCount/$activeTableCount ready',
        caption:
            '${participants.where((p) => _hasText(p.tableNumber)).length} assigned participants across populated groups',
        total: activeTableCount,
        highlightColor: FSYScannerApp.primaryBlue,
      ),
    ];

    final partialParticipantAlerts = partiallyVerified
        .map(
          (participant) => _ParticipantAlert(
            name: participant.fullName,
            detail:
                'Checked in but still not fully complete because print truth is unresolved.',
            trailing: _participantLocationLabel(participant),
            icon: Icons.pending_actions_outlined,
            color: FSYScannerApp.accentGold,
          ),
        )
        .toList();

    final noShowAlerts = pending
        .map(
          (participant) => _ParticipantAlert(
            name: participant.fullName,
            detail: 'Still not checked in or verified in the app.',
            trailing:
                '${_cleanValue(participant.stake, 'No stake')} • ${_cleanValue(participant.ward, 'No ward')}',
            icon: Icons.person_off_outlined,
            color: Colors.grey.shade700,
          ),
        )
        .toList();

    final missingRoomAlerts = checkedInMissingRoom
        .map(
          (participant) => _ParticipantAlert(
            name: participant.fullName,
            detail:
                'Checked in already, but logistics still needs to assign a room.',
            trailing: _participantTableWardLabel(participant),
            icon: Icons.meeting_room_outlined,
            color: FSYScannerApp.accentGold,
          ),
        )
        .toList();

    final missingTableAlerts = checkedInMissingTable
        .map(
          (participant) => _ParticipantAlert(
            name: participant.fullName,
            detail:
                'Checked in already, but logistics still needs to assign a group.',
            trailing: _participantRoomWardLabel(participant),
            icon: Icons.table_restaurant_outlined,
            color: Colors.orangeAccent,
          ),
        )
        .toList();

    final foodAttentionAlerts = dietAttentionOnSite
        .map(
          (participant) => _ParticipantAlert(
            name: participant.fullName,
            detail: _foodAttentionSummary(participant),
            trailing: _participantLocationLabel(participant),
            icon: Icons.no_meals_outlined,
            color: FSYScannerApp.accentGold,
          ),
        )
        .toList();

    final urgentMedicalAlerts = urgentMedicalOnSite
        .map(
          (participant) => _ParticipantAlert(
            name: participant.fullName,
            detail: _medicalSummary(participant),
            trailing: _participantLocationLabel(participant),
            icon: Icons.priority_high_outlined,
            color: Colors.redAccent,
          ),
        )
        .toList();

    final medicalOnSiteAlerts = medicalOnSite
        .map(
          (participant) => _ParticipantAlert(
            name: participant.fullName,
            detail: _medicalSummary(participant),
            trailing: _participantLocationLabel(participant),
            icon: Icons.medical_services_outlined,
            color: Colors.redAccent,
          ),
        )
        .toList();

    final medicalNotArrivedAlerts = medicalNotArrived
        .map(
          (participant) => _ParticipantAlert(
            name: participant.fullName,
            detail: _medicalSummary(participant),
            trailing:
                '${_cleanValue(participant.stake, 'No stake')} • ${_cleanValue(participant.ward, 'No ward')}',
            icon: Icons.health_and_safety_outlined,
            color: Colors.redAccent,
          ),
        )
        .toList();

    final technicalExceptionAlerts = <_ParticipantAlert>[
      ...syncTasks.where((task) => _hasText(task.lastError)).take(4).map(
            (task) => _ParticipantAlert(
              name: 'Sync task #${task.id}',
              detail: task.lastError!,
              trailing: '${task.type} • attempts ${task.attempts}',
              icon: Icons.sync_problem_outlined,
              color: Colors.orangeAccent,
            ),
          ),
      ...printAttempts
          .where((attempt) => attempt.outcome == 'failed')
          .take(4)
          .map(
            (attempt) => _ParticipantAlert(
              name: attempt.participantName,
              detail: attempt.failureReason?.trim().isNotEmpty == true
                  ? attempt.failureReason!
                  : 'Print attempt failed.',
              trailing: 'Attempt ${attempt.attemptNumber}',
              icon: Icons.print_disabled_outlined,
              color: Colors.redAccent,
            ),
          ),
    ];

    final liveAttendanceRate = participants.isEmpty
        ? 0.0
        : (checkedIn.length / participants.length) * 100;
    final fullVerificationRate = participants.isEmpty
        ? 0.0
        : (fullyVerified.length / participants.length) * 100;
    final printSuccessRate = totalPrintAttemptCount == 0
        ? 0.0
        : (successfulPrintAttempts / totalPrintAttemptCount) * 100;
    final retrySuccessRate = retryAttempts.isEmpty
        ? 0.0
        : (retrySuccesses / retryAttempts.length) * 100;
    final exceptionCount = partiallyVerified.length +
        missingAssignmentCount +
        staleQueuedPrintCount +
        syncErrorSampleCount +
        failedSyncTaskCount;
    final uniqueRegisteredDeviceCount = checkedIn
        .map((p) => p.registeredBy?.trim() ?? '')
        .where((id) => id.isNotEmpty)
        .toSet()
        .length;
    final topCheckInDevice = deviceCheckInRows.isEmpty
        ? null
        : deviceCheckInRows
            .reduce((left, right) => left.total >= right.total ? left : right);

    final remainingCount = pending.length;
    String estimatedCompletionLabel;
    if (remainingCount == 0) {
      estimatedCompletionLabel = 'All registered participants have arrived.';
    } else if (recentHourCount <= 0) {
      estimatedCompletionLabel =
          'Pace is too slow to estimate arrival completion.';
    } else {
      final hoursLeft = remainingCount / recentHourCount;
      if (hoursLeft < 1) {
        final minutesLeft = (hoursLeft * 60).round();
        estimatedCompletionLabel =
            'At current pace, full arrival in ~$minutesLeft minutes.';
      } else {
        estimatedCompletionLabel =
            'At current pace, full arrival in ~${hoursLeft.toStringAsFixed(1)} hours.';
      }
    }

    final recent30MinAgo = now - const Duration(minutes: 30).inMilliseconds;
    final prev30MinAgo = now - const Duration(minutes: 60).inMilliseconds;
    final recentVelocity =
        checkedIn.where((p) => (p.verifiedAt ?? 0) >= recent30MinAgo).length;
    final previousVelocity = checkedIn
        .where((p) =>
            (p.verifiedAt ?? 0) >= prev30MinAgo &&
            (p.verifiedAt ?? 0) < recent30MinAgo)
        .length;
    final String velocityShortLabel;
    final String velocityTrendLabel;
    if (recentVelocity > previousVelocity + 2) {
      velocityShortLabel = '↑ $recentVelocity/30 min — accelerating';
      velocityTrendLabel =
          '↑ Pace accelerating: $recentVelocity check-ins in the last 30 min vs $previousVelocity in the prior 30 min.';
    } else if (recentVelocity < previousVelocity - 2) {
      velocityShortLabel = '↓ $recentVelocity/30 min — slowing';
      velocityTrendLabel =
          '↓ Pace slowing: $recentVelocity check-ins in the last 30 min vs $previousVelocity in the prior 30 min.';
    } else {
      velocityShortLabel = '→ $recentVelocity/30 min — steady';
      velocityTrendLabel =
          '→ Pace steady: $recentVelocity check-ins in the last 30 min.';
    }

    final medicalWithoutLocationAlerts = medicalOnSite
        .where((p) => !_hasText(p.roomNumber) || !_hasText(p.tableNumber))
        .map((p) => _ParticipantAlert(
              name: p.fullName,
              detail: _medicalSummary(p),
              trailing:
                  'No ${!_hasText(p.roomNumber) ? 'room' : 'group'} assigned',
              icon: Icons.location_off_outlined,
              color: Colors.redAccent,
            ))
        .toList();

    final pendingTaskCreatedAts = activeSyncTasks.map((t) => t.createdAt);
    final oldestSyncTaskAgeMinutes = pendingTaskCreatedAts.isEmpty
        ? 0.0
        : (now - pendingTaskCreatedAts.reduce((a, b) => a < b ? a : b)) /
            const Duration(minutes: 1).inMilliseconds;

    final prevHourAgo = now - const Duration(hours: 2).inMilliseconds;
    final attemptsLastHour =
        printAttempts.where((a) => a.finishedAt >= recentHourAgo).toList();
    final attemptsPrevHour = printAttempts
        .where(
            (a) => a.finishedAt >= prevHourAgo && a.finishedAt < recentHourAgo)
        .toList();
    final printSuccessRateLastHour = attemptsLastHour.isEmpty
        ? 0.0
        : attemptsLastHour.where((a) => a.outcome == 'success').length /
            attemptsLastHour.length *
            100;
    final printSuccessRatePreviousHour = attemptsPrevHour.isEmpty
        ? 0.0
        : attemptsPrevHour.where((a) => a.outcome == 'success').length /
            attemptsPrevHour.length *
            100;
    final String printSuccessRateTrendLabel;
    if (attemptsLastHour.isEmpty) {
      printSuccessRateTrendLabel = 'No print attempts in the last hour.';
    } else if (attemptsPrevHour.isEmpty) {
      printSuccessRateTrendLabel =
          '${printSuccessRateLastHour.toStringAsFixed(0)}% success rate this hour (no prior hour data).';
    } else {
      final diff = printSuccessRateLastHour - printSuccessRatePreviousHour;
      final arrow = diff > 5
          ? '↑'
          : diff < -5
              ? '↓'
              : '→';
      printSuccessRateTrendLabel =
          '$arrow Print success ${printSuccessRateLastHour.toStringAsFixed(0)}% this hour vs ${printSuccessRatePreviousHour.toStringAsFixed(0)}% last hour.';
    }

    return _AnalyticsSnapshot(
      totalParticipants: participants.length,
      checkedInCount: checkedIn.length,
      fullyVerifiedCount: fullyVerified.length,
      partiallyVerifiedCount: partiallyVerified.length,
      pendingCount: pending.length,
      printedCount: printed.length,
      notPrintedCount: checkedIn.length - printed.length,
      recent15MinuteCount: recent15MinuteCount,
      recentHourCount: recentHourCount,
      totalMedicalFlagCount: medicalParticipants.length,
      checkedInMedicalFlagCount: medicalOnSite.length,
      dietAttentionOnSiteCount: dietAttentionOnSite.length,
      noRestrictionOnSiteCount: noRestrictionOnSite.length,
      urgentMedicalOnSiteCount: urgentMedicalOnSite.length,
      generalMedicalAwarenessOnSiteCount: generalMedicalAwarenessOnSiteCount,
      medicalNotArrivedCount: medicalNotArrived.length,
      medicalWithoutLocationCount: medicalWithoutLocationCount,
      checkedInMissingRoomCount: checkedInMissingRoom.length,
      checkedInMissingTableCount: checkedInMissingTable.length,
      missingAssignmentCount: missingAssignmentCount,
      activeRoomCount: activeRoomCount,
      completedRoomCount: completedRoomCount,
      activeTableCount: activeTableCount,
      completedTableCount: completedTableCount,
      queuedPrintCount: queuedPrints.length,
      staleQueuedPrintCount: staleQueuedPrintCount,
      pendingConfirmationCount: pendingConfirmations.length,
      pendingSyncTaskCount: pendingSyncTaskCount,
      failedSyncTaskCount: failedSyncTaskCount,
      retryingSyncTaskCount: retryingSyncTaskCount,
      approvedCount: approvedCount,
      notApprovedCount: notApprovedCount,
      foodOnlyOnSiteCount: foodOnlyOnSiteCount,
      medicalOnlyOnSiteCount: medicalOnlyOnSiteCount,
      medicalAndFoodOnSiteCount: medicalAndFoodOnSiteCount,
      exceptionCount: exceptionCount,
      totalPrintAttemptCount: totalPrintAttemptCount,
      printFailuresLastHour: printFailuresLastHour,
      syncErrorSampleCount: syncErrorSampleCount,
      uniqueRegisteredDeviceCount: uniqueRegisteredDeviceCount,
      topCheckInDeviceLabel: topCheckInDevice?.label ?? 'No device data yet',
      topCheckInDeviceCount: topCheckInDevice?.total ?? 0,
      liveAttendanceRate: liveAttendanceRate,
      fullVerificationRate: fullVerificationRate,
      printSuccessRate: printSuccessRate,
      retrySuccessRate: retrySuccessRate,
      oldestQueuedPrintAgeMinutes: oldestQueuedPrintAgeMinutes,
      averagePrintAttemptSeconds: averagePrintAttemptSeconds,
      stakeRows: stakeRows,
      wardRows: wardRows,
      roomRows: roomRows,
      tableRows: tableRows,
      tablePresenceRows: tablePresenceRows,
      locationReadinessRows: locationReadinessRows,
      tshirtRows: tshirtRows,
      deviceCheckInRows: deviceCheckInRows,
      hourlyCheckInRows: hourlyCheckInRows,
      peakCheckInRows: peakCheckInRows,
      ageRows: ageRows,
      genderRows: genderRows,
      registrationSourceRows: registrationSourceRows,
      signedByRows: signedByRows,
      statusRows: statusRows,
      medicalCategoryRows: medicalCategoryRows,
      foodCategoryRows: foodCategoryRows,
      syncTypeRows: syncTypeRows,
      printFailureReasonRows: printFailureReasonRows,
      partialParticipantAlerts: partialParticipantAlerts,
      noShowAlerts: noShowAlerts,
      missingRoomAlerts: missingRoomAlerts,
      missingTableAlerts: missingTableAlerts,
      foodAttentionAlerts: foodAttentionAlerts,
      urgentMedicalAlerts: urgentMedicalAlerts,
      medicalOnSiteAlerts: medicalOnSiteAlerts,
      medicalNotArrivedAlerts: medicalNotArrivedAlerts,
      technicalExceptionAlerts: technicalExceptionAlerts,
      estimatedCompletionLabel: estimatedCompletionLabel,
      recentVelocity: recentVelocity,
      previousVelocity: previousVelocity,
      velocityShortLabel: velocityShortLabel,
      velocityTrendLabel: velocityTrendLabel,
      medicalWithoutLocationAlerts: medicalWithoutLocationAlerts,
      oldestSyncTaskAgeMinutes: oldestSyncTaskAgeMinutes,
      printSuccessRateLastHour: printSuccessRateLastHour,
      printSuccessRatePreviousHour: printSuccessRatePreviousHour,
      printSuccessRateTrendLabel: printSuccessRateTrendLabel,
    );
  }

  // -----------------------------------------------------------------------
  // Static helper methods – complete, no placeholders
  // -----------------------------------------------------------------------
  static List<_BreakdownRow> _buildLocationRows({
    required List<Participant> participants,
    required String? Function(Participant participant) selector,
    required String unknownLabel,
  }) {
    final grouped = <String, List<Participant>>{};
    for (final participant in participants) {
      final label = _cleanValue(selector(participant), unknownLabel);
      grouped.putIfAbsent(label, () => []).add(participant);
    }
    final rows = grouped.entries.map((entry) {
      final total = entry.value.length;
      final onSite =
          entry.value.where((participant) => participant.isVerified).length;
      final ready = entry.value
          .where((participant) => participant.isFullyVerified)
          .length;
      return _BreakdownRow(
        label: entry.key,
        trailing: '$ready/$total ready',
        caption: '$onSite on site of $total assigned',
        total: total,
        highlightColor: ready == total && total > 0
            ? FSYScannerApp.accentGreen
            : FSYScannerApp.primaryBlue,
      );
    }).toList()
      ..sort((left, right) => right.total.compareTo(left.total));
    return rows;
  }

  static List<_BreakdownRow> _buildPresenceRows({
    required List<Participant> participants,
    required String? Function(Participant participant) selector,
    required String unknownLabel,
  }) {
    final grouped = <String, List<Participant>>{};
    for (final participant in participants) {
      final label = _cleanValue(selector(participant), unknownLabel);
      grouped.putIfAbsent(label, () => []).add(participant);
    }
    final rows = grouped.entries.map((entry) {
      final total = entry.value.length;
      final onSite =
          entry.value.where((participant) => participant.isVerified).length;
      final ready = entry.value
          .where((participant) => participant.isFullyVerified)
          .length;
      return _BreakdownRow(
        label: entry.key,
        trailing: '$onSite/$total on site',
        caption: '$ready fully verified',
        total: onSite,
        highlightColor: ready == onSite && onSite > 0
            ? FSYScannerApp.accentGreen
            : FSYScannerApp.primaryBlue,
      );
    }).toList()
      ..sort((left, right) => right.total.compareTo(left.total));
    return rows;
  }

  static Map<String, int> _buildAgeCounts(List<Participant> participants) {
    final counts = <String, int>{};
    for (final participant in participants) {
      final age = participant.age;
      final label = switch (age) {
        null => 'Age not set',
        <= 13 => '13 and below',
        <= 15 => '14-15',
        <= 17 => '16-17',
        <= 19 => '18-19',
        _ => '20 and above',
      };
      counts.update(label, (value) => value + 1, ifAbsent: () => 1);
    }
    return counts;
  }

  static Map<String, int> _buildGenderCounts(List<Participant> participants) {
    final counts = <String, int>{};
    for (final participant in participants) {
      final label = _cleanValue(participant.gender, 'Gender not set');
      counts.update(label, (value) => value + 1, ifAbsent: () => 1);
    }
    return counts;
  }

  static Map<String, int> _buildRegistrationSourceCounts(
    List<Participant> participants,
  ) {
    final counts = <String, int>{};
    for (final participant in participants) {
      final label =
          _normalizeRegistrationSource(participant.registrationSource);
      counts.update(label, (value) => value + 1, ifAbsent: () => 1);
    }
    return counts;
  }

  static Map<String, int> _buildSignedByCounts(List<Participant> participants) {
    final counts = <String, int>{};
    for (final participant in participants) {
      final label = _normalizeSignedBy(participant.signedBy);
      counts.update(label, (value) => value + 1, ifAbsent: () => 1);
    }
    return counts;
  }

  static Map<String, int> _buildStatusCounts(List<Participant> participants) {
    final counts = <String, int>{};
    for (final participant in participants) {
      final label = _normalizeStatusLabel(participant.status);
      counts.update(label, (value) => value + 1, ifAbsent: () => 1);
    }
    return counts;
  }

  static List<_BreakdownRow> _buildTshirtRows(List<Participant> participants) {
    final grouped = <String, List<Participant>>{};
    for (final p in participants) {
      final label = _cleanValue(p.tshirtSize, 'No size recorded');
      grouped.putIfAbsent(label, () => []).add(p);
    }
    return grouped.entries.map((entry) {
      final total = entry.value.length;
      final onSite = entry.value.where((p) => p.verifiedAt != null).length;
      return _BreakdownRow(
        label: entry.key,
        trailing: '$onSite / $total arrived',
        caption: '${total - onSite} still not on site',
        total: total,
        current: onSite,
        highlightColor: onSite == total && total > 0
            ? FSYScannerApp.accentGreen
            : FSYScannerApp.primaryBlue,
      );
    }).toList()
      ..sort((a, b) => b.total.compareTo(a.total));
  }

  static Map<String, int> _buildDeviceCheckInCounts(
    List<Participant> participants,
  ) {
    final counts = <String, int>{};
    for (final participant in participants) {
      final label = _cleanValue(participant.registeredBy, 'No device recorded');
      counts.update(label, (value) => value + 1, ifAbsent: () => 1);
    }
    return counts;
  }

  static Map<String, int> _buildCheckInHourCounts(
    List<Participant> participants,
  ) {
    final counts = <String, int>{};
    for (final participant in participants) {
      final verifiedAt = participant.verifiedAt;
      if (verifiedAt == null) {
        continue;
      }
      final label = DateFormat('dd MMM • h a')
          .format(DateTime.fromMillisecondsSinceEpoch(verifiedAt));
      counts.update(label, (value) => value + 1, ifAbsent: () => 1);
    }
    return counts;
  }

  static Map<String, int> _buildMedicalCategoryCounts(
    List<Participant> participants,
  ) {
    final counts = <String, int>{};
    for (final participant in participants) {
      final label = _classifyMedicalAttention(participant);
      counts.update(label, (value) => value + 1, ifAbsent: () => 1);
    }
    return counts;
  }

  static Map<String, int> _buildFoodCategoryCounts(
    List<Participant> participants,
  ) {
    final counts = <String, int>{};
    for (final participant in participants) {
      final label = _classifyFoodAttention(participant);
      counts.update(label, (value) => value + 1, ifAbsent: () => 1);
    }
    return counts;
  }

  static Map<String, int> _buildSyncTypeCounts(List<_SyncTaskEntry> tasks) {
    final counts = <String, int>{};
    for (final task in tasks) {
      final label = task.type.replaceAll('_', ' ');
      counts.update(label, (value) => value + 1, ifAbsent: () => 1);
    }
    return counts;
  }

  static Map<String, int> _buildPrintFailureReasonCounts(
    List<PrinterJobAttempt> attempts,
  ) {
    final counts = <String, int>{};
    for (final attempt
        in attempts.where((entry) => entry.outcome == 'failed')) {
      final label = _cleanValue(
        attempt.failureCode?.replaceAll('_', ' '),
        _cleanValue(attempt.failureReason, 'Unknown failure'),
      );
      counts.update(label, (value) => value + 1, ifAbsent: () => 1);
    }
    return counts;
  }

  static List<_BreakdownRow> _buildAssignedGroupPresenceRows({
    required List<Participant> participants,
    required String? Function(Participant participant) selector,
    required String unknownLabel,
  }) {
    final grouped = <String, List<Participant>>{};
    for (final participant in participants) {
      final label = _cleanValue(selector(participant), unknownLabel);
      grouped.putIfAbsent(label, () => []).add(participant);
    }
    final rows = grouped.entries.map((entry) {
      final assigned = entry.value.length;
      final present =
          entry.value.where((participant) => participant.isVerified).length;
      final fullyReady = entry.value
          .where((participant) => participant.isFullyVerified)
          .length;
      return _BreakdownRow(
        label: entry.key,
        trailing: '$present present',
        caption: '$assigned assigned • $fullyReady fully ready',
        total: present,
        highlightColor: fullyReady == assigned && assigned > 0
            ? FSYScannerApp.accentGreen
            : FSYScannerApp.primaryBlue,
      );
    }).toList()
      ..sort((left, right) => right.total.compareTo(left.total));
    return rows;
  }

  static List<_BreakdownRow> _buildSimpleCountRows(Map<String, int> counts) {
    final rows = counts.entries
        .map(
          (entry) => _BreakdownRow(
            label: entry.key,
            trailing: '${entry.value}',
            caption: '${entry.value} participant${entry.value == 1 ? '' : 's'}',
            total: entry.value,
            highlightColor: FSYScannerApp.primaryBlue,
          ),
        )
        .toList()
      ..sort((left, right) => right.total.compareTo(left.total));
    return rows;
  }

  static bool _hasText(String? value) {
    return value != null && value.trim().isNotEmpty;
  }

  static bool _containsKeyword(String text, List<String> keywords) {
    final normalized = text.toLowerCase();
    return keywords.any(normalized.contains);
  }

  static bool _hasMedicalCategory(String? value) {
    final normalized = (value ?? '').trim().toLowerCase();
    return normalized.contains('medical');
  }

  static bool _hasFoodCategory(String? value) {
    final normalized = (value ?? '').trim().toLowerCase();
    return normalized.contains('food');
  }

  static bool _isExplicitNoRestriction(String? value) {
    if (value == null || value.trim().isEmpty) {
      return true;
    }
    final normalized = value.trim().toLowerCase();
    return normalized == 'none' ||
        normalized == 'n/a' ||
        normalized == 'na' ||
        normalized == 'nil' ||
        normalized == 'no';
  }

  static bool _hasNoRecordedRestriction(Participant participant) {
    final category = participant.medicalInfo;
    if (_isExplicitNoRestriction(category)) {
      return true;
    }
    return !_hasText(category) && !_hasText(participant.note);
  }

  static bool _isMedicalAttentionParticipant(Participant participant) {
    if (_hasMedicalCategory(participant.medicalInfo)) {
      return true;
    }
    final note = participant.note?.trim().toLowerCase() ?? '';
    if (note.isEmpty) {
      return false;
    }
    return _containsKeyword(note, const [
      'asthma',
      'seizure',
      'epilepsy',
      'anaphyl',
      'heart',
      'insulin',
      'diabet',
      'wheelchair',
      'medication',
      'allergy',
    ]);
  }

  static bool _isFoodAttentionParticipant(Participant participant) {
    if (_hasFoodCategory(participant.medicalInfo)) {
      return true;
    }
    if (_isExplicitNoRestriction(participant.medicalInfo)) {
      return false;
    }
    final combined =
        '${participant.medicalInfo ?? ''} ${participant.note ?? ''}'
            .toLowerCase();
    if (combined.trim().isEmpty) {
      return false;
    }
    return _containsKeyword(combined, const [
      'allergy',
      'allergic',
      'peanut',
      'seafood',
      'egg',
      'milk',
      'gluten',
      'halal',
      'vegetarian',
      'vegan',
      'diet',
      'food',
      'lactose',
      'diabetic',
    ]);
  }

  static bool _isUrgentMedicalParticipant(Participant participant) {
    if (!_isMedicalAttentionParticipant(participant)) {
      return false;
    }
    final combined =
        '${participant.medicalInfo ?? ''} ${participant.note ?? ''}'
            .toLowerCase();
    if (combined.trim().isEmpty) {
      return false;
    }
    return _containsKeyword(combined, const [
      'asthma',
      'seizure',
      'epilepsy',
      'anaphyl',
      'heart',
      'severe',
      'emergency',
      'insulin',
      'diabetic',
      'wheelchair',
      'allergy',
    ]);
  }

  static String _classifyMedicalAttention(Participant participant) {
    final category = (participant.medicalInfo ?? '').trim().toLowerCase();
    final details = (participant.note ?? '').trim().toLowerCase();
    final combined = '$category $details'.trim();
    if (combined.isEmpty) {
      return 'Other medical';
    }
    if (category.contains('medical, food') ||
        category.contains('food, medical')) {
      return 'Medical and food';
    }
    if (_containsKeyword(
        combined, const ['allergy', 'allergic', 'peanut', 'egg'])) {
      return 'Allergy';
    }
    if (_containsKeyword(combined, const ['asthma', 'inhaler', 'breathing'])) {
      return 'Respiratory';
    }
    if (_containsKeyword(combined, const ['diabet', 'insulin', 'sugar'])) {
      return 'Diabetes';
    }
    if (_containsKeyword(combined, const ['seizure', 'epilepsy'])) {
      return 'Neurological';
    }
    if (_containsKeyword(
        combined, const ['wheelchair', 'mobility', 'injury'])) {
      return 'Mobility';
    }
    if (_containsKeyword(combined, const ['medication', 'tablet', 'capsule'])) {
      return 'Medication';
    }
    if (_containsKeyword(
        combined, const ['food', 'diet', 'gluten', 'lactose'])) {
      return 'Diet-related';
    }
    if (category == 'medical') {
      return 'Medical';
    }
    return 'Other medical';
  }

  static String _classifyFoodAttention(Participant participant) {
    final category = (participant.medicalInfo ?? '').trim().toLowerCase();
    if (category.contains('medical, food') ||
        category.contains('food, medical')) {
      return 'Medical and food';
    }
    if (category == 'food') {
      return 'Food';
    }
    final combined =
        '${participant.medicalInfo ?? ''} ${participant.note ?? ''}'
            .toLowerCase();
    if (_containsKeyword(combined, const ['halal'])) {
      return 'Possible halal concern';
    }
    if (_containsKeyword(combined, const ['vegetarian', 'vegan'])) {
      return 'Possible vegetarian or vegan concern';
    }
    if (_containsKeyword(combined, const ['gluten'])) {
      return 'Possible gluten concern';
    }
    if (_containsKeyword(combined, const ['lactose', 'milk'])) {
      return 'Possible dairy concern';
    }
    if (_containsKeyword(combined, const ['peanut', 'seafood', 'allergy'])) {
      return 'Possible allergy concern';
    }
    return 'Other food-related concern';
  }

  static bool _isApprovedParticipant(Participant participant) {
    final normalized = (participant.status ?? '').trim().toLowerCase();
    return normalized == 'approved';
  }

  static String _normalizeRegistrationSource(String? value) {
    final normalized = (value ?? '').trim().toLowerCase();
    if (normalized.isEmpty) {
      return 'Not recorded';
    }
    if (normalized.contains('both')) {
      return 'Both online and printed';
    }
    if (normalized.contains('online')) {
      return 'Online only';
    }
    if (normalized.contains('printed')) {
      return 'Printed only';
    }
    return _cleanValue(value, 'Not recorded');
  }

  static String _normalizeSignedBy(String? value) {
    final normalized = (value ?? '').trim().toLowerCase();
    if (normalized.isEmpty) {
      return 'Not recorded';
    }
    if (normalized == 'not signed') {
      return 'Not signed';
    }
    if (normalized == 'no printed copy') {
      return 'No printed copy';
    }
    if (normalized == 'parent') {
      return 'Parent';
    }
    if (normalized == 'guardian') {
      return 'Guardian';
    }
    if (normalized == 'unsure') {
      return 'Unsure';
    }
    return _cleanValue(value, 'Not recorded');
  }

  static String _normalizeStatusLabel(String? value) {
    final normalized = (value ?? '').trim().toLowerCase();
    if (normalized.isEmpty) {
      return 'Not recorded';
    }
    if (normalized == 'approved') {
      return 'Approved';
    }
    if (normalized == 'not yet approved') {
      return 'Not yet approved';
    }
    if (normalized == 'no online registration') {
      return 'No online registration';
    }
    return _cleanValue(value, 'Not recorded');
  }

  static String _cleanValue(String? value, String fallback) {
    if (value == null || value.trim().isEmpty) {
      return fallback;
    }
    return value.trim();
  }

  static String _participantLocationLabel(Participant participant) {
    final room = _cleanValue(participant.roomNumber, 'No room');
    final group = _cleanValue(participant.tableNumber, 'No group');
    return 'Room $room • Group $group';
  }

  static String _participantTableWardLabel(Participant participant) {
    final group = _cleanValue(participant.tableNumber, 'No group');
    final ward = _cleanValue(participant.ward, 'No ward');
    return 'Group $group • $ward';
  }

  static String _participantRoomWardLabel(Participant participant) {
    final room = _cleanValue(participant.roomNumber, 'No room');
    final ward = _cleanValue(participant.ward, 'No ward');
    return 'Room $room • $ward';
  }

  static String _medicalSummary(Participant participant) {
    final category = participant.medicalInfo?.trim() ?? '';
    final note = participant.note?.trim() ?? '';
    final combined = [category, note]
        .where((value) => value.isNotEmpty && value.toLowerCase() != 'none')
        .join(' | ');
    if (combined.isEmpty) {
      return 'Medical flag present but no detailed text available.';
    }
    return combined.length > 90 ? '${combined.substring(0, 90)}...' : combined;
  }

  static String _foodAttentionSummary(Participant participant) {
    final medical = participant.medicalInfo?.trim() ?? '';
    final note = participant.note?.trim() ?? '';
    final combined = [medical, note]
        .where((value) => value.isNotEmpty && value.toLowerCase() != 'none')
        .join(' | ');
    if (combined.isEmpty) {
      return 'Food-related attention inferred but no detailed note was found.';
    }
    return combined.length > 90 ? '${combined.substring(0, 90)}...' : combined;
  }
}

class _SyncTaskEntry {
  final int id;
  final String type;
  final String status;
  final int attempts;
  final String? lastError;
  final int createdAt;

  const _SyncTaskEntry({
    required this.id,
    required this.type,
    required this.status,
    required this.attempts,
    required this.lastError,
    required this.createdAt,
  });

  factory _SyncTaskEntry.fromRow(Map<String, Object?> row) {
    return _SyncTaskEntry(
      id: row['id'] as int? ?? 0,
      type: row['type'] as String? ?? '',
      status: row['status'] as String? ?? '',
      attempts: row['attempts'] as int? ?? 0,
      lastError: row['last_error'] as String?,
      createdAt: row['created_at'] as int? ?? 0,
    );
  }
}

class _MetricCardData {
  final String label;
  final String value;
  final String helper;
  final IconData icon;
  final Color color;
  final int? delta;

  const _MetricCardData({
    required this.label,
    required this.value,
    required this.helper,
    required this.icon,
    required this.color,
    this.delta,
  });
}

class _AttentionItem {
  final String label;
  final String value;

  const _AttentionItem({
    required this.label,
    required this.value,
  });
}

class _BreakdownRow {
  final String label;
  final String trailing;
  final String caption;
  final int total;
  final Color highlightColor;
  final int? current;

  const _BreakdownRow({
    required this.label,
    required this.trailing,
    required this.caption,
    required this.total,
    required this.highlightColor,
    this.current,
  });
}

class _ParticipantAlert {
  final String name;
  final String detail;
  final String? trailing;
  final IconData icon;
  final Color color;

  const _ParticipantAlert({
    required this.name,
    required this.detail,
    required this.trailing,
    required this.icon,
    required this.color,
  });
}
