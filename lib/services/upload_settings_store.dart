import 'clamped_int_setting_store.dart';

const minMaxParallelUploads = 1;
const maxMaxParallelUploads = 5;
const defaultMaxParallelUploads = 3;

int clampMaxParallelUploads(Object? input) => ClampedIntSettingStore.clampValue(
      input,
      min: minMaxParallelUploads,
      max: maxMaxParallelUploads,
      fallback: defaultMaxParallelUploads,
    );

/// Persists upload settings in `<documents>/upload-settings.json`.
class UploadSettingsStore {
  UploadSettingsStore(String documentsPath)
      : _store = ClampedIntSettingStore(
          documentsPath: documentsPath,
          fileName: 'upload-settings.json',
          jsonKey: 'maxParallelUploads',
          min: minMaxParallelUploads,
          max: maxMaxParallelUploads,
          defaultValue: defaultMaxParallelUploads,
        );

  final ClampedIntSettingStore _store;

  Future<int> getMaxParallelUploads() => _store.read();

  Future<int> saveMaxParallelUploads(int value) => _store.write(value);
}
