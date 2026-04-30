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
import '../providers/app_state.dart';

class AnalyticsScreen extends StatefulWidget {
  const AnalyticsScreen({super.key});

  @override
  State<AnalyticsScreen> createState() => _AnalyticsScreenState();
}

class _AnalyticsScreenState extends State<AnalyticsScreen> {
  List<Participant> _participants = [];
  List<_SyncTaskEntry> _syncTasks = [];
  bool _loading = true;
  String? _error;
  int _requestId = 0;
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

      final participants = await participantsFuture;
      final taskRows = await syncTasksFuture;

      participants.sort((a, b) {
        final verifiedCompare = (b.verifiedAt ?? 0).compareTo(a.verifiedAt ?? 0);
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
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('Analytics'),
        actions: [
          IconButton(
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh analytics',
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? _buildErrorState()
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.all(12),
                    children: [
                      _buildHeader(appState, analytics),
                      const SizedBox(height: 12),
                      _buildSummaryGrid(appState, analytics),
                      const SizedBox(height: 12),
                      _buildProgressCard(analytics),
                      const SizedBox(height: 12),
                      _buildOpsHealthCard(appState, analytics),
                      const SizedBox(height: 12),
                      _buildExceptionsCard(appState, analytics),
                      const SizedBox(height: 12),
                      _buildTrendCard(analytics),
                      const SizedBox(height: 12),
                      _buildStakeCard(analytics),
                      const SizedBox(height: 12),
                      _buildOperationalMixCard(analytics),
                      const SizedBox(height: 12),
                      _buildDemographicsCard(analytics),
                      const SizedBox(height: 12),
                      _buildAuditTrailCard(appState, analytics),
                    ],
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
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
            ),
            const SizedBox(height: 4),
            Text(
              subtitle,
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: Colors.grey[700]),
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
          ],
        ),
      ),
    );
  }

  Widget _buildSummaryGrid(AppState appState, _AnalyticsSnapshot analytics) {
    final cards = [
      _MetricCardData(
        label: 'Checked in',
        value: '${analytics.checkedInCount}',
        helper:
            '${analytics.completionRate.toStringAsFixed(1)}% of ${analytics.totalParticipants}',
        icon: Icons.how_to_reg,
        color: FSYScannerApp.accentGreen,
      ),
      _MetricCardData(
        label: 'Pending',
        value: '${analytics.pendingCount}',
        helper: analytics.pendingCount == 0
            ? 'Everyone is checked in'
            : 'Still waiting to arrive',
        icon: Icons.hourglass_bottom,
        color: FSYScannerApp.accentGold,
      ),
      _MetricCardData(
        label: 'Printed',
        value: '${analytics.printedCount}',
        helper:
            '${analytics.printCoverageRate.toStringAsFixed(1)}% of checked in',
        icon: Icons.print,
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
            ? FSYScannerApp.primaryBlue
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
        helper: '${analytics.checkedInNotPrintedCount} checked in not printed',
        icon: Icons.warning_amber_rounded,
        color: analytics.exceptionCount == 0
            ? FSYScannerApp.accentGreen
            : Colors.redAccent,
      ),
      _MetricCardData(
        label: 'Printer retries',
        value: '${appState.printerFailedJobCount}',
        helper: appState.printerStatusMessage,
        icon: Icons.print_disabled,
        color: appState.printerFailedJobCount == 0
            ? FSYScannerApp.primaryBlue
            : Colors.redAccent,
      ),
      _MetricCardData(
        label: 'Medical flags',
        value: '${analytics.medicalFlagCount}',
        helper: '${analytics.noteCount} participant notes',
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
          .map(
            (card) => SizedBox(
              width: 170,
              child: _buildMetricCard(card),
            ),
          )
          .toList(),
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
              'Executive Summary',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  flex: 3,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${analytics.checkedInCount} of ${analytics.totalParticipants}',
                        style: const TextStyle(
                          fontSize: 30,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${analytics.completionRate.toStringAsFixed(1)}% event completion',
                        style: TextStyle(color: Colors.grey[700]),
                      ),
                      const SizedBox(height: 20),
                      _buildProgressRow(
                        label: 'Check-in progress',
                        value: analytics.completionRate / 100,
                        color: FSYScannerApp.accentGreen,
                        trailing:
                            '${analytics.checkedInCount}/${analytics.totalParticipants}',
                      ),
                      const SizedBox(height: 12),
                      _buildProgressRow(
                        label: 'Receipt coverage',
                        value: analytics.printCoverageRate / 100,
                        color: FSYScannerApp.primaryBlue,
                        trailing:
                            '${analytics.printedCount}/${analytics.checkedInCount}',
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: SizedBox(
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
                  ),
                ),
              ],
            ),
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
            Text(trailing),
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

  Widget _buildOpsHealthCard(
    AppState appState,
    _AnalyticsSnapshot analytics,
  ) {
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
              'Ops Health',
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
              icon: appState.printerConnected ? Icons.print : Icons.print_disabled,
              label: 'Printer',
              value: appState.printerConnected ? 'Connected' : 'Attention needed',
              detail: appState.printerStatusMessage,
              color: appState.printerConnected
                  ? FSYScannerApp.primaryBlue
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

  Widget _buildExceptionsCard(
    AppState appState,
    _AnalyticsSnapshot analytics,
  ) {
    final items = [
      _ExceptionData(
        label: 'Checked in not printed',
        value: analytics.checkedInNotPrintedCount,
        color: analytics.checkedInNotPrintedCount == 0
            ? FSYScannerApp.accentGreen
            : Colors.redAccent,
      ),
      _ExceptionData(
        label: 'Missing room assignment',
        value: analytics.missingRoomCount,
        color:
            analytics.missingRoomCount == 0 ? FSYScannerApp.primaryBlue : Colors.redAccent,
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
                    horizontalInterval:
                        math.max(1, (math.max(4, maxCount) / 4).ceil()).toDouble(),
                  ),
                  borderData: FlBorderData(show: false),
                  titlesData: FlTitlesData(
                    topTitles: const AxisTitles(),
                    rightTitles: const AxisTitles(),
                    leftTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 28,
                        interval:
                            math.max(1, (math.max(4, maxCount) / 4).ceil()).toDouble(),
                      ),
                    ),
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 28,
                        getTitlesWidget: (value, meta) {
                          final index = value.toInt();
                          if (index < 0 || index >= analytics.activityBuckets.length) {
                            return const SizedBox.shrink();
                          }
                          return Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text(
                              DateFormat('ha')
                                  .format(analytics.activityBuckets[index].start)
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
                          toY: analytics.activityBuckets[index].count.toDouble(),
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
            ...analytics.topRoomRows.map(_buildBreakdownRow),
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
              value: entry.value.total.toDouble(),
              color: colors[entry.key % colors.length],
              title: '',
              radius: 22,
            );
          }).toList();

    final maxAgeValue = analytics.ageRows.fold<int>(
      0,
      (current, row) => math.max(current, row.total),
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
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
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
                              Expanded(child: Text(row.label)),
                              Text('${row.total}'),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
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
                              horizontalInterval: math.max(
                                1,
                                (math.max(4, maxAgeValue) / 4).ceil(),
                              ).toDouble(),
                            ),
                            borderData: FlBorderData(show: false),
                            titlesData: FlTitlesData(
                              topTitles: const AxisTitles(),
                              rightTitles: const AxisTitles(),
                              leftTitles: AxisTitles(
                                sideTitles: SideTitles(
                                  showTitles: true,
                                  reservedSize: 28,
                                  interval: math.max(
                                    1,
                                    (math.max(4, maxAgeValue) / 4).ceil(),
                                  ).toDouble(),
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
                                    toY: analytics.ageRows[index].total.toDouble(),
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
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAuditTrailCard(
    AppState appState,
    _AnalyticsSnapshot analytics,
  ) {
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
                progress >= 1 ? FSYScannerApp.accentGreen : FSYScannerApp.accentGold,
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
                ),
              ),
              Text('${row.pending} pending'),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 10,
              valueColor:
                  const AlwaysStoppedAnimation<Color>(FSYScannerApp.accentGold),
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
      if (_hasValue(participant.roomNumber)) 'Room ${participant.roomNumber!.trim()}',
      if (_hasValue(participant.tableNumber))
        'Table ${participant.tableNumber!.trim()}',
      if (participant.printedAt != null) 'Printed',
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
      ),
      trailing: Text(
        verifiedAt == null ? '-' : DateFormat('h:mm a').format(
          DateTime.fromMillisecondsSinceEpoch(verifiedAt),
        ),
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
        style: TextStyle(
          color: textColor,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  String _formatRelativeTime(int timestamp) {
    final difference =
        DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(timestamp));
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
  final int printedCount;
  final int checkedInNotPrintedCount;
  final int medicalFlagCount;
  final int noteCount;
  final int missingRoomCount;
  final int missingTableCount;
  final int recent15MinuteCount;
  final int recentHourCount;
  final int peakHourCount;
  final int pendingSyncTaskCount;
  final int retryingSyncTaskCount;
  final int exceptionCount;
  final int? oldestPendingTask;
  final double completionRate;
  final double printCoverageRate;
  final List<_BreakdownRow> topStakeRows;
  final List<_BreakdownRow> topWardPendingRows;
  final List<_BreakdownRow> topRoomRows;
  final List<_BreakdownRow> genderRows;
  final List<_BreakdownRow> ageRows;
  final List<_BreakdownRow> syncTypeRows;
  final List<_ActivityBucket> activityBuckets;
  final List<Participant> recentCheckIns;

  const _AnalyticsSnapshot({
    required this.totalParticipants,
    required this.checkedInCount,
    required this.pendingCount,
    required this.printedCount,
    required this.checkedInNotPrintedCount,
    required this.medicalFlagCount,
    required this.noteCount,
    required this.missingRoomCount,
    required this.missingTableCount,
    required this.recent15MinuteCount,
    required this.recentHourCount,
    required this.peakHourCount,
    required this.pendingSyncTaskCount,
    required this.retryingSyncTaskCount,
    required this.exceptionCount,
    required this.oldestPendingTask,
    required this.completionRate,
    required this.printCoverageRate,
    required this.topStakeRows,
    required this.topWardPendingRows,
    required this.topRoomRows,
    required this.genderRows,
    required this.ageRows,
    required this.syncTypeRows,
    required this.activityBuckets,
    required this.recentCheckIns,
  });

  factory _AnalyticsSnapshot.fromData({
    required List<Participant> participants,
    required List<_SyncTaskEntry> syncTasks,
  }) {
    final checkedIn = participants.where((p) => p.verifiedAt != null).toList();
    final printed = participants.where((p) => p.printedAt != null).length;
    final pending = participants.length - checkedIn.length;
    final checkedInNotPrinted =
        checkedIn.where((p) => p.printedAt == null).length;
    final medicalFlags =
        participants.where((p) => _hasText(p.medicalInfo)).length;
    final notes = participants.where((p) => _hasText(p.note)).length;
    final missingRooms =
        participants.where((p) => !_hasText(p.roomNumber)).length;
    final missingTables =
        participants.where((p) => !_hasText(p.tableNumber)).length;

    final now = DateTime.now().millisecondsSinceEpoch;
    final recent15Minutes = checkedIn
        .where((p) => now - (p.verifiedAt ?? 0) <= const Duration(minutes: 15).inMilliseconds)
        .length;
    final recentHour = checkedIn
        .where((p) => now - (p.verifiedAt ?? 0) <= const Duration(hours: 1).inMilliseconds)
        .length;

    final activityBuckets = _buildActivityBuckets(checkedIn);
    final peakHour = activityBuckets.fold<int>(
      0,
      (current, bucket) => math.max(current, bucket.count),
    );

    final stakeRows = _buildBreakdown(
      participants,
      (participant) => _normalizeLabel(participant.stake, 'Unknown stake'),
    )..sort((a, b) => b.total.compareTo(a.total));

    final wardRows = _buildBreakdown(
      participants,
      (participant) => _normalizeLabel(participant.ward, 'Unknown ward'),
    )..sort((a, b) => b.pending.compareTo(a.pending));

    final roomRows = _buildBreakdown(
      participants,
      (participant) => _normalizeLabel(participant.roomNumber, 'No room'),
    )..sort((a, b) => b.total.compareTo(a.total));

    final genderRows = _buildBreakdown(
      participants,
      (participant) => _normalizeLabel(participant.gender, 'Unknown'),
    )..sort((a, b) => b.total.compareTo(a.total));

    final ageRows = _buildAgeBreakdown(participants);
    final syncTypeRows = _buildSyncBreakdown(syncTasks);
    final retryingSyncCount = syncTasks.where((task) => task.attempts > 0).length;
    final oldestPendingTask = syncTasks.isEmpty
        ? null
        : syncTasks.map((task) => task.createdAt).reduce(math.min);
    final recentCheckIns = [...checkedIn]
      ..sort((a, b) => (b.verifiedAt ?? 0).compareTo(a.verifiedAt ?? 0));

    final exceptionCount = checkedInNotPrinted +
        missingRooms +
        missingTables +
        retryingSyncCount +
        medicalFlags;

    return _AnalyticsSnapshot(
      totalParticipants: participants.length,
      checkedInCount: checkedIn.length,
      pendingCount: pending,
      printedCount: printed,
      checkedInNotPrintedCount: checkedInNotPrinted,
      medicalFlagCount: medicalFlags,
      noteCount: notes,
      missingRoomCount: missingRooms,
      missingTableCount: missingTables,
      recent15MinuteCount: recent15Minutes,
      recentHourCount: recentHour,
      peakHourCount: peakHour,
      pendingSyncTaskCount: syncTasks.length,
      retryingSyncTaskCount: retryingSyncCount,
      exceptionCount: exceptionCount,
      oldestPendingTask: oldestPendingTask,
      completionRate:
          participants.isEmpty ? 0 : checkedIn.length / participants.length * 100,
      printCoverageRate:
          checkedIn.isEmpty ? 0 : printed / checkedIn.length * 100,
      topStakeRows: stakeRows.take(6).toList(),
      topWardPendingRows: wardRows.take(6).toList(),
      topRoomRows: roomRows.take(6).toList(),
      genderRows: genderRows,
      ageRows: ageRows,
      syncTypeRows: syncTypeRows,
      activityBuckets: activityBuckets,
      recentCheckIns: recentCheckIns.take(8).toList(),
    );
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
            printed: entry.value.printed,
          ),
        )
        .toList();
  }

  static List<_BreakdownRow> _buildAgeBreakdown(List<Participant> participants) {
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
    }

    return order
        .map(
          (label) => _BreakdownRow(
            label: label,
            total: grouped[label]!.total,
            checkedIn: grouped[label]!.checkedIn,
            printed: grouped[label]!.printed,
          ),
        )
        .toList();
  }

  static List<_BreakdownRow> _buildSyncBreakdown(List<_SyncTaskEntry> syncTasks) {
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
            printed: 0,
          ),
        )
        .toList();
    rows.sort((a, b) => b.total.compareTo(a.total));
    return rows;
  }

  static List<_ActivityBucket> _buildActivityBuckets(List<Participant> checkedIn) {
    final now = DateTime.now();
    final start = DateTime(now.year, now.month, now.day, now.hour)
        .subtract(const Duration(hours: 7));
    final buckets = List.generate(
      8,
      (index) => _ActivityBucket(
        start: start.add(Duration(hours: index)),
        count: 0,
      ),
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

  static String _normalizeLabel(String? raw, String fallback) {
    if (!_hasText(raw)) {
      return fallback;
    }
    return raw!.trim();
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
  final int printed;

  const _BreakdownRow({
    required this.label,
    required this.total,
    required this.checkedIn,
    required this.printed,
  });

  int get pending => total - checkedIn;
}

class _BreakdownAccumulator {
  int total = 0;
  int checkedIn = 0;
  int printed = 0;
}

class _ActivityBucket {
  final DateTime start;
  final int count;

  const _ActivityBucket({
    required this.start,
    required this.count,
  });
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
