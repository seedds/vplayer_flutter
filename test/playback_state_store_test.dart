import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vplayer/services/playback_state_store.dart';

void main() {
  late Directory tempDir;
  late PlaybackStateStore store;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('vplayer_pbs');
    store = PlaybackStateStore(tempDir.path);
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  test('save and read back position', () async {
    await store.savePosition('/v/a.mp4', 42.5, 100);
    expect(await store.getSavedPosition('/v/a.mp4'), 42.5);

    final state = await store.load();
    expect(state['/v/a.mp4']!.durationSeconds, 100);
    expect(state['/v/a.mp4']!.hasStartedPlayback, true);
  });

  test('persists to disk in expected JSON shape', () async {
    await store.savePosition('/v/a.mp4', 10, 60);
    final raw = await File('${tempDir.path}/playback-state.json')
        .readAsString();
    final parsed = jsonDecode(raw) as Map<String, Object?>;
    final entry = parsed['/v/a.mp4'] as Map<String, Object?>;
    expect(entry['positionSeconds'], 10);
    expect(entry['durationSeconds'], 60);
    expect(entry['hasStartedPlayback'], true);
  });

  test('reload from a fresh store instance', () async {
    await store.savePosition('/v/a.mp4', 10, 60);
    final fresh = PlaybackStateStore(tempDir.path);
    expect(await fresh.getSavedPosition('/v/a.mp4'), 10);
  });

  test('saveDuration keeps existing progress', () async {
    await store.savePosition('/v/a.mp4', 12);
    await store.saveDuration('/v/a.mp4', 90);
    final state = await store.load();
    expect(state['/v/a.mp4']!.positionSeconds, 12);
    expect(state['/v/a.mp4']!.durationSeconds, 90);
  });

  test('clearAllProgress resets position but keeps duration', () async {
    await store.savePosition('/v/a.mp4', 42, 100);
    await store.clearAllProgress();
    final state = await store.load();
    expect(state['/v/a.mp4']!.positionSeconds, 0);
    expect(state['/v/a.mp4']!.hasStartedPlayback, false);
    expect(state['/v/a.mp4']!.durationSeconds, 100);
  });

  test('clearProgressFor only touches listed paths', () async {
    await store.savePosition('/v/a.mp4', 42, 100);
    await store.savePosition('/v/b.mp4', 20, 50);
    await store.clearProgressFor(['/v/a.mp4']);
    final state = await store.load();
    expect(state['/v/a.mp4']!.positionSeconds, 0);
    expect(state['/v/b.mp4']!.positionSeconds, 20);
  });

  test('recovers from corrupt file', () async {
    await File('${tempDir.path}/playback-state.json')
        .writeAsString('not json{');
    expect(await store.load(), isEmpty);
  });

  test('rejects invalid positions', () async {
    await store.savePosition('/v/a.mp4', -5);
    await store.savePosition('/v/a.mp4', double.nan);
    expect(await store.load(), isEmpty);
  });
}
