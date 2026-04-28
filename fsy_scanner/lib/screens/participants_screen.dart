import 'dart:async';
import 'package:flutter/material.dart';

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
      setState(() {
        _isLoading = false;
      });
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
            .where((p) => p.fullName.toLowerCase().contains(query.toLowerCase()))
            .toList();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final registeredCount = _allParticipants.where((p) => p.registered == 1).length;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Participants'),
        backgroundColor: Colors.blue[600],
        foregroundColor: Colors.white,
      ),
      body: Column(
        children: [
          // Search bar
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: TextField(
              controller: _searchController,
              decoration: const InputDecoration(
                labelText: 'Search participants',
                prefixIcon: Icon(Icons.search),
                border: OutlineInputBorder(),
              ),
              onChanged: _filterParticipants,
            ),
          ),

          // Counts
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0),
            child: Row(
              children: [
                Text('Total: ${_allParticipants.length}'),
                const SizedBox(width: 16),
                Text('Registered: $registeredCount'),
              ],
            ),
          ),

          const SizedBox(height: 16),

          // Participants list
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : ListView.builder(
                    itemCount: _filteredParticipants.length,
                    itemBuilder: (context, index) {
                      final participant = _filteredParticipants[index];
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
                              if (participant.registered == 1)
                                IconButton(
                                  icon: const Icon(Icons.print, color: Colors.blue),
                                  tooltip: 'Reprint receipt',
                                  onPressed: () async {
                                    final deviceId = await DeviceId.get();
                                    unawaited(PrinterService.printReceipt(participant, deviceId));
                                    if (mounted) {
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        SnackBar(content: Text('Printing receipt for ${participant.fullName}')),
                                      );
                                    }
                                  },
                                ),
                              participant.registered == 1
                                  ? Icon(Icons.check_circle, color: Colors.green[600])
                                  : Icon(Icons.circle_outlined, color: Colors.grey[400]),
                            ],
                          ),
                          onTap: () async {
                            if (participant.registered == 0) {
                              await Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (context) => ConfirmScreen(participant: participant),
                                ),
                              );
                              _loadParticipants();
                            } else {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text('${participant.fullName} is already registered')),
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
    );
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }
}