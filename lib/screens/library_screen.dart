import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/library_item.dart';
import '../providers/app_providers.dart';
import '../theme.dart';
import '../widgets/video_card.dart';
import 'player_screen.dart';

class LibraryScreen extends ConsumerWidget {
  const LibraryScreen({super.key});

  Future<void> _confirm(
    BuildContext context, {
    required String title,
    required String message,
    required String confirmLabel,
    required Future<void> Function() onConfirm,
  }) async {
    final confirmed = await showCupertinoDialog<bool>(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          CupertinoDialogAction(
            onPressed: () => Navigator.of(context).pop(true),
            isDestructiveAction: true,
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await onConfirm();
    }
  }

  Future<void> _showError(BuildContext context, String message) {
    return showCupertinoDialog<void>(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: const Text('Error'),
        content: Text(message),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Future<void> _deleteItems(
      BuildContext context, WidgetRef ref, List<LibraryItem> targets) async {
    try {
      final cleanupVideos = await ref
          .read(videoLibraryProvider)
          .collectPlaybackArtifactVideos(targets);

      if (cleanupVideos.isNotEmpty) {
        await ref
            .read(playbackStateStoreProvider)
            .clearProgressFor(cleanupVideos.map((v) => v.path));
        final thumbnails = ref.read(thumbnailServiceProvider);
        for (final video in cleanupVideos) {
          await thumbnails.deleteThumbnailForVideo(video);
        }
        ref
            .read(thumbnailProvider.notifier)
            .evict(cleanupVideos.map((v) => v.path));
      }

      final library = ref.read(videoLibraryProvider);
      for (final target in targets) {
        await library.deleteLibraryItem(target.path);
      }

      ref.read(selectionProvider.notifier).cancel();
      await ref.read(libraryProvider.notifier).refresh();
    } catch (error) {
      if (context.mounted) {
        await _showError(context, 'Delete failed: $error');
      }
    }
  }

  void _openPlayer(BuildContext context, WidgetRef ref, LibraryItem video) {
    ref.read(selectedVideoPathProvider.notifier).set(video.path);
    Navigator.of(context)
        .push(CupertinoPageRoute<void>(
      builder: (_) => const PlayerScreen(),
      fullscreenDialog: true,
    ))
        .whenComplete(() {
      ref.read(selectedVideoPathProvider.notifier).set(null);
      ref.read(libraryProvider.notifier).refresh();
    });
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final library = ref.watch(libraryProvider);
    final selection = ref.watch(selectionProvider);
    final thumbnails = ref.watch(thumbnailProvider);

    // Hydrate thumbnails for visible videos.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(thumbnailProvider.notifier).hydrate(library.videoItems);
      ref
          .read(selectionProvider.notifier)
          .prune(library.items.map((i) => i.path));
    });

    if (library.loading) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CupertinoActivityIndicator(color: VColors.accent, radius: 14),
            SizedBox(height: 16),
            Text(
              'Preparing storage, network, and local upload server...',
              textAlign: TextAlign.center,
              style: TextStyle(color: VColors.muted),
            ),
          ],
        ),
      );
    }

    final selectedCount = selection.selected.length;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              if (selection.selectionMode)
                Text(
                  '$selectedCount selected',
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    color: VColors.ink,
                  ),
                )
              else if (library.currentFolderPath != null)
                CupertinoButton(
                  padding: EdgeInsets.zero,
                  minimumSize: const Size(0, 36),
                  onPressed: () {
                    ref.read(selectionProvider.notifier).cancel();
                    ref
                        .read(libraryProvider.notifier)
                        .refresh(parentPathOf(library.currentFolderPath));
                  },
                  child: const Icon(CupertinoIcons.back, color: VColors.ink),
                ),
              const Spacer(),
              if (selection.selectionMode) ...[
                CupertinoButton(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  minimumSize: const Size(0, 36),
                  onPressed: () =>
                      ref.read(selectionProvider.notifier).cancel(),
                  child: const Text('Cancel'),
                ),
                CupertinoButton(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  minimumSize: const Size(0, 36),
                  onPressed: () => _confirm(
                    context,
                    title: 'Clear playback history?',
                    message:
                        'Saved playback positions will be reset for videos inside the selected items.',
                    confirmLabel: 'Clear',
                    onConfirm: () async {
                      final targets = library.items
                          .where((i) => selection.selected.contains(i.path))
                          .toList();
                      final cleanupVideos = await ref
                          .read(videoLibraryProvider)
                          .collectPlaybackArtifactVideos(targets);
                      await ref
                          .read(playbackStateStoreProvider)
                          .clearProgressFor(cleanupVideos.map((v) => v.path));
                      ref.read(selectionProvider.notifier).cancel();
                      await ref.read(libraryProvider.notifier).refresh();
                    },
                  ),
                  child: const Text('Clear History'),
                ),
                CupertinoButton(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  minimumSize: const Size(0, 36),
                  onPressed: () => _confirm(
                    context,
                    title: 'Delete selected items?',
                    message:
                        '$selectedCount item${selectedCount == 1 ? '' : 's'} will be removed.',
                    confirmLabel: 'Delete',
                    onConfirm: () => _deleteItems(
                      context,
                      ref,
                      library.items
                          .where((i) => selection.selected.contains(i.path))
                          .toList(),
                    ),
                  ),
                  child: const Text(
                    'Delete',
                    style: TextStyle(color: VColors.deleteRed),
                  ),
                ),
              ] else
                CupertinoButton(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  minimumSize: const Size(0, 36),
                  onPressed: () => _confirm(
                    context,
                    title: 'Clear playback history?',
                    message:
                        'This resets all saved playback positions and marks every video as new.',
                    confirmLabel: 'Clear',
                    onConfirm: () async {
                      await ref
                          .read(playbackStateStoreProvider)
                          .clearAllProgress();
                      await ref.read(libraryProvider.notifier).refresh();
                    },
                  ),
                  child: const Text('Clear All History'),
                ),
            ],
          ),
        ),
        Expanded(
          child: library.items.isEmpty
              ? _EmptyState(inFolder: library.currentFolderPath != null)
              : ListView.builder(
                  itemCount: library.items.length,
                  itemBuilder: (context, index) {
                    final item = library.items[index];
                    final playback = library.playbackStateByPath[item.path];
                    return VideoCard(
                      item: item,
                      isNew: item.isVideo &&
                          playback?.hasStartedPlayback != true,
                      selected: selection.selected.contains(item.path),
                      selectionMode: selection.selectionMode,
                      durationSeconds:
                          item.isVideo ? playback?.durationSeconds : null,
                      savedPositionSeconds:
                          item.isVideo ? playback?.positionSeconds ?? 0 : null,
                      thumbnailPath:
                          item.isVideo ? thumbnails[item.path] : null,
                      onLongPress: () {
                        final notifier = ref.read(selectionProvider.notifier);
                        if (selection.selectionMode) {
                          notifier.toggle(item.path);
                        } else {
                          notifier.startWith(item.path);
                        }
                      },
                      onDelete: () => _confirm(
                        context,
                        title: item.isFolder ? 'Delete folder?' : 'Delete file?',
                        message: item.name,
                        confirmLabel: 'Delete',
                        onConfirm: () => _deleteItems(context, ref, [item]),
                      ),
                      onPlay: () {
                        if (selection.selectionMode) {
                          ref
                              .read(selectionProvider.notifier)
                              .toggle(item.path);
                          return;
                        }
                        if (item.isFolder) {
                          ref.read(selectionProvider.notifier).cancel();
                          ref
                              .read(libraryProvider.notifier)
                              .refresh(item.relativePath);
                          return;
                        }
                        if (item.isVideo) {
                          _openPlayer(context, ref, item);
                        }
                      },
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.inFolder});

  final bool inFolder;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              inFolder ? 'This folder is empty' : 'No media yet',
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: VColors.ink,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              inFolder
                  ? 'Use the Upload tab to add files here, or go up to another folder.'
                  : 'Use the Upload tab at the bottom, open the device URL on your computer, and send a file here.',
              textAlign: TextAlign.center,
              style: const TextStyle(color: VColors.muted),
            ),
          ],
        ),
      ),
    );
  }
}
