import 'package:flutter/cupertino.dart';

import '../theme.dart';

/// Classic iOS Settings drill-down: a list of integer [options] with a
/// checkmark on the [selectedValue]. Tapping an option calls [onSelect]; if it
/// reports success the page pops, otherwise [errorMessage] is shown.
class SettingPickerScreen extends StatelessWidget {
  const SettingPickerScreen({
    super.key,
    required this.title,
    required this.footer,
    required this.options,
    required this.selectedValue,
    required this.labelFor,
    required this.onSelect,
    required this.errorMessage,
  });

  final String title;
  final String footer;
  final List<int> options;
  final int selectedValue;
  final String Function(int value) labelFor;

  /// Persists [value]; returns `true` on success, `false` to surface
  /// [errorMessage].
  final Future<bool> Function(int value) onSelect;
  final String errorMessage;

  Future<void> _handleTap(BuildContext context, int value) async {
    final didSave = await onSelect(value);
    if (!context.mounted) return;
    if (didSave) {
      Navigator.of(context).pop();
    } else {
      await showCupertinoDialog<void>(
        context: context,
        builder: (context) => CupertinoAlertDialog(
          title: const Text('Error'),
          content: Text(errorMessage),
          actions: [
            CupertinoDialogAction(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      backgroundColor: VColors.background,
      navigationBar: CupertinoNavigationBar(
        backgroundColor: VColors.background,
        previousPageTitle: 'Settings',
        middle: Text(title),
      ),
      child: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          CupertinoListSection.insetGrouped(
            backgroundColor: VColors.background,
            decoration: BoxDecoration(
              color: VColors.cardBackground,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: VColors.cardBorder),
            ),
            dividerMargin: 20,
            additionalDividerMargin: 0,
            footer: Text(
              footer,
              style: const TextStyle(color: VColors.muted, fontSize: 13),
            ),
            children: [
              for (final value in options)
                CupertinoListTile(
                  backgroundColor: VColors.cardBackground,
                  backgroundColorActivated: VColors.cardPressed,
                  title: Text(
                    labelFor(value),
                    style: const TextStyle(color: VColors.ink, fontSize: 16),
                  ),
                  trailing: value == selectedValue
                      ? const Icon(
                          CupertinoIcons.check_mark,
                          size: 22,
                          color: VColors.accent,
                        )
                      : null,
                  onTap: () => _handleTap(context, value),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
