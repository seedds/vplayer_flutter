import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/app_providers.dart';
import '../theme.dart';
import '../widgets/setting_picker_screen.dart';

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

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SettingPickerScreen(
      title: 'Concurrent uploads',
      footer:
          'Choose how many files the browser uploader can send in parallel.',
      options: uploadConcurrencyOptions,
      selectedValue: ref.watch(uploadSettingsProvider),
      labelFor: (value) => '$value',
      onSelect: (value) =>
          ref.read(uploadSettingsProvider.notifier).select(value),
      errorMessage: 'Could not save upload settings.',
    );
  }
}

/// Detail page listing the subtitle font-size options with a checkmark on the
/// selected value (classic iOS Settings drill-down).
class SubtitleFontSizePickerScreen extends ConsumerWidget {
  const SubtitleFontSizePickerScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SettingPickerScreen(
      title: 'Subtitle size',
      footer: 'Choose the on-screen text size for video subtitles.',
      options: subtitleFontSizeOptions,
      selectedValue: ref.watch(subtitleFontSizeProvider),
      labelFor: (value) => '$value pt',
      onSelect: (value) =>
          ref.read(subtitleFontSizeProvider.notifier).select(value),
      errorMessage: 'Could not save subtitle settings.',
    );
  }
}
