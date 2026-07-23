import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/app_providers.dart';
import '../theme.dart';

/// Rounded card behind each inset-grouped section, themed to the app palette.
final _sectionDecoration = BoxDecoration(
  color: VColors.cardBackground,
  borderRadius: BorderRadius.circular(12),
  border: Border.all(color: VColors.cardBorder),
);

const _headerStyle = TextStyle(
  color: VColors.muted,
  fontSize: 13,
  fontWeight: FontWeight.w400,
);

const _footerStyle = TextStyle(color: VColors.muted, fontSize: 13);

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  void _openConcurrencyPicker(BuildContext context) {
    Navigator.of(context).push(
      CupertinoPageRoute<void>(
        builder: (_) => const ConcurrencyPickerScreen(),
      ),
    );
  }

  void _openSubtitleSizePicker(BuildContext context) {
    Navigator.of(context).push(
      CupertinoPageRoute<void>(
        builder: (_) => const SubtitleFontSizePickerScreen(),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final maxParallelUploads = ref.watch(uploadSettingsProvider);
    final subtitleFontSize = ref.watch(subtitleFontSizeProvider);

    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(20, 16, 20, 8),
          child: Text(
            'Settings',
            style: TextStyle(
              fontSize: 34,
              fontWeight: FontWeight.w700,
              color: VColors.ink,
              letterSpacing: 0.4,
            ),
          ),
        ),
        CupertinoListSection.insetGrouped(
          backgroundColor: VColors.background,
          decoration: _sectionDecoration,
          header: const Text('Upload', style: _headerStyle),
          footer: const Text(
            'Refresh the browser upload page to apply changes.',
            style: _footerStyle,
          ),
          children: [
            CupertinoListTile(
              backgroundColor: VColors.cardBackground,
              backgroundColorActivated: VColors.cardPressed,
              title: const Text(
                'Concurrent uploads',
                style: TextStyle(color: VColors.ink, fontSize: 16),
              ),
              additionalInfo: Text(
                '$maxParallelUploads',
                style: const TextStyle(color: VColors.muted, fontSize: 16),
              ),
              trailing: const CupertinoListTileChevron(),
              onTap: () => _openConcurrencyPicker(context),
            ),
          ],
        ),
        CupertinoListSection.insetGrouped(
          backgroundColor: VColors.background,
          decoration: _sectionDecoration,
          header: const Text('Subtitles', style: _headerStyle),
          footer: const Text(
            'Applies to subtitles shown while playing a video.',
            style: _footerStyle,
          ),
          children: [
            CupertinoListTile(
              backgroundColor: VColors.cardBackground,
              backgroundColorActivated: VColors.cardPressed,
              title: const Text(
                'Subtitle size',
                style: TextStyle(color: VColors.ink, fontSize: 16),
              ),
              additionalInfo: Text(
                '$subtitleFontSize pt',
                style: const TextStyle(color: VColors.muted, fontSize: 16),
              ),
              trailing: const CupertinoListTileChevron(),
              onTap: () => _openSubtitleSizePicker(context),
            ),
          ],
        ),
      ],
    );
  }
}

/// Detail page listing the concurrency options with a checkmark on the
/// selected value (classic iOS Settings drill-down).
class ConcurrencyPickerScreen extends ConsumerWidget {
  const ConcurrencyPickerScreen({super.key});

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

  Future<void> _select(BuildContext context, WidgetRef ref, int value) async {
    final didSave =
        await ref.read(uploadSettingsProvider.notifier).select(value);
    if (!context.mounted) return;
    if (didSave) {
      Navigator.of(context).pop();
    } else {
      await _showError(context, 'Could not save upload settings.');
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final maxParallelUploads = ref.watch(uploadSettingsProvider);

    return CupertinoPageScaffold(
      backgroundColor: VColors.background,
      navigationBar: const CupertinoNavigationBar(
        backgroundColor: VColors.background,
        previousPageTitle: 'Settings',
        middle: Text('Concurrent uploads'),
      ),
      child: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          CupertinoListSection.insetGrouped(
            backgroundColor: VColors.background,
            decoration: _sectionDecoration,
            dividerMargin: 20,
            additionalDividerMargin: 0,
            footer: const Text(
              'Choose how many files the browser uploader can send in parallel.',
              style: _footerStyle,
            ),
            children: [
              for (final value in uploadConcurrencyOptions)
                CupertinoListTile(
                  backgroundColor: VColors.cardBackground,
                  backgroundColorActivated: VColors.cardPressed,
                  title: Text(
                    '$value',
                    style: const TextStyle(color: VColors.ink, fontSize: 16),
                  ),
                  trailing: value == maxParallelUploads
                      ? const Icon(
                          CupertinoIcons.check_mark,
                          size: 22,
                          color: VColors.accent,
                        )
                      : null,
                  onTap: () => _select(context, ref, value),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Detail page listing the subtitle font-size options with a checkmark on the
/// selected value (classic iOS Settings drill-down).
class SubtitleFontSizePickerScreen extends ConsumerWidget {
  const SubtitleFontSizePickerScreen({super.key});

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

  Future<void> _select(BuildContext context, WidgetRef ref, int value) async {
    final didSave =
        await ref.read(subtitleFontSizeProvider.notifier).select(value);
    if (!context.mounted) return;
    if (didSave) {
      Navigator.of(context).pop();
    } else {
      await _showError(context, 'Could not save subtitle settings.');
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final subtitleFontSize = ref.watch(subtitleFontSizeProvider);

    return CupertinoPageScaffold(
      backgroundColor: VColors.background,
      navigationBar: const CupertinoNavigationBar(
        backgroundColor: VColors.background,
        previousPageTitle: 'Settings',
        middle: Text('Subtitle size'),
      ),
      child: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          CupertinoListSection.insetGrouped(
            backgroundColor: VColors.background,
            decoration: _sectionDecoration,
            dividerMargin: 20,
            additionalDividerMargin: 0,
            footer: const Text(
              'Choose the on-screen text size for video subtitles.',
              style: _footerStyle,
            ),
            children: [
              for (final value in subtitleFontSizeOptions)
                CupertinoListTile(
                  backgroundColor: VColors.cardBackground,
                  backgroundColorActivated: VColors.cardPressed,
                  title: Text(
                    '$value pt',
                    style: const TextStyle(color: VColors.ink, fontSize: 16),
                  ),
                  trailing: value == subtitleFontSize
                      ? const Icon(
                          CupertinoIcons.check_mark,
                          size: 22,
                          color: VColors.accent,
                        )
                      : null,
                  onTap: () => _select(context, ref, value),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
