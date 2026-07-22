import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

class PlaybackStateEntry {
  const PlaybackStateEntry({
    required this.positionSeconds,
    required this.updatedAt,
    this.durationSeconds,
    this.hasStartedPlayback,
  });

  final double positionSeconds;
  final int updatedAt;
  final double? durationSeconds;
  final bool? hasStartedPlayback;

  Map<String, Object?> toJson() => {
        'positionSeconds': positionSeconds,
        'updatedAt': updatedAt,
        if (durationSeconds != null) 'durationSeconds': durationSeconds,
        if (hasStartedPlayback != null)
          'hasStartedPlayback': hasStartedPlayback,
      };

  static PlaybackStateEntry? fromJson(Object? json) {
    if (json is! Map<String, Object?>) return null;
    final position = json['positionSeconds'];
    if (position is! num) return null;
    final duration = json['durationSeconds'];
    final started = json['hasStartedPlayback'];
    final updatedAt = json['updatedAt'];
    return PlaybackStateEntry(
      positionSeconds: position.toDouble(),
      updatedAt: updatedAt is num ? updatedAt.toInt() : 0,
      durationSeconds: duration is num ? duration.toDouble() : null,
      hasStartedPlayback: started is bool ? started : null,
    );
  }
}

/// JSON-file-backed playback progress store, keyed by absolute video path.
/// Writes are serialized through a mutation queue; every save rewrites the
/// whole file (same model as the original app).
class PlaybackStateStore {
  PlaybackStateStore(this.documentsPath);

  final String documentsPath;

  Map<String, PlaybackStateEntry>? _cache;
  Future<void> _mutationQueue = Future.value();

  String get _filePath => p.join(documentsPath, 'playback-state.json');

  Future<Map<String, PlaybackStateEntry>> load() async {
    final cached = _cache;
    if (cached != null) return cached;

    final file = File(_filePath);
    if (!await file.exists()) {
      return _cache = {};
    }
    try {
      final raw = await file.readAsString();
      final parsed = jsonDecode(raw);
      final result = <String, PlaybackStateEntry>{};
      if (parsed is Map<String, Object?>) {
        for (final entry in parsed.entries) {
          final value = PlaybackStateEntry.fromJson(entry.value);
          if (value != null) result[entry.key] = value;
        }
      }
      return _cache = result;
    } catch (_) {
      return _cache = {};
    }
  }

  Future<void> _update(
      Map<String, PlaybackStateEntry>? Function(
              Map<String, PlaybackStateEntry> state)
          updater) {
    final next = _mutationQueue.catchError((_) {}).then((_) async {
      final state = await load();
      final nextState = updater(state);
      if (nextState == null) return;
      _cache = nextState;
      final json = <String, Object?>{
        for (final entry in nextState.entries) entry.key: entry.value.toJson(),
      };
      await File(_filePath).writeAsString(jsonEncode(json));
    });
    _mutationQueue = next;
    return next;
  }

  Future<double> getSavedPosition(String path) async {
    final state = await load();
    return state[path]?.positionSeconds ?? 0;
  }

  Future<void> savePosition(String path, double positionSeconds,
      [double? durationSeconds]) async {
    if (!positionSeconds.isFinite || positionSeconds < 0) return;
    await _update((state) {
      final previous = state[path];
      return {
        ...state,
        path: PlaybackStateEntry(
          positionSeconds: positionSeconds,
          updatedAt: DateTime.now().millisecondsSinceEpoch,
          durationSeconds: durationSeconds != null &&
                  durationSeconds.isFinite &&
                  durationSeconds >= 0
              ? durationSeconds
              : previous?.durationSeconds,
          hasStartedPlayback: true,
        ),
      };
    });
  }

  Future<void> saveDuration(String path, double durationSeconds) async {
    if (!durationSeconds.isFinite || durationSeconds < 0) return;
    await _update((state) {
      final previous = state[path];
      return {
        ...state,
        path: PlaybackStateEntry(
          positionSeconds: previous?.positionSeconds ?? 0,
          updatedAt: DateTime.now().millisecondsSinceEpoch,
          durationSeconds: durationSeconds,
          hasStartedPlayback: previous?.hasStartedPlayback ?? false,
        ),
      };
    });
  }

  /// Resets position/started flags for every entry, keeping durations.
  Future<void> clearAllProgress() async {
    await _update((state) => {
          for (final entry in state.entries)
            entry.key: PlaybackStateEntry(
              positionSeconds: 0,
              updatedAt: DateTime.now().millisecondsSinceEpoch,
              durationSeconds: entry.value.durationSeconds,
              hasStartedPlayback: false,
            ),
        });
  }

  Future<void> clearProgressFor(Iterable<String> paths) async {
    final targets = paths.toSet();
    if (targets.isEmpty) return;
    await _update((state) {
      var didUpdate = false;
      final next = Map<String, PlaybackStateEntry>.of(state);
      for (final path in targets) {
        final entry = state[path];
        if (entry == null) continue;
        next[path] = PlaybackStateEntry(
          positionSeconds: 0,
          updatedAt: DateTime.now().millisecondsSinceEpoch,
          durationSeconds: entry.durationSeconds,
          hasStartedPlayback: false,
        );
        didUpdate = true;
      }
      return didUpdate ? next : null;
    });
  }
}
