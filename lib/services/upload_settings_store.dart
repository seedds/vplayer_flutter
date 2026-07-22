import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

const minMaxParallelUploads = 1;
const maxMaxParallelUploads = 5;
const defaultMaxParallelUploads = 3;

int clampMaxParallelUploads(Object? input) {
  if (input is! num || !input.isFinite) return defaultMaxParallelUploads;
  return input.round().clamp(minMaxParallelUploads, maxMaxParallelUploads);
}

/// Persists upload settings in `<documents>/upload-settings.json`.
class UploadSettingsStore {
  UploadSettingsStore(this.documentsPath);

  final String documentsPath;

  int? _cache;
  Future<void> _mutationQueue = Future.value();

  String get _filePath => p.join(documentsPath, 'upload-settings.json');

  Future<int> getMaxParallelUploads() async {
    final cached = _cache;
    if (cached != null) return cached;

    final file = File(_filePath);
    if (!await file.exists()) {
      return _cache = defaultMaxParallelUploads;
    }
    try {
      final parsed = jsonDecode(await file.readAsString());
      final value =
          parsed is Map<String, Object?> ? parsed['maxParallelUploads'] : null;
      return _cache = clampMaxParallelUploads(value);
    } catch (_) {
      return _cache = defaultMaxParallelUploads;
    }
  }

  Future<int> saveMaxParallelUploads(int value) async {
    final clamped = clampMaxParallelUploads(value);
    final next = _mutationQueue.catchError((_) {}).then((_) async {
      _cache = clamped;
      await File(_filePath)
          .writeAsString(jsonEncode({'maxParallelUploads': clamped}));
    });
    _mutationQueue = next;
    await next;
    return clamped;
  }
}
