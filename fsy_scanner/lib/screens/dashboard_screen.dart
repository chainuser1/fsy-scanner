import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app.dart';
import '../db/database_helper.dart';
import '../db/participants_dao.dart';
import '../models/participant.dart';
import '../providers/app_state.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  List<Participant> all = [];
  bool loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final db = await DatabaseHelper.database;
    final dao = ParticipantsDao(db);
    setState(() => loading = true);
    all = await dao.getAllParticipants();
    all.sort((a, b) => (b.verifiedAt ?? 0).compareTo(a.verifiedAt ?? 0));
    setState(() => loading = false);
  }

  @override
  Widget build(BuildContext context) {
    Provider.of<AppState>(context); // listen for changes
    return Scaffold(
      appBar: AppBar(
        title: const Text('Dashboard'),
        actions: [
          IconButton(onPressed: _load, icon: const Icon(Icons.refresh)),
        ],
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.all(12),
                children: [
                  _buildOverallProgress(),
                  const SizedBox(height: 16),
                  _buildStakeChart(),
                  const SizedBox(height: 16),
                  _buildTopRooms(),
                  const SizedBox(height: 16),
                  _buildGenderPie(),
                  const SizedBox(height: 16),
                  _buildAgeGroups(),
                  const SizedBox(height: 16),
                  _buildRecentActivity(),
                ],
              ),
            ),
    );
  }

  Widget _buildOverallProgress() {
    final total = all.length;
    final verified = all.where((p) => p.verifiedAt != null).length;
    final verifiedD = verified.toDouble();
    final totalD = total.toDouble();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            const Text('Overall Check‑in Progress',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  flex: 3,
                  child: Column(
                    children: [
                      Text('$verified / $total',
                          style: const TextStyle(
                              fontSize: 32, fontWeight: FontWeight.w800)),
                      Text(
                        '${(total > 0 ? verified / total * 100 : 0).toStringAsFixed(1)}% completed',
                        style: const TextStyle(color: Colors.grey),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  flex: 2,
                  child: SizedBox(
                    height: 100,
                    child: PieChart(
                      PieChartData(
                        sectionsSpace: 2,
                        centerSpaceRadius: 30,
                        sections: [
                          PieChartSectionData(
                            value: verifiedD,
                            color: FSYScannerApp.accentGreen,
                            title: '',
                            radius: 18,
                          ),
                          PieChartSectionData(
                            value: totalD - verifiedD,
                            color: Colors.grey[300],
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

  Widget _buildStakeChart() {
    final grouped = <String, Map<String, int>>{};
    for (final p in all) {
      final stake = p.stake ?? 'Unknown';
      grouped.putIfAbsent(stake, () => {'total': 0, 'verified': 0});
      grouped[stake]!['total'] = grouped[stake]!['total']! + 1;
      if (p.verifiedAt != null) {
        grouped[stake]!['verified'] = grouped[stake]!['verified']! + 1;
      }
    }
    final stakes = grouped.entries.toList()
      ..sort((a, b) => b.value['verified']!.compareTo(a.value['verified']!));

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Stake Breakdown',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            ...stakes.map((e) {
              final stake = e.key;
              final total = e.value['total']!;
              final verified = e.value['verified']!;
              final pct = total > 0 ? verified / total : 0.0;
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    SizedBox(
                        width: 100,
                        child: Text(stake, overflow: TextOverflow.ellipsis)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: pct,
                          backgroundColor: Colors.grey[200],
                          valueColor: const AlwaysStoppedAnimation<Color>(
                              FSYScannerApp.accentGreen),
                          minHeight: 12,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text('$verified/$total',
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                  ],
                ),
              );
            }),
          ],
        ),
      ),
    );
  }

  Widget _buildTopRooms() {
    final roomMap = <String, Map<String, int>>{};
    for (final p in all) {
      final room = p.roomNumber ?? 'N/A';
      roomMap.putIfAbsent(room, () => {'total': 0, 'verified': 0});
      roomMap[room]!['total'] = roomMap[room]!['total']! + 1;
      if (p.verifiedAt != null) {
        roomMap[room]!['verified'] = roomMap[room]!['verified']! + 1;
      }
    }
    final rooms = roomMap.entries.toList()
      ..sort((a, b) => b.value['total']!.compareTo(a.value['total']!));
    final top10 = rooms.take(10).toList();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Top 10 Rooms by Occupancy',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            ...top10.map((e) {
              final room = e.key;
              final total = e.value['total']!;
              final verified = e.value['verified']!;
              final pct = total > 0 ? verified / total : 0.0;
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  children: [
                    SizedBox(width: 45, child: Text(room)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: pct,
                          backgroundColor: Colors.grey[200],
                          valueColor: AlwaysStoppedAnimation<Color>(pct >= 1.0
                              ? FSYScannerApp.accentGreen
                              : FSYScannerApp.accentGold),
                          minHeight: 10,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text('$verified/$total',
                        style: const TextStyle(fontSize: 12)),
                  ],
                ),
              );
            }),
          ],
        ),
      ),
    );
  }

  Widget _buildGenderPie() {
    final genderMap = <String, int>{};
    for (final p in all) {
      final gender = p.gender ?? 'Unknown';
      genderMap[gender] = (genderMap[gender] ?? 0) + 1;
    }
    final colors = [
      FSYScannerApp.accentGreen,
      FSYScannerApp.accentGold,
      FSYScannerApp.primaryBlue,
    ];
    final sections = genderMap.entries.toList().asMap().entries.map((entry) {
      final idx = entry.key;
      final e = entry.value;
      return PieChartSectionData(
        value: e.value.toDouble(),
        title: '${e.key}\n${e.value}',
        color: colors[idx % colors.length],
        radius: 28,
        titleStyle: const TextStyle(fontSize: 11, color: Colors.black87),
      );
    }).toList();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            const Text('Gender Distribution',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 16),
            SizedBox(
              height: 150,
              child: PieChart(PieChartData(
                sections: sections,
                sectionsSpace: 2,
                centerSpaceRadius: 25,
              )),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAgeGroups() {
    final ages =
        all.map((p) => p.age).where((a) => a != null).map((a) => a!).toList();
    if (ages.isEmpty) return const SizedBox.shrink();

    final groups = <String, int>{
      '13‑14': 0,
      '15‑16': 0,
      '17‑19': 0,
      '20+': 0,
    };
    for (final a in ages) {
      if (a <= 14) {
        groups['13‑14'] = groups['13‑14']! + 1;
      } else if (a <= 16) {
        groups['15‑16'] = groups['15‑16']! + 1;
      } else if (a <= 19) {
        groups['17‑19'] = groups['17‑19']! + 1;
      } else {
        groups['20+'] = groups['20+']! + 1;
      }
    }
    final maxVal = groups.values.reduce((a, b) => a > b ? a : b).toDouble();
    final barGroups = groups.entries.map((e) {
      final x = ['13‑14', '15‑16', '17‑19', '20+'].indexOf(e.key);
      return BarChartGroupData(
        x: x,
        barRods: [
          BarChartRodData(
            toY: e.value.toDouble(),
            color: FSYScannerApp.primaryBlue,
            width: 22,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
          ),
        ],
      );
    }).toList();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Age Distribution',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 16),
            SizedBox(
              height: 160,
              child: BarChart(
                BarChartData(
                  alignment: BarChartAlignment.spaceAround,
                  maxY: maxVal * 1.2,
                  barGroups: barGroups,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRecentActivity() {
    final now = DateTime.now();
    final oneDayAgo =
        now.subtract(const Duration(days: 1)).millisecondsSinceEpoch;
    final recent = all
        .where((p) => p.verifiedAt != null && p.verifiedAt! >= oneDayAgo)
        .toList();
    if (recent.isEmpty) return const SizedBox.shrink();

    final hourCounts = List.filled(24, 0);
    for (final p in recent) {
      final dt = DateTime.fromMillisecondsSinceEpoch(p.verifiedAt!);
      hourCounts[dt.hour]++;
    }
    final maxHour = hourCounts.reduce((a, b) => a > b ? a : b).toDouble();
    final barGroups = List.generate(24, (hour) {
      return BarChartGroupData(
        x: hour,
        barRods: [
          BarChartRodData(
            toY: hourCounts[hour].toDouble(),
            color: FSYScannerApp.accentGold,
            width: 6,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(2)),
          ),
        ],
      );
    });

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Check‑in Activity (Last 24h)',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 16),
            SizedBox(
              height: 160,
              child: BarChart(
                BarChartData(
                  alignment: BarChartAlignment.center,
                  maxY: maxHour * 1.2,
                  barGroups: barGroups,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
