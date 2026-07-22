import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter_slidable/flutter_slidable.dart';

import '../models/library_item.dart';
import '../services/format.dart';
import '../theme.dart';

class VideoCard extends StatelessWidget {
  const VideoCard({
    super.key,
    required this.item,
    required this.isNew,
    required this.selected,
    required this.selectionMode,
    required this.onPlay,
    required this.onLongPress,
    required this.onDelete,
    this.durationSeconds,
    this.savedPositionSeconds,
    this.thumbnailPath,
  });

  final LibraryItem item;
  final bool isNew;
  final bool selected;
  final bool selectionMode;
  final VoidCallback onPlay;
  final VoidCallback onLongPress;
  final VoidCallback onDelete;
  final double? durationSeconds;
  final double? savedPositionSeconds;
  final String? thumbnailPath;

  double get _playbackProgress {
    final duration = durationSeconds;
    final position = savedPositionSeconds;
    if (!item.isVideo || duration == null || duration <= 0 || position == null) {
      return 0;
    }
    return (position / duration).clamp(0.0, 1.0);
  }

  String get _placeholderLabel => switch (item.kind) {
        LibraryItemKind.folder => 'Folder',
        LibraryItemKind.subtitle => 'SRT',
        LibraryItemKind.file => 'File',
        LibraryItemKind.video => 'Video',
      };

  String get _metaText => switch (item.kind) {
        LibraryItemKind.folder => 'Folder',
        LibraryItemKind.video =>
          '${formatDuration(savedPositionSeconds)} / ${formatDuration(durationSeconds)}',
        LibraryItemKind.subtitle => 'Subtitle file',
        LibraryItemKind.file => 'File cannot be played',
      };

  Widget _buildThumbnail() {
    final thumb = thumbnailPath;
    Widget child;
    if (item.isVideo && thumb != null) {
      child = Image.file(File(thumb), fit: BoxFit.cover);
    } else if (item.isFolder) {
      child = const ColoredBox(
        color: Color(0xFFFFF5EB),
        child: Icon(CupertinoIcons.folder, color: Color(0xFFC97846), size: 28),
      );
    } else {
      child = ColoredBox(
        color: VColors.accent,
        child: Center(
          child: Text(
            _placeholderLabel,
            style: const TextStyle(
              color: Color(0xFFF6F1EB),
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: SizedBox(width: 54, height: 46, child: child),
    );
  }

  Widget _buildBadge() {
    if (!item.isVideo) return const SizedBox.shrink();
    if (isNew) {
      return const Text(
        '[new]',
        style: TextStyle(
          color: VColors.accent,
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
      );
    }
    return SizedBox(
      width: 18,
      height: 18,
      child: CustomPaint(painter: _PieProgressPainter(_playbackProgress)),
    );
  }

  Widget _buildCardContent(BuildContext context) {
    return _PressableRow(
      onTap: onPlay,
      onLongPress: onLongPress,
      baseColor: selected ? VColors.cardSelected : VColors.cardBackground,
      pressedColor: VColors.cardPressed,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: const BoxDecoration(
          border: Border(
            bottom: BorderSide(color: VColors.cardBorder),
          ),
        ),
        child: Row(
          children: [
            _buildThumbnail(),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: VColors.ink,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _metaText,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: VColors.muted,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(width: 44, child: Center(child: _buildBadge())),
            if (selectionMode) ...[
              const SizedBox(width: 8),
              _SelectionIndicator(selected: selected),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (selectionMode) return _buildCardContent(context);

    return Slidable(
      key: ValueKey(item.id),
      endActionPane: ActionPane(
        motion: const DrawerMotion(),
        extentRatio: 0.25,
        children: [
          CustomSlidableAction(
            onPressed: (_) => onDelete(),
            backgroundColor: VColors.deleteRed,
            foregroundColor: const Color(0xFFFFF3EF),
            child: const Text(
              'Delete',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800),
            ),
          ),
        ],
      ),
      child: _buildCardContent(context),
    );
  }
}

/// Tap/long-press row surface with a pressed-state background tint,
/// replacing Material's InkWell for the Cupertino UI.
class _PressableRow extends StatefulWidget {
  const _PressableRow({
    required this.onTap,
    required this.onLongPress,
    required this.baseColor,
    required this.pressedColor,
    required this.child,
  });

  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final Color baseColor;
  final Color pressedColor;
  final Widget child;

  @override
  State<_PressableRow> createState() => _PressableRowState();
}

class _PressableRowState extends State<_PressableRow> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed != value) setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      onTapDown: (_) => _setPressed(true),
      onTapUp: (_) => _setPressed(false),
      onTapCancel: () => _setPressed(false),
      child: ColoredBox(
        color: _pressed ? widget.pressedColor : widget.baseColor,
        child: widget.child,
      ),
    );
  }
}

class _SelectionIndicator extends StatelessWidget {
  const _SelectionIndicator({required this.selected});

  final bool selected;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 34,
      height: 30,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(17),
        border: Border.all(
          color: selected ? VColors.accent : const Color(0xFFD8C7B6),
          width: 2,
        ),
        color: selected ? VColors.accent : VColors.cardBackground,
      ),
      child: selected
          ? const Center(
              child: Icon(CupertinoIcons.check_mark,
                  size: 18, color: CupertinoColors.white),
            )
          : null,
    );
  }
}

/// Small pie-chart badge showing watch progress (starts at 12 o'clock).
class _PieProgressPainter extends CustomPainter {
  _PieProgressPainter(this.progress);

  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    const radius = 8.0;

    canvas.drawCircle(
        center, radius, Paint()..color = const Color(0xFFF4E7DA));

    final clamped = progress.clamp(0.0, 1.0);
    if (clamped >= 1) {
      canvas.drawCircle(center, radius, Paint()..color = VColors.accent);
    } else if (clamped > 0) {
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        -math.pi / 2,
        2 * math.pi * clamped,
        true,
        Paint()..color = VColors.accent,
      );
    }

    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = const Color(0xFFC7B4A5)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.25,
    );
  }

  @override
  bool shouldRepaint(_PieProgressPainter oldDelegate) =>
      oldDelegate.progress != progress;
}
