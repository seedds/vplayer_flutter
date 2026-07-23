import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Persists a single clamped integer setting in a JSON file under the app
/// documents directory (`{ "<jsonKey>": <int> }`).
///
/// Reads are cached in memory; writes are serialized through a mutation queue
/// so overlapping saves can't interleave their file writes. Out-of-range and
/// corrupt values fall back to [defaultValue] (on read) or the nearest bound
/// (on save).
class ClampedIntSettingStore {
  ClampedIntSettingStore({
    required this.documentsPath,
    required this.fileName,
    required this.jsonKey,
    required this.min,
    required this.max,
    required this.defaultValue,
  });

  final String documentsPath;
  final String fileName;
  final String jsonKey;
  final int min;
  final int max;
  final int defaultValue;

  int? _cache;
  Future<void> _mutationQueue = Future.value();

  String get _filePath => p.join(documentsPath, fileName);

  /// Rounds and clamps [input] into `[min, max]`, or returns [fallback] when
  /// [input] isn't a finite number.
  static int clampValue(
    Object? input, {
    required int min,
    required int max,
    required int fallback,
  }) {
    if (input is! num || !input.isFinite) return fallback;
    return input.round().clamp(min, max);
  }

  int clamp(Object? input) =>
      clampValue(input, min: min, max: max, fallback: defaultValue);

  Future<int> read() async {
    final cached = _cache;
    if (cached != null) return cached;

    final file = File(_filePath);
    if (!await file.exists()) return _cache = defaultValue;
    try {
      final parsed = jsonDecode(await file.readAsString());
      final value = parsed is Map<String, Object?> ? parsed[jsonKey] : null;
      return _cache = clamp(value);
    } catch (_) {
      return _cache = defaultValue;
    }
  }

  Future<int> write(int value) async {
    final clamped = clamp(value);
    final next = _mutationQueue.catchError((_) {}).then((_) async {
      _cache = clamped;
      await File(_filePath).writeAsString(jsonEncode({jsonKey: clamped}));
    });
    _mutationQueue = next;
    await next;
    return clamped;
  }
}
