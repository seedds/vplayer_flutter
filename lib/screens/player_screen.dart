import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../app.dart';
import '../models/library_item.dart';
import '../providers/app_providers.dart';
import '../services/format.dart';
import '../services/playback_state_store.dart';
import '../services/subtitle_service.dart';
import '../theme.dart';

const _backgroundDoubleTapDelay = Duration(milliseconds: 250);
const _scrubPreviewDedupeThresholdSeconds = 0.05;
const _scrubPreviewPopupWidth = 160.0;
const _scrubPreviewPopupHeight = 90.0;
const _resumeNearEndThresholdSeconds = 10.0;
const _playbackRateStep = 0.1;
const _minPlaybackRate = 0.5;
const _maxPlaybackRate = 2.0;
const _controlsAutoHideDelay = Duration(milliseconds: 2500);
// Fixed width for the seek-bar elapsed/remaining labels. Sized for the widest
// value ("-HH:MM:SS") at 12px/w700 with tabular figures, so the boxes never
// resize while scrubbing and the centered title stays put. Tunable.
const _seekTimeLabelWidth = 74.0;

double _clampPlaybackRate(double rate) =>
    ((rate * 10).roundToDouble() / 10).clamp(_minPlaybackRate, _maxPlaybackRate);

double _resumePosition(double savedPosition, double duration) {
  if (!savedPosition.isFinite || savedPosition <= 0) return 0;
  if (!duration.isFinite || duration <= 0) return savedPosition;
  final clamped = savedPosition.clamp(0.0, duration);
  final remaining = duration - clamped;
  if (remaining >= _resumeNearEndThresholdSeconds) return clamped;
  return (duration - _resumeNearEndThresholdSeconds).clamp(0.0, duration);
}

String _formatClockTime(DateTime value) =>
    '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';

class PlayerScreen extends ConsumerStatefulWidget {
  const PlayerScreen({super.key});

  @override
  ConsumerState<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends ConsumerState<PlayerScreen>
    with WidgetsBindingObserver {
  late final Player _player;
  late final VideoController _videoController;
  late final PlaybackStateStore _playbackStore;

  List<LibraryItem> _videos = [];
  int _currentIndex = 0;
  LibraryItem? get _video =>
      _currentIndex >= 0 && _currentIndex < _videos.length
          ? _videos[_currentIndex]
          : null;
  bool get _hasNextVideo => _currentIndex < _videos.length - 1;

  bool _controlsVisible = true;
  bool _controlsLocked = false;
  bool _isPlaying = false;
  bool _isScrubbing = false;
  double _currentTime = 0;
  double _duration = 0;
  double _scrubTime = 0;
  double _playbackRate = 1;
  String _clockTime = _formatClockTime(DateTime.now());
  Uint8List? _scrubPreviewBytes;
  List<SubtitleCue> _subtitleCues = [];
  String? _activeSubtitleText;

  Timer? _autoHideTimer;
  Timer? _clockTimer;
  Timer? _backgroundTapTimer;
  int _lastBackgroundTapTouchCount = 0;
  int _backgroundGestureTouchCount = 0;
  final Set<int> _activePointers = {};

  double _lastPersistedPosition = 0;
  bool _playbackInterrupted = false;
  double _seekBarWidth = 1;

  // Scrub preview single-flight machinery.
  bool _previewInFlight = false;
  double? _queuedPreviewTime;
  double? _lastPreviewedTime;
  int _previewRequestId = 0;

  final _subscriptions = <StreamSubscription<Object?>>[];
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _playbackStore = ref.read(playbackStateStoreProvider);

    final library = ref.read(libraryProvider);
    _videos = library.videoItems;
    final selectedPath = ref.read(selectedVideoPathProvider);
    _currentIndex = _videos.indexWhere((v) => v.path == selectedPath);
    if (_currentIndex < 0) _currentIndex = 0;

    _player = Player();
    _videoController = VideoController(_player);

    SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

    _clockTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        setState(() => _clockTime = _formatClockTime(DateTime.now()));
      }
    });

    _subscriptions.add(_player.stream.position.listen((position) {
      final seconds = position.inMilliseconds / 1000;
      if (!mounted) return;
      setState(() {
        _currentTime = seconds;
        _activeSubtitleText = getActiveSubtitleText(_subtitleCues, seconds);
      });
      if (!_isScrubbing) {
        _persistPosition(seconds);
      }
    }));

    _subscriptions.add(_player.stream.duration.listen((duration) {
      final seconds = duration.inMilliseconds / 1000;
      if (seconds <= 0) return;
      _duration = seconds;
      final video = _video;
      if (video != null) {
        _playbackStore.saveDuration(video.path, seconds);
      }
      if (mounted) setState(() {});
    }));

    _subscriptions.add(_player.stream.playing.listen((playing) {
      if (!mounted) return;
      setState(() => _isPlaying = playing);
      _restartAutoHideTimer();
    }));

    _subscriptions.add(_player.stream.completed.listen((completed) {
      if (!completed) return;
      _handlePlayToEnd();
    }));

    _openVideo(autoplayIfAllowed: true);
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _autoHideTimer?.cancel();
    _clockTimer?.cancel();
    _backgroundTapTimer?.cancel();
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    _persistPositionForce();
    _player.dispose();

    SystemChrome.setPreferredOrientations(appOrientations(isTabletLayout));
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  // ---- lifecycle ------------------------------------------------------------

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      _handlePlaybackInterruption();
    }
    // On resume: stay paused (parity with original).
  }

  void _handlePlaybackInterruption() {
    if (_disposed) return;
    _playbackInterrupted = true;
    _clearScrubPreview();
    _persistPositionForce();
    _player.pause();
    if (mounted) {
      setState(() {
        _isScrubbing = false;
        _controlsLocked = false;
        _controlsVisible = true;
      });
    }
  }

  // ---- persistence ----------------------------------------------------------

  void _persistPosition(double positionSeconds, {bool force = false}) {
    final video = _video;
    if (video == null) return;
    if (!force && (positionSeconds - _lastPersistedPosition).abs() < 2) {
      return;
    }
    _lastPersistedPosition = positionSeconds;
    _playbackStore.savePosition(video.path, positionSeconds, _duration);
  }

  void _persistPositionForce() =>
      _persistPosition(_currentTime, force: true);

  // ---- video loading --------------------------------------------------------

  bool get _shouldAutoplay => !_playbackInterrupted;

  Future<void> _openVideo({required bool autoplayIfAllowed}) async {
    final video = _video;
    if (video == null) return;

    _lastPersistedPosition = 0;
    _clearScrubPreview();
    setState(() {
      _subtitleCues = [];
      _activeSubtitleText = null;
      _duration = 0;
      _currentTime = 0;
      _scrubTime = 0;
    });

    final savedPosition = await _playbackStore.getSavedPosition(video.path);
    if (_disposed) return;

    await _player.open(Media(video.path), play: false);
    if (_disposed) return;
    await _player.setRate(_playbackRate);

    // Wait for duration so the resume seek lands correctly.
    var duration = _player.state.duration.inMilliseconds / 1000;
    if (duration <= 0) {
      try {
        final loaded = await _player.stream.duration
            .firstWhere((d) => d > Duration.zero)
            .timeout(const Duration(seconds: 4));
        duration = loaded.inMilliseconds / 1000;
      } on TimeoutException {
        duration = 0;
      }
    }
    if (_disposed) return;
    _duration = duration;

    final resumePosition = _resumePosition(savedPosition, duration);
    if (resumePosition > 0) {
      await _player
          .seek(Duration(milliseconds: (resumePosition * 1000).round()));
    }
    if (_disposed) return;

    setState(() {
      _currentTime = resumePosition;
      _scrubTime = resumePosition;
    });

    unawaited(_loadSubtitles(video));

    if (autoplayIfAllowed && _shouldAutoplay) {
      await _player.play();
    }
  }

  Future<void> _loadSubtitles(LibraryItem video) async {
    try {
      final subtitlePath =
          await ref.read(videoLibraryProvider).findMatchingSubtitlePath(video);
      if (_disposed || _video?.path != video.path) return;
      if (subtitlePath == null) {
        setState(() {
          _subtitleCues = [];
          _activeSubtitleText = null;
        });
        return;
      }
      final cues = await loadSrtFile(subtitlePath);
      if (_disposed || _video?.path != video.path) return;
      setState(() {
        _subtitleCues = cues;
        _activeSubtitleText = getActiveSubtitleText(cues, _currentTime);
      });
    } catch (_) {
      if (!_disposed && mounted) {
        setState(() {
          _subtitleCues = [];
          _activeSubtitleText = null;
        });
      }
    }
  }

  void _selectIndex(int index) {
    if (index < 0 || index >= _videos.length) return;
    _persistPositionForce();
    setState(() {
      _currentIndex = index;
      _controlsVisible = false;
    });
    ref.read(selectedVideoPathProvider.notifier).set(_videos[index].path);
    _openVideo(autoplayIfAllowed: true);
  }

  void _handlePlayToEnd() {
    _persistPositionForce();
    _clearScrubPreview();
    if (mounted) {
      setState(() {
        _isScrubbing = false;
        // End of playlist: reveal controls so the user isn't stranded on a
        // frozen frame. With a next video, _selectIndex hides them for a
        // clean start.
        _controlsVisible = !_hasNextVideo;
      });
    }
    if (_hasNextVideo) {
      _selectIndex(_currentIndex + 1);
    }
  }

  // ---- controls visibility ---------------------------------------------------

  void _clearAutoHideTimer() {
    _autoHideTimer?.cancel();
    _autoHideTimer = null;
  }

  void _restartAutoHideTimer() {
    _clearAutoHideTimer();
    if (_controlsVisible && _isPlaying && !_isScrubbing) {
      _autoHideTimer = Timer(_controlsAutoHideDelay, () {
        if (mounted && !_isScrubbing) setState(() => _controlsVisible = false);
      });
    }
  }

  void _showControls() {
    setState(() => _controlsVisible = true);
    _restartAutoHideTimer();
  }

  // ---- transport --------------------------------------------------------------

  void _handleClose() {
    _persistPositionForce();
    Navigator.of(context).pop();
  }

  Future<void> _handleSeekBy(double seconds) async {
    final target =
        (_currentTime + seconds).clamp(0.0, _duration > 0 ? _duration : double.infinity);
    await _player.seek(Duration(milliseconds: (target * 1000).round()));
    setState(() {
      _currentTime = target;
      _scrubTime = target;
    });
    _showControls();
  }

  void _handleTogglePlayback({bool showControls = true}) {
    if (_isPlaying) {
      _player.pause();
    } else {
      _playbackInterrupted = false;
      _player.play();
    }
    if (showControls) _showControls();
  }

  void _updatePlaybackRate(double nextRate) {
    final normalized = _clampPlaybackRate(nextRate);
    _player.setRate(normalized);
    setState(() => _playbackRate = normalized);
    _showControls();
  }

  // ---- background gestures -----------------------------------------------------

  void _clearPendingBackgroundTap() {
    _backgroundTapTimer?.cancel();
    _backgroundTapTimer = null;
  }

  void _toggleControlsLockFromGesture() {
    _clearScrubPreview();
    setState(() {
      _isScrubbing = false;
      _controlsLocked = !_controlsLocked;
      _controlsVisible = true;
    });
    _restartAutoHideTimer();
  }

  void _handleBackgroundTap(VoidCallback singleTapAction, int touchCount) {
    if (_isScrubbing) return;

    final normalizedTouchCount = touchCount >= 2 ? 2 : 1;
    final isDoubleTap = _backgroundTapTimer != null &&
        _lastBackgroundTapTouchCount == normalizedTouchCount;

    if (isDoubleTap) {
      _clearPendingBackgroundTap();
      _lastBackgroundTapTouchCount = 0;

      if (normalizedTouchCount >= 2) {
        _toggleControlsLockFromGesture();
        return;
      }
      _handleTogglePlayback(showControls: false);
      return;
    }

    _lastBackgroundTapTouchCount = normalizedTouchCount;
    _clearPendingBackgroundTap();
    _backgroundTapTimer = Timer(_backgroundDoubleTapDelay, () {
      _backgroundTapTimer = null;
      _lastBackgroundTapTouchCount = 0;
      if (normalizedTouchCount == 1) {
        singleTapAction();
        _restartAutoHideTimer();
      }
    });
  }

  void _onBackgroundPointerDown(PointerDownEvent event) {
    _activePointers.add(event.pointer);
    _backgroundGestureTouchCount =
        _backgroundGestureTouchCount < _activePointers.length
            ? _activePointers.length
            : _backgroundGestureTouchCount;
    _clearAutoHideTimer();
  }

  void _onBackgroundPointerUp(PointerUpEvent event) {
    _activePointers.remove(event.pointer);
    if (_activePointers.isNotEmpty) return;

    final touchCount =
        _backgroundGestureTouchCount > 0 ? _backgroundGestureTouchCount : 1;
    _backgroundGestureTouchCount = 0;

    _handleBackgroundTap(
      _controlsVisible
          ? () {
              if (mounted) setState(() => _controlsVisible = false);
            }
          : () {
              if (mounted) {
                setState(() => _controlsVisible = !_controlsVisible);
              }
            },
      touchCount,
    );
    _restartAutoHideTimer();
  }

  void _onBackgroundPointerCancel(PointerCancelEvent event) {
    _activePointers.remove(event.pointer);
    if (_activePointers.isEmpty) {
      _backgroundGestureTouchCount = 0;
      _restartAutoHideTimer();
    }
  }

  // ---- scrub preview -------------------------------------------------------------

  void _clearScrubPreview() {
    _previewInFlight = false;
    _queuedPreviewTime = null;
    _previewRequestId += 1;
    _lastPreviewedTime = null;
    if (mounted) setState(() => _scrubPreviewBytes = null);
  }

  Future<void> _generateScrubPreview(double time, int requestId) async {
    try {
      await _player.seek(Duration(milliseconds: (time * 1000).round()));
      final bytes = await _player.screenshot(format: 'image/jpeg');
      if (_previewRequestId != requestId || bytes == null || _disposed) {
        return;
      }
      _lastPreviewedTime = time;
      if (mounted) setState(() => _scrubPreviewBytes = bytes);
    } catch (_) {
      if (_previewRequestId == requestId && mounted) {
        setState(() => _scrubPreviewBytes = null);
      }
    } finally {
      if (_previewRequestId == requestId) {
        _previewInFlight = false;
        final queued = _queuedPreviewTime;
        _queuedPreviewTime = null;
        if (queued != null &&
            (_lastPreviewedTime == null ||
                (_lastPreviewedTime! - queued).abs() >
                    _scrubPreviewDedupeThresholdSeconds)) {
          _requestScrubPreview(queued);
        }
      }
    }
  }

  void _requestScrubPreview(double time) {
    if (_lastPreviewedTime != null &&
        (_lastPreviewedTime! - time).abs() <=
            _scrubPreviewDedupeThresholdSeconds) {
      return;
    }
    if (_previewInFlight) {
      _queuedPreviewTime = time;
      return;
    }
    _previewInFlight = true;
    _queuedPreviewTime = null;
    _previewRequestId += 1;
    unawaited(_generateScrubPreview(time, _previewRequestId));
  }

  // ---- seek bar --------------------------------------------------------------------

  double _seekTimeFromPosition(double positionX) {
    final width = _seekBarWidth > 1 ? _seekBarWidth : 1;
    final clampedX = positionX.clamp(0.0, width.toDouble());
    if (_duration <= 0) return 0;
    return clampedX / width * _duration;
  }

  void _handleSeekBarStart(double localX) {
    _clearScrubPreview();
    setState(() {
      _isScrubbing = true;
      _controlsVisible = true;
      _scrubTime = _seekTimeFromPosition(localX);
    });
    _requestScrubPreview(_scrubTime);
  }

  void _handleSeekBarMove(double localX) {
    setState(() => _scrubTime = _seekTimeFromPosition(localX));
    _requestScrubPreview(_scrubTime);
  }

  Future<void> _handleSlidingComplete(double value) async {
    _clearScrubPreview();
    await _player.seek(Duration(milliseconds: (value * 1000).round()));
    if (_disposed) return;
    setState(() {
      _currentTime = value;
      _scrubTime = value;
      _isScrubbing = false;
      _controlsVisible = true;
      _activeSubtitleText = getActiveSubtitleText(_subtitleCues, value);
    });
    _persistPosition(value, force: true);
    _restartAutoHideTimer();
  }

  // ---- build ------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final video = _video;
    if (video == null) {
      return const ColoredBox(color: Color(0xFF050505));
    }

    final subtitleFontSize = ref.watch(subtitleFontSizeProvider).toDouble();
    final insets = MediaQuery.paddingOf(context);
    final displayedTime = _isScrubbing ? _scrubTime : _currentTime;
    final remainingTime =
        (_duration - displayedTime).clamp(0.0, double.infinity);
    final progressPercent =
        _duration > 0 ? (displayedTime / _duration).clamp(0.0, 1.0) : 0.0;
    final scrubPreviewLeft = (progressPercent * _seekBarWidth -
            _scrubPreviewPopupWidth / 2)
        .clamp(
            0.0,
            (_seekBarWidth - _scrubPreviewPopupWidth)
                .clamp(0.0, double.infinity));

    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) _persistPositionForce();
      },
      child: ColoredBox(
        color: const Color(0xFF050505),
        child: Stack(
          children: [
            // Video surface.
            Positioned.fill(
              child: Video(
                controller: _videoController,
                controls: NoVideoControls,
                fit: BoxFit.contain,
                fill: const Color(0xFF050505),
                subtitleViewConfiguration:
                    const SubtitleViewConfiguration(visible: false),
              ),
            ),

            // Background tap layer (single/double/two-finger taps).
            Positioned.fill(
              child: Listener(
                behavior: HitTestBehavior.translucent,
                onPointerDown: _onBackgroundPointerDown,
                onPointerUp: _onBackgroundPointerUp,
                onPointerCancel: _onBackgroundPointerCancel,
              ),
            ),

            // Subtitle overlay.
            if (_activeSubtitleText != null)
              Positioned(
                left: 18,
                right: 18,
                bottom: _controlsVisible && !_controlsLocked
                    ? insets.bottom + 54
                    : insets.bottom + 14,
                child: IgnorePointer(
                  child: Center(
                    child: Text(
                      _activeSubtitleText!,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: const Color(0xFFF2F2F2),
                        fontSize: subtitleFontSize,
                        height: 44 / 36,
                        fontWeight: FontWeight.w800,
                        shadows: const [
                          Shadow(offset: Offset(-2, 0), color: CupertinoColors.black),
                          Shadow(offset: Offset(2, 0), color: CupertinoColors.black),
                          Shadow(offset: Offset(0, -2), color: CupertinoColors.black),
                          Shadow(offset: Offset(0, 2), color: CupertinoColors.black),
                          Shadow(offset: Offset(-2, -2), color: CupertinoColors.black),
                          Shadow(offset: Offset(2, -2), color: CupertinoColors.black),
                          Shadow(offset: Offset(-2, 2), color: CupertinoColors.black),
                          Shadow(offset: Offset(2, 2), color: CupertinoColors.black),
                        ],
                      ),
                    ),
                  ),
                ),
              ),

            if (_controlsVisible) ...[
              // Top overlay: Back, clock, Next.
              if (!_controlsLocked)
                Positioned(
                  top: insets.top + 10,
                  left: 18,
                  right: 18,
                  child: Row(
                    children: [
                      SizedBox(
                        width: 78,
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: _PillButton(
                              label: 'Back', onPressed: _handleClose),
                        ),
                      ),
                      Expanded(
                        child: Text(
                          _clockTime,
                          textAlign: TextAlign.center,
                          maxLines: 1,
                          style: const TextStyle(
                            color: CupertinoColors.white,
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      SizedBox(
                        width: 78,
                        child: Align(
                          alignment: Alignment.centerRight,
                          child: _hasNextVideo
                              ? _PillButton(
                                  label: 'Next',
                                  onPressed: () =>
                                      _selectIndex(_currentIndex + 1))
                              : null,
                        ),
                      ),
                    ],
                  ),
                ),

              // Center controls: lock + transport.
              Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _CircleButton(
                      onPressed: () {
                        setState(
                            () => _controlsLocked = !_controlsLocked);
                        _showControls();
                      },
                      child: Icon(
                        _controlsLocked
                            ? CupertinoIcons.lock_open
                            : CupertinoIcons.lock,
                        color: CupertinoColors.white,
                        size: 24,
                      ),
                    ),
                    const SizedBox(height: 16),
                    SizedBox(
                      height: 48,
                      child: !_controlsLocked
                          ? Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                _PillButton(
                                  label: '-10',
                                  minWidth: 64,
                                  onPressed: () => _handleSeekBy(-10),
                                ),
                                const SizedBox(width: 14),
                                _PillButton(
                                  minWidth: 92,
                                  onPressed: _handleTogglePlayback,
                                  child: Icon(
                                    _isPlaying
                                        ? CupertinoIcons.pause_fill
                                        : CupertinoIcons.play_fill,
                                    color: CupertinoColors.white,
                                    size: 22,
                                  ),
                                ),
                                const SizedBox(width: 14),
                                _PillButton(
                                  label: '+10',
                                  minWidth: 64,
                                  onPressed: () => _handleSeekBy(10),
                                ),
                              ],
                            )
                          : null,
                    ),
                  ],
                ),
              ),

              // Playback rate controls (right side).
              if (!_controlsLocked)
                Positioned(
                  right: insets.right + 12,
                  top: 0,
                  bottom: 0,
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _SquareButton(
                          label: '+',
                          onPressed: () => _updatePlaybackRate(
                              _playbackRate + _playbackRateStep),
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          child: Text(
                            _playbackRate.toStringAsFixed(1),
                            style: const TextStyle(
                              color: CupertinoColors.white,
                              fontSize: 17,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        _SquareButton(
                          label: '-',
                          onPressed: () => _updatePlaybackRate(
                              _playbackRate - _playbackRateStep),
                        ),
                      ],
                    ),
                  ),
                ),

              // Bottom seek bar.
              if (!_controlsLocked)
                Positioned(
                  left: insets.left,
                  right: insets.right,
                  bottom: insets.bottom + 12,
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      _seekBarWidth = constraints.maxWidth;
                      return Stack(
                        clipBehavior: Clip.none,
                        children: [
                          if (_isScrubbing && _scrubPreviewBytes != null)
                            Positioned(
                              left: scrubPreviewLeft,
                              bottom: 56,
                              child: Container(
                                width: _scrubPreviewPopupWidth,
                                height: _scrubPreviewPopupHeight,
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                      color: CupertinoColors.white
                                          .withValues(alpha: 0.08)),
                                  color: const Color(0xF5080C10),
                                ),
                                clipBehavior: Clip.antiAlias,
                                child: Image.memory(
                                  _scrubPreviewBytes!,
                                  fit: BoxFit.cover,
                                  gaplessPlayback: true,
                                ),
                              ),
                            ),
                          GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onHorizontalDragDown: (details) =>
                                _handleSeekBarStart(
                                    details.localPosition.dx),
                            onHorizontalDragUpdate: (details) =>
                                _handleSeekBarMove(details.localPosition.dx),
                            onHorizontalDragEnd: (_) =>
                                _handleSlidingComplete(_scrubTime),
                            onHorizontalDragCancel: () =>
                                _handleSlidingComplete(_scrubTime),
                            onTapUp: (details) => _handleSlidingComplete(
                                _seekTimeFromPosition(
                                    details.localPosition.dx)),
                            child: SizedBox(
                              height: 44,
                              child: Stack(
                                children: [
                                  Positioned.fill(
                                    child: ColoredBox(
                                      color: const Color(0xB80A121A),
                                      child: Align(
                                        alignment: Alignment.centerLeft,
                                        child: FractionallySizedBox(
                                          widthFactor: progressPercent,
                                          heightFactor: 1,
                                          child: const ColoredBox(
                                              color: VColors.accent),
                                        ),
                                      ),
                                    ),
                                  ),
                                  Positioned.fill(
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 12),
                                      child: Row(
                                        children: [
                                          SizedBox(
                                            width: _seekTimeLabelWidth,
                                            child: Align(
                                              alignment: Alignment.centerLeft,
                                              child: Text(
                                                formatDuration(displayedTime),
                                                style: const TextStyle(
                                                  color: CupertinoColors.white,
                                                  fontSize: 12,
                                                  fontWeight: FontWeight.w700,
                                                  fontFeatures: [
                                                    FontFeature.tabularFigures()
                                                  ],
                                                ),
                                              ),
                                            ),
                                          ),
                                          Expanded(
                                            child: Padding(
                                              padding: const EdgeInsets
                                                  .symmetric(horizontal: 12),
                                              child: Text(
                                                video.name,
                                                maxLines: 1,
                                                overflow:
                                                    TextOverflow.ellipsis,
                                                textAlign: TextAlign.center,
                                                style: const TextStyle(
                                                  color: CupertinoColors.white,
                                                  fontSize: 12,
                                                  fontWeight: FontWeight.w600,
                                                ),
                                              ),
                                            ),
                                          ),
                                          SizedBox(
                                            width: _seekTimeLabelWidth,
                                            child: Align(
                                              alignment: Alignment.centerRight,
                                              child: Text(
                                                '-${formatDuration(remainingTime.toDouble())}',
                                                style: const TextStyle(
                                                  color: CupertinoColors.white,
                                                  fontSize: 12,
                                                  fontWeight: FontWeight.w700,
                                                  fontFeatures: [
                                                    FontFeature.tabularFigures()
                                                  ],
                                                ),
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Wraps a tap target with an iOS-style fade-on-press feedback.
class _Pressable extends StatefulWidget {
  const _Pressable({required this.onPressed, required this.child});

  final VoidCallback onPressed;
  final Widget child;

  @override
  State<_Pressable> createState() => _PressableState();
}

class _PressableState extends State<_Pressable> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed != value) setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => _setPressed(true),
      onTapUp: (_) => _setPressed(false),
      onTapCancel: () => _setPressed(false),
      onTap: widget.onPressed,
      child: AnimatedOpacity(
        opacity: _pressed ? 0.5 : 1,
        duration: const Duration(milliseconds: 100),
        child: widget.child,
      ),
    );
  }
}

class _PillButton extends StatelessWidget {
  const _PillButton({
    this.label,
    this.child,
    this.minWidth,
    required this.onPressed,
  });

  final String? label;
  final Widget? child;
  final double? minWidth;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return _Pressable(
      onPressed: onPressed,
      child: Container(
        constraints: BoxConstraints(minWidth: minWidth ?? 0),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: VColors.accent.withValues(alpha: 0.9),
          borderRadius: BorderRadius.circular(999),
        ),
        child: child ??
            Text(
              label ?? '',
              style: const TextStyle(
                color: CupertinoColors.white,
                fontSize: 15,
                fontWeight: FontWeight.w700,
              ),
            ),
      ),
    );
  }
}

class _CircleButton extends StatelessWidget {
  const _CircleButton({required this.onPressed, required this.child});

  final VoidCallback onPressed;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return _Pressable(
      onPressed: onPressed,
      child: Container(
        width: 56,
        height: 56,
        decoration: BoxDecoration(
          color: const Color(0xC7080C10),
          shape: BoxShape.circle,
          border:
              Border.all(color: CupertinoColors.white.withValues(alpha: 0.12)),
        ),
        child: Center(child: child),
      ),
    );
  }
}

class _SquareButton extends StatelessWidget {
  const _SquareButton({required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return _Pressable(
      onPressed: onPressed,
      child: Container(
        width: 52,
        height: 52,
        decoration: BoxDecoration(
          color: VColors.accent.withValues(alpha: 0.9),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Center(
          child: Text(
            label,
            style: const TextStyle(
              color: CupertinoColors.white,
              fontSize: 28,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }
}
