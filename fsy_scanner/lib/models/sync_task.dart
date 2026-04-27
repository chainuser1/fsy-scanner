class SyncTask {
  final int? id;
  final String type;
  final String payload;
  final String status;
  final int attempts;
  final String? lastError;
  final int createdAt;
  final int? completedAt;

  SyncTask({
    this.id,
    required this.type,
    required this.payload,
    this.status = 'pending',
    this.attempts = 0,
    this.lastError,
    required this.createdAt,
    this.completedAt,
  });

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'type': type,
      'payload': payload,
      'status': status,
      'attempts': attempts,
      'last_error': lastError,
      'created_at': createdAt,
      'completed_at': completedAt,
    };
  }

  factory SyncTask.fromJson(Map<String, dynamic> json) {
    return SyncTask(
      id: json['id'],
      type: json['type'] ?? '',
      payload: json['payload'] ?? '',
      status: json['status'] ?? 'pending',
      attempts: json['attempts'] ?? 0,
      lastError: json['last_error'],
      createdAt: json['created_at'] ?? DateTime.now().millisecondsSinceEpoch,
      completedAt: json['completed_at'],
    );
  }
}
