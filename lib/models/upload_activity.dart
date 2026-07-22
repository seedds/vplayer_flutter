enum UploadStatus { idle, receiving, complete, error, stopped }

class ActiveUploadRow {
  const ActiveUploadRow({
    required this.uploadId,
    required this.fileName,
    required this.message,
    required this.updatedAt,
    required this.receivedBytes,
    required this.totalBytes,
  });

  final String uploadId;
  final String fileName;
  final String message;
  final int updatedAt;
  final int receivedBytes;
  final int totalBytes;
}

class UploadActivity {
  const UploadActivity({
    required this.status,
    required this.message,
    required this.updatedAt,
    this.activeUploads = const [],
    this.receivedBytes,
    this.totalBytes,
  });

  factory UploadActivity.simple(UploadStatus status, String message) =>
      UploadActivity(
        status: status,
        message: message,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      );

  final UploadStatus status;
  final String message;
  final int updatedAt;
  final List<ActiveUploadRow> activeUploads;
  final int? receivedBytes;
  final int? totalBytes;

  double get progress {
    final total = totalBytes;
    final received = receivedBytes;
    if (total == null || total <= 0 || received == null || received <= 0) {
      return status == UploadStatus.complete ? 1 : 0;
    }
    return (received / total).clamp(0.0, 1.0);
  }
}
