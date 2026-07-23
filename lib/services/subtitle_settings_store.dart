import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

const minSubtitleFontSize = 24;
const maxSubtitleFontSize = 48;
const defaultSubtitleFontSize = 36;

int clampSubtitleFontSize(Object? input) {
  if (input is! num || !input.isFinite) return defaultSubtitleFontSize;
  return input.round().clamp(minSubtitleFontSize, maxSubtitleFontSize);
}

/// Persists subtitle settings in `<documents>/subtitle-settings.json`.
class SubtitleSettingsStore {
  SubtitleSettingsStore(this.documentsPath);

  final String documentsPath;

  int? _cache;
  Future<void> _mutationQueue = Future.value();

  String get _filePath => p.join(documentsPath, 'subtitle-settings.json');

  Future<int> getSubtitleFontSize() async {
    final cached = _cache;
    if (cached != null) return cached;

    final file = File(_filePath);
    if (!await file.exists()) {
      return _cache = defaultSubtitleFontSize;
    }
    try {
      final parsed = jsonDecode(await file.readAsString());
      final value =
          parsed is Map<String, Object?> ? parsed['subtitleFontSize'] : null;
      return _cache = clampSubtitleFontSize(value);
    } catch (_) {
      return _cache = defaultSubtitleFontSize;
    }
  }

  Future<int> saveSubtitleFontSize(int value) async {
    final clamped = clampSubtitleFontSize(value);
    final next = _mutationQueue.catchError((_) {}).then((_) async {
      _cache = clamped;
      await File(_filePath)
          .writeAsString(jsonEncode({'subtitleFontSize': clamped}));
    });
    _mutationQueue = next;
    await next;
    return clamped;
  }
}
