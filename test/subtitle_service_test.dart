import 'package:flutter_test/flutter_test.dart';
import 'package:vplayer/services/subtitle_service.dart';

void main() {
  group('parseSrt', () {
    test('parses standard cues', () {
      const srt = '''
1
00:00:01,000 --> 00:00:03,000
Hello

2
00:00:04,000 --> 00:00:06,500
World
Line two
''';
      final cues = parseSrt(srt);
      expect(cues.length, 2);
      expect(cues[0].startMs, 1000);
      expect(cues[0].endMs, 3000);
      expect(cues[0].text, 'Hello');
      expect(cues[1].text, 'World\nLine two');
    });

    test('handles CRLF and dot millisecond separators', () {
      const srt =
          '1\r\n00:00:01.500 --> 00:00:02.500\r\nHi\r\n\r\n';
      final cues = parseSrt(srt);
      expect(cues.length, 1);
      expect(cues[0].startMs, 1500);
    });

    test('tolerates missing cue index', () {
      const srt = '00:00:01,000 --> 00:00:02,000\nNo index';
      final cues = parseSrt(srt);
      expect(cues.length, 1);
      expect(cues[0].text, 'No index');
    });

    test('drops invalid timing and empty text', () {
      const srt = '''
1
00:00:05,000 --> 00:00:03,000
Backwards

2
garbage --> garbage
Bad

3
00:00:01,000 --> 00:00:02,000
''';
      expect(parseSrt(srt), isEmpty);
    });

    test('sorts by start time', () {
      const srt = '''
1
00:00:10,000 --> 00:00:11,000
Second

2
00:00:01,000 --> 00:00:02,000
First
''';
      final cues = parseSrt(srt);
      expect(cues[0].text, 'First');
      expect(cues[1].text, 'Second');
    });

    test('empty input yields no cues', () {
      expect(parseSrt(''), isEmpty);
      expect(parseSrt('   \n\n  '), isEmpty);
    });
  });

  group('getActiveSubtitleText', () {
    final cues = [
      const SubtitleCue(startMs: 1000, endMs: 2000, text: 'a'),
      const SubtitleCue(startMs: 3000, endMs: 4000, text: 'b'),
    ];

    test('returns cue for time inside range (inclusive)', () {
      expect(getActiveSubtitleText(cues, 1.0), 'a');
      expect(getActiveSubtitleText(cues, 2.0), 'a');
      expect(getActiveSubtitleText(cues, 3.5), 'b');
    });

    test('returns null outside ranges', () {
      expect(getActiveSubtitleText(cues, 0.5), null);
      expect(getActiveSubtitleText(cues, 2.5), null);
      expect(getActiveSubtitleText(cues, 5.0), null);
    });
  });
}
