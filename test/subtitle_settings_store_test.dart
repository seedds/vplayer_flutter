import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vplayer/services/subtitle_settings_store.dart';

void main() {
  late Directory tempDir;
  late SubtitleSettingsStore store;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('vplayer_subs');
    store = SubtitleSettingsStore(tempDir.path);
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  test('defaults when no file exists', () async {
    expect(await store.getSubtitleFontSize(), defaultSubtitleFontSize);
  });

  test('save and read back font size', () async {
    expect(await store.saveSubtitleFontSize(44), 44);
    expect(await store.getSubtitleFontSize(), 44);
  });

  test('persists to disk in expected JSON shape', () async {
    await store.saveSubtitleFontSize(28);
    final raw = await File('${tempDir.path}/subtitle-settings.json')
        .readAsString();
    final parsed = jsonDecode(raw) as Map<String, Object?>;
    expect(parsed['subtitleFontSize'], 28);
  });

  test('reload from a fresh store instance', () async {
    await store.saveSubtitleFontSize(40);
    final fresh = SubtitleSettingsStore(tempDir.path);
    expect(await fresh.getSubtitleFontSize(), 40);
  });

  test('clamps out-of-range values on save', () async {
    expect(await store.saveSubtitleFontSize(5), minSubtitleFontSize);
    expect(await store.saveSubtitleFontSize(500), maxSubtitleFontSize);
  });

  test('clamps out-of-range values on read', () async {
    await File('${tempDir.path}/subtitle-settings.json')
        .writeAsString(jsonEncode({'subtitleFontSize': 999}));
    expect(await store.getSubtitleFontSize(), maxSubtitleFontSize);
  });

  test('recovers from corrupt file', () async {
    await File('${tempDir.path}/subtitle-settings.json')
        .writeAsString('not json{');
    expect(await store.getSubtitleFontSize(), defaultSubtitleFontSize);
  });
}
