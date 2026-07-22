import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/app_providers.dart';
import '../theme.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

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

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final maxParallelUploads = ref.watch(uploadSettingsProvider);

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: VColors.cardBackground,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: VColors.cardBorder),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Upload settings',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: VColors.ink,
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                'Control how many files the browser uploader sends at once.',
                style: TextStyle(color: VColors.muted, fontSize: 13),
              ),
              const SizedBox(height: 16),
              const Text(
                'Concurrent uploads',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: VColors.ink,
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                'Choose how many files the browser uploader can send in parallel.',
                style: TextStyle(color: VColors.muted, fontSize: 12),
              ),
              const SizedBox(height: 12),
              CupertinoSlidingSegmentedControl<int>(
                groupValue: maxParallelUploads,
                backgroundColor: VColors.background,
                thumbColor: VColors.accent,
                children: {
                  for (final value in uploadConcurrencyOptions)
                    value: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Text(
                        '$value',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: value == maxParallelUploads
                              ? CupertinoColors.white
                              : VColors.ink,
                        ),
                      ),
                    ),
                },
                onValueChanged: (value) async {
                  if (value == null) return;
                  final didSave = await ref
                      .read(uploadSettingsProvider.notifier)
                      .select(value);
                  if (!didSave && context.mounted) {
                    await _showError(
                        context, 'Could not save upload settings.');
                  }
                },
              ),
              const SizedBox(height: 12),
              const Text(
                'Refresh the browser upload page to apply changes.',
                style: TextStyle(color: VColors.muted, fontSize: 12),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
