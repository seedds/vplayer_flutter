import 'dart:io';

class SubtitleCue {
  const SubtitleCue({
    required this.startMs,
    required this.endMs,
    required this.text,
  });

  final int startMs;
  final int endMs;
  final String text;
}

int? _parseTimestamp(String input) {
  final match = RegExp(r'^(\d{2}):(\d{2}):(\d{2})[,.](\d{3})$')
      .firstMatch(input.trim());
  if (match == null) return null;
  final hours = int.parse(match.group(1)!);
  final minutes = int.parse(match.group(2)!);
  final seconds = int.parse(match.group(3)!);
  final milliseconds = int.parse(match.group(4)!);
  return ((hours * 60 + minutes) * 60 + seconds) * 1000 + milliseconds;
}

/// Parses SRT contents. Tolerates missing cue indices, CRLF/CR line endings,
/// and dot millisecond separators. Drops cues with invalid timing or no text.
List<SubtitleCue> parseSrt(String input) {
  final normalized =
      input.replaceAll('\r\n', '\n').replaceAll('\r', '\n').trim();
  if (normalized.isEmpty) return [];

  final cues = <SubtitleCue>[];
  for (final block in normalized.split(RegExp(r'\n\s*\n'))) {
    final lines = block
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();
    final timingIndex = lines.indexWhere((line) => line.contains('-->'));
    if (timingIndex == -1) continue;

    final parts = lines[timingIndex].split('-->');
    if (parts.length < 2) continue;
    final startMs = _parseTimestamp(parts[0]);
    final endMs = _parseTimestamp(parts[1]);
    if (startMs == null || endMs == null || endMs <= startMs) continue;

    final text = lines.sublist(timingIndex + 1).join('\n').trim();
    if (text.isEmpty) continue;

    cues.add(SubtitleCue(startMs: startMs, endMs: endMs, text: text));
  }
  cues.sort((a, b) => a.startMs.compareTo(b.startMs));
  return cues;
}

Future<List<SubtitleCue>> loadSrtFile(String path) async {
  final contents = await File(path).readAsString();
  return parseSrt(contents);
}

String? getActiveSubtitleText(
    List<SubtitleCue> cues, double currentTimeSeconds) {
  final currentTimeMs =
      (currentTimeSeconds * 1000).floor().clamp(0, 1 << 62);
  for (final cue in cues) {
    if (currentTimeMs >= cue.startMs && currentTimeMs <= cue.endMs) {
      return cue.text;
    }
  }
  return null;
}
