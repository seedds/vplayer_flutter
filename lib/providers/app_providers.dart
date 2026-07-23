import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:network_info_plus/network_info_plus.dart';

import '../models/library_item.dart';
import '../models/upload_activity.dart';
import '../services/playback_state_store.dart';
import '../services/subtitle_settings_store.dart';
import '../services/thumbnail_service.dart';
import '../services/upload_server.dart';
import '../services/upload_settings_store.dart';
import '../services/video_library.dart';

const thumbnailHydrationConcurrency = 3;
const thumbnailHydrationMaxAttempts = 3;
const uploadConcurrencyOptions = [1, 2, 3, 4, 5];
const subtitleFontSizeOptions = [24, 28, 32, 36, 40, 44, 48];

// ---- service singletons (documentsPath is provided at bootstrap) ----------

final documentsPathProvider = Provider<String>(
  (ref) => throw UnimplementedError('overridden in main'),
);

final videoLibraryProvider = Provider<VideoLibrary>(
  (ref) => VideoLibrary(ref.watch(documentsPathProvider)),
);

final playbackStateStoreProvider = Provider<PlaybackStateStore>(
  (ref) => PlaybackStateStore(ref.watch(documentsPathProvider)),
);

final uploadSettingsStoreProvider = Provider<UploadSettingsStore>(
  (ref) => UploadSettingsStore(ref.watch(documentsPathProvider)),
);

final subtitleSettingsStoreProvider = Provider<SubtitleSettingsStore>(
  (ref) => SubtitleSettingsStore(ref.watch(documentsPathProvider)),
);

final thumbnailServiceProvider = Provider<ThumbnailService>(
  (ref) => ThumbnailService(ref.watch(documentsPathProvider)),
);

final uploadServerProvider = Provider<LocalUploadServer>(
  (ref) => LocalUploadServer(
    library: ref.watch(videoLibraryProvider),
    playbackStore: ref.watch(playbackStateStoreProvider),
    thumbnails: ref.watch(thumbnailServiceProvider),
  ),
);

// ---- library state ---------------------------------------------------------

class LibraryState {
  const LibraryState({
    this.loading = true,
    this.items = const [],
    this.playbackStateByPath = const {},
    this.currentFolderPath,
    this.revision = 0,
  });

  final bool loading;
  final List<LibraryItem> items;
  final Map<String, PlaybackStateEntry> playbackStateByPath;
  final String? currentFolderPath;
  final int revision;

  List<LibraryItem> get videoItems =>
      items.where((item) => item.isVideo).toList();

  LibraryState copyWith({
    bool? loading,
    List<LibraryItem>? items,
    Map<String, PlaybackStateEntry>? playbackStateByPath,
    String? Function()? currentFolderPath,
    int? revision,
  }) =>
      LibraryState(
        loading: loading ?? this.loading,
        items: items ?? this.items,
        playbackStateByPath: playbackStateByPath ?? this.playbackStateByPath,
        currentFolderPath: currentFolderPath != null
            ? currentFolderPath()
            : this.currentFolderPath,
        revision: revision ?? this.revision,
      );
}

String? parentPathOf(String? path) => VideoLibrary.parentPathOf(path);

class LibraryController extends Notifier<LibraryState> {
  @override
  LibraryState build() => const LibraryState();

  VideoLibrary get _library => ref.read(videoLibraryProvider);
  PlaybackStateStore get _playbackStore =>
      ref.read(playbackStateStoreProvider);

  Future<void> refresh([String? path = _unset]) async {
    var targetPath =
        identical(path, _unset) ? state.currentFolderPath : path;

    // Walk up if the folder disappeared.
    while (targetPath != null && targetPath.isNotEmpty) {
      final folder = await _library.getLibraryItem(targetPath, 'folder');
      if (folder != null && folder.isFolder) break;
      targetPath = parentPathOf(targetPath);
    }
    if (targetPath != null && targetPath.isEmpty) targetPath = null;

    final items = await _library.listLibraryItems(targetPath);
    final playbackState = await _playbackStore.load();
    final resolvedPath = targetPath;
    state = state.copyWith(
      loading: false,
      items: items,
      playbackStateByPath: Map.of(playbackState),
      currentFolderPath: () => resolvedPath,
      revision: state.revision + 1,
    );
  }

  Future<void> reloadPlaybackState() async {
    final playbackState = await _playbackStore.load();
    state = state.copyWith(playbackStateByPath: Map.of(playbackState));
  }

  static const _unset = '\u0000__unset__';
}

final libraryProvider =
    NotifierProvider<LibraryController, LibraryState>(LibraryController.new);

// ---- selection state -------------------------------------------------------

class SelectionState {
  const SelectionState({this.selectionMode = false, this.selected = const {}});

  final bool selectionMode;
  final Set<String> selected;
}

class SelectionController extends Notifier<SelectionState> {
  @override
  SelectionState build() => const SelectionState();

  void startWith(String path) =>
      state = SelectionState(selectionMode: true, selected: {path});

  void toggle(String path) {
    final next = Set<String>.of(state.selected);
    if (!next.remove(path)) next.add(path);
    state = next.isEmpty
        ? const SelectionState()
        : SelectionState(selectionMode: true, selected: next);
  }

  void cancel() => state = const SelectionState();

  /// Drop selections that no longer exist in the library.
  void prune(Iterable<String> validPaths) {
    if (state.selected.isEmpty) return;
    final valid = validPaths.toSet();
    final next = state.selected.where(valid.contains).toSet();
    if (next.length == state.selected.length) return;
    state = next.isEmpty
        ? const SelectionState()
        : SelectionState(selectionMode: true, selected: next);
  }
}

final selectionProvider =
    NotifierProvider<SelectionController, SelectionState>(
        SelectionController.new);

// ---- server state -----------------------------------------------------------

class ServerState {
  const ServerState({
    this.running = false,
    this.activePort,
    this.ipAddress,
    required this.activity,
  });

  final bool running;
  final int? activePort;
  final String? ipAddress;
  final UploadActivity activity;

  String? get serverUrl => running && ipAddress != null && activePort != null
      ? 'http://$ipAddress:$activePort'
      : null;

  ServerState copyWith({
    bool? running,
    int? Function()? activePort,
    String? Function()? ipAddress,
    UploadActivity? activity,
  }) =>
      ServerState(
        running: running ?? this.running,
        activePort: activePort != null ? activePort() : this.activePort,
        ipAddress: ipAddress != null ? ipAddress() : this.ipAddress,
        activity: activity ?? this.activity,
      );
}

class ServerController extends Notifier<ServerState> {
  Timer? _ipPollTimer;

  @override
  ServerState build() {
    ref.onDispose(() => _ipPollTimer?.cancel());
    return ServerState(
      activity: UploadActivity.simple(
          UploadStatus.idle, 'Starting local server...'),
    );
  }

  LocalUploadServer get _server => ref.read(uploadServerProvider);

  void _setActivity(UploadActivity activity) {
    state = state.copyWith(activity: activity);
  }

  Future<void> refreshNetwork() async {
    try {
      String? address = await NetworkInfo().getWifiIP();
      if (address == '0.0.0.0') address = null;
      address ??= await _fallbackLocalIp();
      state = state.copyWith(ipAddress: () => address);
    } catch (_) {}
    _syncIpPolling();
  }

  Future<String?> _fallbackLocalIp() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLinkLocal: false,
      );
      for (final interface in interfaces) {
        for (final addr in interface.addresses) {
          if (!addr.isLoopback && addr.address != '0.0.0.0') {
            return addr.address;
          }
        }
      }
    } catch (_) {}
    return null;
  }

  void _syncIpPolling() {
    final shouldPoll = state.running && state.ipAddress == null;
    if (shouldPoll && _ipPollTimer == null) {
      _ipPollTimer = Timer.periodic(const Duration(seconds: 2), (_) {
        refreshNetwork();
      });
    } else if (!shouldPoll) {
      _ipPollTimer?.cancel();
      _ipPollTimer = null;
    }
  }

  Future<({bool ok, int? reportedPort})> _probeExistingServer(int port) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(milliseconds: 1500);
    try {
      final request = await client
          .getUrl(Uri.parse('http://127.0.0.1:$port/health'))
          .timeout(const Duration(milliseconds: 1500));
      final response =
          await request.close().timeout(const Duration(milliseconds: 1500));
      if (response.statusCode != 200) return (ok: false, reportedPort: null);
      final text = await response
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(milliseconds: 1500));
      final payload = jsonDecode(text);
      if (payload is Map<String, Object?> && payload['ok'] == true) {
        final reported = payload['port'];
        return (
          ok: true,
          reportedPort: reported is num ? reported.toInt() : null,
        );
      }
      return (ok: false, reportedPort: null);
    } catch (_) {
      return (ok: false, reportedPort: null);
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _adopt(int port) async {
    state = state.copyWith(
      running: true,
      activePort: () => port,
      activity:
          UploadActivity.simple(UploadStatus.idle, 'Server ready on port $port.'),
    );
    await refreshNetwork();
  }

  Future<void> startServer(int port, {int? maxParallelUploads}) async {
    final concurrency = maxParallelUploads ??
        await ref.read(uploadSettingsStoreProvider).getMaxParallelUploads();
    try {
      _setActivity(UploadActivity.simple(
          UploadStatus.idle, 'Starting server on port $port...'));

      // Another instance (e.g. hot restart leftovers) may already be serving.
      final existing = await _probeExistingServer(port);
      if (existing.ok && !_server.isRunning) {
        await _adopt(existing.reportedPort ?? port);
        return;
      }

      _server.onActivity = _setActivity;
      _server.onLibraryChanged =
          () => ref.read(libraryProvider.notifier).refresh();
      await _server.start(port: port, maxParallelUploads: concurrency);
      await _adopt(_server.port ?? port);
    } catch (error) {
      final fallback = await _probeExistingServer(port);
      if (fallback.ok) {
        await _adopt(fallback.reportedPort ?? port);
        return;
      }
      state = state.copyWith(
        running: false,
        activePort: () => null,
        activity: UploadActivity.simple(
            UploadStatus.error,
            error is Exception
                ? error.toString().replaceFirst('Exception: ', '')
                : 'Unable to start the server.'),
      );
      _syncIpPolling();
    }
  }

  Future<void> stopServer() async {
    await _server.stop();
    state = state.copyWith(
      running: false,
      activePort: () => null,
      activity: UploadActivity.simple(UploadStatus.stopped, 'Server stopped.'),
    );
    _syncIpPolling();
  }
}

final serverProvider =
    NotifierProvider<ServerController, ServerState>(ServerController.new);

// ---- upload settings --------------------------------------------------------

class UploadSettingsController extends Notifier<int> {
  @override
  int build() => defaultMaxParallelUploads;

  Future<void> load() async {
    state =
        await ref.read(uploadSettingsStoreProvider).getMaxParallelUploads();
    ref.read(uploadServerProvider).setMaxParallelUploads(state);
  }

  Future<bool> select(int value) async {
    try {
      state =
          await ref.read(uploadSettingsStoreProvider).saveMaxParallelUploads(value);
      ref.read(uploadServerProvider).setMaxParallelUploads(state);
      return true;
    } catch (_) {
      return false;
    }
  }
}

final uploadSettingsProvider =
    NotifierProvider<UploadSettingsController, int>(
        UploadSettingsController.new);

// ---- subtitle settings ------------------------------------------------------

class SubtitleSettingsController extends Notifier<int> {
  @override
  int build() => defaultSubtitleFontSize;

  Future<void> load() async {
    state =
        await ref.read(subtitleSettingsStoreProvider).getSubtitleFontSize();
  }

  Future<bool> select(int value) async {
    try {
      state = await ref
          .read(subtitleSettingsStoreProvider)
          .saveSubtitleFontSize(value);
      return true;
    } catch (_) {
      return false;
    }
  }
}

final subtitleFontSizeProvider =
    NotifierProvider<SubtitleSettingsController, int>(
        SubtitleSettingsController.new);

// ---- thumbnails --------------------------------------------------------------

class ThumbnailController extends Notifier<Map<String, String>> {
  final _jobPaths = <String>{};
  bool _hydrating = false;
  final _queue = <LibraryItem>[];
  final _retryCounts = <String, int>{};

  @override
  Map<String, String> build() => {};

  ThumbnailService get _service => ref.read(thumbnailServiceProvider);

  /// Queue thumbnail generation for videos with no cached entry yet.
  void hydrate(List<LibraryItem> videos) {
    for (final video in videos) {
      if (state.containsKey(video.path) || _jobPaths.contains(video.path)) {
        continue;
      }
      _jobPaths.add(video.path);
      _queue.add(video);
    }
    _run();
  }

  Future<void> _run() async {
    if (_hydrating || _queue.isEmpty) return;
    _hydrating = true;
    try {
      final workers = <Future<void>>[];
      final count = _queue.length < thumbnailHydrationConcurrency
          ? _queue.length
          : thumbnailHydrationConcurrency;
      for (var i = 0; i < count; i++) {
        workers.add(_worker());
      }
      await Future.wait(workers);
    } finally {
      _hydrating = false;
      if (_queue.isNotEmpty) unawaited(_run());
    }
  }

  Future<void> _worker() async {
    while (_queue.isNotEmpty) {
      final video = _queue.removeAt(0);
      var releaseJob = true;
      try {
        final storedDuration = ref
            .read(libraryProvider)
            .playbackStateByPath[video.path]
            ?.durationSeconds;

        final cached = await _service.getCachedThumbnailPath(video);
        if (cached != null) {
          state = {...state, video.path: cached};
          _retryCounts.remove(video.path);
          // Backfill runtime for videos cached before duration was recorded.
          if (storedDuration == null) {
            await _backfillDuration(
                video.path, await _service.probeDurationSeconds(video));
          }
          continue;
        }

        try {
          final generated =
              await _service.generateThumbnailForVideo(video, storedDuration);
          state = {...state, video.path: generated.path};
          _retryCounts.remove(video.path);
          if (storedDuration == null) {
            await _backfillDuration(
                video.path,
                generated.durationSeconds ??
                    await _service.probeDurationSeconds(video));
          }
        } catch (_) {
          // Runtime does not depend on a renderable frame: even when the
          // thumbnail can't be produced (e.g. an undecodable video track),
          // surface the total runtime from the demuxer before retrying.
          if (storedDuration == null) {
            await _backfillDuration(
                video.path, await _service.probeDurationSeconds(video));
          }
          rethrow;
        }
      } catch (_) {
        final attempt = (_retryCounts[video.path] ?? 0) + 1;
        if (attempt < thumbnailHydrationMaxAttempts) {
          _retryCounts[video.path] = attempt;
          _queue.add(video);
          releaseJob = false;
          continue;
        }
        _retryCounts.remove(video.path);
      } finally {
        if (releaseJob) _jobPaths.remove(video.path);
      }
    }
  }

  /// Persists a runtime discovered during thumbnail work and refreshes the
  /// library so the row shows the total duration without a first playback.
  Future<void> _backfillDuration(String path, double? durationSeconds) async {
    if (durationSeconds == null || durationSeconds <= 0) return;
    await ref.read(playbackStateStoreProvider).saveDuration(path, durationSeconds);
    await ref.read(libraryProvider.notifier).reloadPlaybackState();
  }

  void evict(Iterable<String> paths) {
    final next = Map<String, String>.of(state);
    for (final path in paths) {
      next.remove(path);
    }
    state = next;
  }
}

final thumbnailProvider =
    NotifierProvider<ThumbnailController, Map<String, String>>(
        ThumbnailController.new);

// ---- player selection ---------------------------------------------------------

/// Path of the video currently opened in the player, if any.
class SelectedVideoPathController extends Notifier<String?> {
  @override
  String? build() => null;

  void set(String? path) => state = path;
}

final selectedVideoPathProvider =
    NotifierProvider<SelectedVideoPathController, String?>(
        SelectedVideoPathController.new);
