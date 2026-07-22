import 'dart:async';
import 'dart:io';

import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path/path.dart' as p;

import '../models/library_item.dart';

const thumbnailTimeSeconds = 10;
const thumbnailMaxWidth = 240;
const thumbnailMaxHeight = 240;

/// Generates and caches library thumbnails under `<documents>/thumbnails/`.
///
/// Cache keys use the same DJB2-xor hash of
/// `path|size|modified|10|240|240` as the original app, so renames and
/// re-uploads invalidate naturally.
class ThumbnailService {
  ThumbnailService(this.documentsPath);

  final String documentsPath;

  String get thumbnailDirectory => p.join(documentsPath, 'thumbnails');

  Future<void> ensureThumbnailDirectory() async {
    await Directory(thumbnailDirectory).create(recursive: true);
  }

  static String hashString(String input) {
    var hash = 5381;
    for (var i = 0; i < input.length; i++) {
      hash = ((hash * 33) ^ input.codeUnitAt(i)) & 0xFFFFFFFF;
    }
    return hash.toRadixString(36);
  }

  String thumbnailTargetPath(LibraryItem video) {
    final cacheKey = hashString([
      video.path,
      video.size,
      video.modified,
      thumbnailTimeSeconds,
      thumbnailMaxWidth,
      thumbnailMaxHeight,
    ].join('|'));
    return p.join(thumbnailDirectory, '$cacheKey.jpg');
  }

  Future<String?> getCachedThumbnailPath(LibraryItem video) async {
    await ensureThumbnailDirectory();
    final target = thumbnailTargetPath(video);
    return await File(target).exists() ? target : null;
  }

  List<double> _candidateTimes(double? durationSeconds) {
    final preferred = durationSeconds != null &&
            durationSeconds.isFinite &&
            durationSeconds > 0
        ? thumbnailTimeSeconds
            .toDouble()
            .clamp(0.0, (durationSeconds - 1).clamp(0.0, double.infinity))
        : thumbnailTimeSeconds.toDouble();
    return preferred > 0 ? [preferred, 0] : [0];
  }

  /// Generates a thumbnail with a headless muted player: open paused, seek,
  /// screenshot, dispose. Returns the cached image path together with the
  /// runtime the player reported (null if it never became known), so callers
  /// can backfill duration without a separate playback.
  Future<({String path, double? durationSeconds})> generateThumbnailForVideo(
      LibraryItem video,
      [double? durationSeconds]) async {
    await ensureThumbnailDirectory();

    final player = Player(configuration: const PlayerConfiguration(muted: true));
    // Attaching a VideoController is what flips libmpv's `vid` from `no` to
    // `auto` (media_kit disables video decoding until a controller attaches),
    // so a bare headless player can never render a frame for screenshot().
    // Bound the output to the thumbnail size for a cheaper decode.
    final controller = VideoController(
      player,
      configuration: const VideoControllerConfiguration(
        width: thumbnailMaxWidth,
        height: thumbnailMaxHeight,
      ),
    );
    Object? lastError;
    try {
      await player.open(Media(video.path), play: false);
      await _waitForDuration(player);
      final observedDuration = _durationToSeconds(player.state.duration);

      // Ensure a frame is actually decoded before seeking/screenshotting.
      await controller.waitUntilFirstFrameRendered
          .timeout(const Duration(seconds: 4), onTimeout: () {});

      for (final time in _candidateTimes(durationSeconds)) {
        try {
          await player.seek(Duration(milliseconds: (time * 1000).round()));
          // Give the decoder a moment to render the seeked frame.
          await Future<void>.delayed(const Duration(milliseconds: 300));
          final bytes = await player.screenshot(format: 'image/jpeg');
          if (bytes != null && bytes.isNotEmpty) {
            final target = thumbnailTargetPath(video);
            await File(target).writeAsBytes(bytes, flush: true);
            return (path: target, durationSeconds: observedDuration);
          }
        } catch (error) {
          lastError = error;
        }
      }
    } finally {
      await player.dispose();
    }

    throw lastError is Exception
        ? lastError
        : Exception('Thumbnail generation returned no image.');
  }

  /// Opens the video headlessly just long enough to read its runtime, for
  /// videos whose thumbnail is already cached but whose duration was never
  /// stored. Returns null if the duration never became known.
  Future<double?> probeDurationSeconds(LibraryItem video) async {
    final player = Player(
      configuration: const PlayerConfiguration(
        vo: 'null',
        muted: true,
      ),
    );
    try {
      await player.open(Media(video.path), play: false);
      await _waitForDuration(player);
      return _durationToSeconds(player.state.duration);
    } catch (_) {
      return null;
    } finally {
      await player.dispose();
    }
  }

  double? _durationToSeconds(Duration duration) => duration > Duration.zero
      ? duration.inMicroseconds / Duration.microsecondsPerSecond
      : null;

  Future<void> _waitForDuration(Player player) async {
    if (player.state.duration > Duration.zero) return;
    try {
      await player.stream.duration
          .firstWhere((d) => d > Duration.zero)
          .timeout(const Duration(seconds: 4));
    } on TimeoutException {
      // proceed anyway; seek may still work
    }
  }

  Future<void> deleteThumbnailForVideo(LibraryItem video) async {
    await ensureThumbnailDirectory();
    try {
      final file = File(thumbnailTargetPath(video));
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  Future<void> pruneThumbnailCache(List<LibraryItem> videos) async {
    await ensureThumbnailDirectory();
    final validPaths = videos.map(thumbnailTargetPath).toSet();
    await for (final entry in Directory(thumbnailDirectory).list()) {
      if (!validPaths.contains(entry.path)) {
        try {
          await entry.delete();
        } catch (_) {}
      }
    }
  }
}
