import 'clamped_int_setting_store.dart';

const minSubtitleFontSize = 24;
const maxSubtitleFontSize = 48;
const defaultSubtitleFontSize = 36;

int clampSubtitleFontSize(Object? input) => ClampedIntSettingStore.clampValue(
      input,
      min: minSubtitleFontSize,
      max: maxSubtitleFontSize,
      fallback: defaultSubtitleFontSize,
    );

/// Persists subtitle settings in `<documents>/subtitle-settings.json`.
class SubtitleSettingsStore {
  SubtitleSettingsStore(String documentsPath)
      : _store = ClampedIntSettingStore(
          documentsPath: documentsPath,
          fileName: 'subtitle-settings.json',
          jsonKey: 'subtitleFontSize',
          min: minSubtitleFontSize,
          max: maxSubtitleFontSize,
          defaultValue: defaultSubtitleFontSize,
        );

  final ClampedIntSettingStore _store;

  Future<int> getSubtitleFontSize() => _store.read();

  Future<int> saveSubtitleFontSize(int value) => _store.write(value);
}
