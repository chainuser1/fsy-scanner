import 'dart:async';
import 'package:flutter/material.dart';

import '../app.dart';
import '../db/database_helper.dart';
import '../db/participants_dao.dart';
import '../models/participant.dart';
import '../print/printer_service.dart';
import '../utils/device_id.dart';
import 'confirm_screen.dart';

class ParticipantsScreen extends StatefulWidget {
  const ParticipantsScreen({super.key});

  @override
  State<ParticipantsScreen> createState() => _ParticipantsScreenState();
}

class _ParticipantsScreenState extends State<ParticipantsScreen> {
  final TextEditingController _searchController = TextEditingController();
  List<Participant> _allParticipants = [];
  List<Participant> _filteredParticipants = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadParticipants();
  }

  Future<void> _loadParticipants() async {
    try {
      final db = await DatabaseHelper.database;
      final dao = ParticipantsDao(db);
      final participants = await dao.getAllParticipants();
      setState(() {
        _allParticipants = participants;
        _filteredParticipants = participants;
        _isLoading = false;
      });
    } catch (e) {
      setState(() => _isLoading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error loading participants: $e')),
        );
      }
    }
  }

  void _filterParticipants(String query) {
    setState(() {
      if (query.isEmpty) {
        _filteredParticipants = _allParticipants;
      } else {
        _filteredParticipants = _allParticipants
            .where(
                (p) => p.fullName.toLowerCase().contains(query.toLowerCase()))
            .toList();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final verifiedCount =
        _allParticipants.where((p) => p.verifiedAt != null).length;

    return Scaffold(
      appBar: AppBar(title: const Text('Participants')),
      body: RefreshIndicator(
        onRefresh: _loadParticipants,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Autocomplete<Participant>(
                optionsBuilder: (textEditingValue) {
                  if (textEditingValue.text.isEmpty) {
                    return const Iterable<Participant>.empty();
                  }
                  return _allParticipants.where((p) => p.fullName
                      .toLowerCase()
                      .contains(textEditingValue.text.toLowerCase()));
                },
                displayStringForOption: (option) => option.fullName,
                fieldViewBuilder:
                    (context, controller, focusNode, onSubmitted) {
                  _searchController.text = controller.text;
                  return TextField(
                    controller: controller,
                    focusNode: focusNode,
                    decoration: const InputDecoration(
                      labelText: 'Search participants',
                      prefixIcon: Icon(Icons.search),
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (value) {
                      _filterParticipants(value);
                      onSubmitted();
                    },
                  );
                },
                optionsViewBuilder: (context, onSelected, options) {
                  return Align(
                    alignment: Alignment.topLeft,
                    child: Material(
                      child: SizedBox(
                        width: MediaQuery.of(context).size.width * 0.9,
                        child: ListView.builder(
                          shrinkWrap: true,
                          itemCount: options.length,
                          itemBuilder: (context, index) {
                            final participant = options.elementAt(index);
                            return ListTile(
                              title: Text(participant.fullName),
                              subtitle: Text(
                                  '${participant.stake ?? ""} • ${participant.ward ?? ""}'),
                              onTap: () => onSelected(participant),
                            );
                          },
                        ),
                      ),
                    ),
                  );
                },
                onSelected: (participant) {
                  if (!participant.verifiedAt) {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) =>
                            ConfirmScreen(participant: participant),
                      ),
                    ).then((_) => _loadParticipants());
                  } else {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                          content: Text(
                              '${participant.fullName} is already checked in')),
                    );
                  }
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0),
              child: Row(
                children: [
                  Text('Total: ${_allParticipants.length}'),
                  const SizedBox(width: 16),
                  Text('Checked in: $verifiedCount'),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : _filteredParticipants.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.people_outline,
                                  size: 64, color: Colors.grey[400]),
                              const SizedBox(height: 16),
                              Text('No participants found',
                                  style: TextStyle(color: Colors.grey[600])),
                            ],
                          ),
                        )
                      : ListView.builder(
                          itemCount: _filteredParticipants.length,
                          itemBuilder: (context, index) {
                            final participant = _filteredParticipants[index];
                            final isVerified = participant.verifiedAt != null;
                            return Card(
                              child: ListTile(
                                title: Text(participant.fullName),
                                subtitle: Text(
                                  '${participant.stake ?? ""} • ${participant.ward ?? ""}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
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
                                          unawaited(PrinterService.printReceipt(
                                              participant, deviceId));
                                          if (mounted) {
                                            ScaffoldMessenger.of(context)
                                                .showSnackBar(
                                              SnackBar(
                                                  content: Text(
                                                      'Printing receipt for ${participant.fullName}')),
                                            );
                                          }
                                        },
                                      ),
                                    Icon(
                                      isVerified
                                          ? Icons.check_circle
                                          : Icons.circle_outlined,
                                      color: isVerified
                                          ? FSYScannerApp.accentGreen
                                          : Colors.grey[400],
                                    ),
                                  ],
                                ),
                                onTap: () async {
                                  if (!isVerified) {
                                    await Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (context) => ConfirmScreen(
                                            participant: participant),
                                      ),
                                    );
                                    _loadParticipants();
                                  } else {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                          content: Text(
                                              '${participant.fullName} is already checked in')),
                                    );
                                  }
                                },
                              ),
                            );
                          },
                        ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }
}
