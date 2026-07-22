import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/upload_activity.dart';
import '../providers/app_providers.dart';
import '../services/format.dart';
import '../services/upload_server.dart';
import '../theme.dart';

class UploadScreen extends ConsumerStatefulWidget {
  const UploadScreen({super.key});

  @override
  ConsumerState<UploadScreen> createState() => _UploadScreenState();
}

class _UploadScreenState extends ConsumerState<UploadScreen> {
  final _portController =
      TextEditingController(text: '$defaultServerPort');

  @override
  void dispose() {
    _portController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final server = ref.watch(serverProvider);
    final activity = server.activity;
    final activeUploads = activity.activeUploads;

    final serverDisplayUrl = server.serverUrl ??
        (server.running
            ? 'Server is running. Discovering device IP...'
            : 'Server is stopped');

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _Panel(
          title: 'HTTP upload server',
          subtitle: 'Keep this tab open while sending files from your computer.',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                server.running ? 'Server is running' : 'Server is stopped',
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  color: VColors.ink,
                ),
              ),
              const SizedBox(height: 4),
              SelectableRegion(
                selectionControls: cupertinoTextSelectionControls,
                contextMenuBuilder: (context, state) =>
                    CupertinoAdaptiveTextSelectionToolbar.buttonItems(
                  anchors: state.contextMenuAnchors,
                  buttonItems: state.contextMenuButtonItems,
                ),
                child: Text(
                  serverDisplayUrl,
                  style: const TextStyle(
                    color: VColors.accent,
                    fontWeight: FontWeight.w700,
                    fontSize: 16,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Port',
                          style: TextStyle(
                            color: VColors.muted,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 4),
                        CupertinoTextField(
                          controller: _portController,
                          keyboardType: TextInputType.number,
                          placeholder: '8081',
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 10),
                          style: const TextStyle(color: VColors.ink),
                          decoration: BoxDecoration(
                            color: VColors.background,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: VColors.cardBorder),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  CupertinoButton(
                    color: VColors.accent,
                    foregroundColor: VColors.background,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    onPressed: () {
                      final port = normalizePort(
                          _portController.text, defaultServerPort);
                      _portController.text = '$port';
                      ref.read(serverProvider.notifier).startServer(port);
                    },
                    child: Text(
                        server.running ? 'Restart server' : 'Start server'),
                  ),
                  const SizedBox(width: 8),
                  CupertinoButton(
                    color: VColors.deleteRed,
                    foregroundColor: VColors.background,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    onPressed: server.running
                        ? () => ref.read(serverProvider.notifier).stopServer()
                        : null,
                    child: const Text('Stop'),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _Panel(
          title: 'Upload activity',
          subtitle: 'Each finished upload appears automatically in Library.',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Text(
                      activity.message,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        color: VColors.ink,
                      ),
                    ),
                  ),
                  Text(
                    formatDate(activity.updatedAt),
                    style:
                        const TextStyle(color: VColors.muted, fontSize: 12),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              _ProgressTrack(progress: activity.progress),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    activeUploads.isNotEmpty
                        ? '${activeUploads.length} active upload${activeUploads.length == 1 ? '' : 's'}'
                        : 'No active uploads',
                    style:
                        const TextStyle(color: VColors.muted, fontSize: 12),
                  ),
                  Text(
                    activity.totalBytes != null && activity.totalBytes! > 0
                        ? '${formatBytes(activity.receivedBytes ?? 0)} / ${formatBytes(activity.totalBytes!)}'
                        : activity.status == UploadStatus.complete
                            ? 'Upload finished'
                            : 'Waiting for browser upload',
                    style:
                        const TextStyle(color: VColors.muted, fontSize: 12),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              for (final upload in activeUploads)
                _ActiveUploadRow(upload: upload),
            ],
          ),
        ),
      ],
    );
  }
}

class _ActiveUploadRow extends StatelessWidget {
  const _ActiveUploadRow({required this.upload});

  final ActiveUploadRow upload;

  @override
  Widget build(BuildContext context) {
    final progress = upload.totalBytes > 0
        ? (upload.receivedBytes / upload.totalBytes).clamp(0.0, 1.0)
        : 0.0;
    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: VColors.cardBackground,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: VColors.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Text(
                  upload.fileName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontWeight: FontWeight.w700, color: VColors.ink),
                ),
              ),
              Text(
                formatDate(upload.updatedAt),
                style: const TextStyle(color: VColors.muted, fontSize: 11),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            upload.message,
            style: const TextStyle(color: VColors.muted, fontSize: 12),
          ),
          const SizedBox(height: 8),
          _ProgressTrack(progress: progress),
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '${formatBytes(upload.receivedBytes)} / ${formatBytes(upload.totalBytes)}',
                style: const TextStyle(color: VColors.muted, fontSize: 12),
              ),
              Text(
                '${(progress * 100).round()}%',
                style: const TextStyle(color: VColors.muted, fontSize: 12),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ProgressTrack extends StatelessWidget {
  const _ProgressTrack({required this.progress});

  final double progress;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: SizedBox(
        height: 10,
        child: ColoredBox(
          color: VColors.accent.withValues(alpha: 0.08),
          child: Align(
            alignment: Alignment.centerLeft,
            child: FractionallySizedBox(
              widthFactor: progress.clamp(0.0, 1.0),
              heightFactor: 1,
              child: const ColoredBox(color: VColors.accent),
            ),
          ),
        ),
      ),
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({
    required this.title,
    required this.subtitle,
    required this.child,
  });

  final String title;
  final String subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: VColors.cardBackground,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: VColors.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: VColors.ink,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            subtitle,
            style: const TextStyle(color: VColors.muted, fontSize: 13),
          ),
          const SizedBox(height: 16),
          child,
        ],
      ),
    );
  }
}
