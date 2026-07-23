import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vplayer/services/video_library.dart';

void main() {
  group('sanitizeFileName', () {
    test('replaces illegal characters and lowercases extension', () {
      expect(VideoLibrary.sanitizeFileName('My/Video?.MP4'), 'Video_.mp4');
      expect(VideoLibrary.sanitizeFileName('héllo wörld.mkv'),
          'h_llo w_rld.mkv');
    });

    test('collapses whitespace and trims base name', () {
      expect(VideoLibrary.sanitizeFileName('a   b .mp4'), 'a b.mp4');
    });

    test('falls back to upload for empty names', () {
      expect(VideoLibrary.sanitizeFileName(''), 'upload');
      expect(VideoLibrary.sanitizeFileName('///'), 'upload');
    });

    test('strips trailing dot runs in the base name', () {
      expect(VideoLibrary.sanitizeFileName('movie....mp4'), 'movie.mp4');
    });
  });

  group('sanitizeFolderName', () {
    test('neutralizes traversal segments', () {
      expect(VideoLibrary.sanitizeFolderName('..'), 'folder');
      expect(VideoLibrary.sanitizeFolderName('.'), 'folder');
    });

    test('keeps allowed characters', () {
      expect(VideoLibrary.sanitizeFolderName('Season 1'), 'Season 1');
    });
  });

  group('normalizeLibraryFilePath', () {
    test('sanitizes every segment', () {
      expect(VideoLibrary.normalizeLibraryFilePath('a/../b/c?.mp4'),
          'a/folder/b/c_.mp4');
    });

    test('empty input yields upload', () {
      expect(VideoLibrary.normalizeLibraryFilePath(''), 'upload');
    });
  });

  group('extension rules', () {
    test('detects allowed video extensions', () {
      expect(VideoLibrary.isAllowedVideoFileName('a.MP4'), true);
      expect(VideoLibrary.isAllowedVideoFileName('a.mkv'), true);
      expect(VideoLibrary.isAllowedVideoFileName('a.avi'), false);
    });

    test('detects subtitle extension', () {
      expect(VideoLibrary.isAllowedSubtitleFileName('a.srt'), true);
      expect(VideoLibrary.isAllowedSubtitleFileName('a.vtt'), false);
    });
  });

  group('compareNatural', () {
    test('numeric-aware, case-insensitive', () {
      final names = ['Episode 10.mp4', 'episode 2.mp4', 'Episode 1.mp4'];
      names.sort(VideoLibrary.compareNatural);
      expect(names,
          ['Episode 1.mp4', 'episode 2.mp4', 'Episode 10.mp4']);
    });
  });

  group('filesystem operations', () {
    late Directory tempDir;
    late VideoLibrary library;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('vplayer_test');
      library = VideoLibrary(tempDir.path);
      await library.ensureAppDirectories();
    });

    tearDown(() async {
      await tempDir.delete(recursive: true);
    });

    test('lists folders first then files, sorted naturally', () async {
      await File('${library.videoDirectory}/b.mp4').writeAsString('x');
      await File('${library.videoDirectory}/a.mp4').writeAsString('x');
      await Directory('${library.videoDirectory}/zfolder').create();

      final items = await library.listLibraryItems();
      expect(items.map((i) => i.name).toList(), ['zfolder', 'a.mp4', 'b.mp4']);
    });

    test('createUploadTarget sanitizes and creates parent dirs', () async {
      final target =
          await library.createUploadTarget('Shows/S1/Ep?1.MP4');
      expect(target.relativePath, 'Shows/S1/Ep_1.mp4');
      expect(
          await Directory(library.directoryPathFor('Shows/S1')).exists(), true);
    });

    test('rename rejects collisions', () async {
      await File('${library.videoDirectory}/a.mp4').writeAsString('x');
      await File('${library.videoDirectory}/b.mp4').writeAsString('x');
      expect(
        () => library.renameLibraryItem('a.mp4', 'file', 'b.mp4'),
        throwsException,
      );
    });

    test('move rejects moving folder into itself', () async {
      await Directory('${library.videoDirectory}/f').create();
      expect(
        () => library.moveLibraryItem('f', 'folder', 'f'),
        throwsException,
      );
    });

    test('findMatchingSubtitlePath matches basename case-insensitively',
        () async {
      await File('${library.videoDirectory}/Movie.mp4').writeAsString('x');
      await File('${library.videoDirectory}/movie.srt').writeAsString('x');
      final video = (await library.listLibraryItems())
          .firstWhere((i) => i.name == 'Movie.mp4');
      final subtitle = await library.findMatchingSubtitlePath(video);
      expect(subtitle, isNotNull);
      expect(subtitle!.endsWith('movie.srt'), true);
    });

    test('listAllVideoItems recurses folders', () async {
      await Directory('${library.videoDirectory}/f').create();
      await File('${library.videoDirectory}/f/inner.mp4').writeAsString('x');
      await File('${library.videoDirectory}/outer.mp4').writeAsString('x');
      final videos = await library.listAllVideoItems();
      expect(videos.map((v) => v.relativePath).toSet(),
          {'f/inner.mp4', 'outer.mp4'});
    });

    test('collectPlaybackArtifactVideos de-duplicates overlapping targets',
        () async {
      await Directory('${library.videoDirectory}/f').create();
      await File('${library.videoDirectory}/f/inner.mp4').writeAsString('x');

      final folder = (await library.listLibraryItems())
          .firstWhere((i) => i.name == 'f');
      final video = (await library.listLibraryItems('f'))
          .firstWhere((i) => i.name == 'inner.mp4');

      // Folder expands to inner.mp4, and the video is also passed directly:
      // the shared collector should still yield exactly one entry.
      final videos =
          await library.collectPlaybackArtifactVideos([folder, video]);
      expect(videos.map((v) => v.relativePath).toList(), ['f/inner.mp4']);
    });
  });
}
