import 'dart:math' as math;

String formatBytes(num value) {
  if (!value.isFinite || value <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  final index =
      math.min((math.log(value) / math.log(1024)).floor(), units.length - 1);
  final scaled = value / math.pow(1024, index);
  final digits = scaled >= 10 || index == 0 ? 0 : 1;
  return '${scaled.toStringAsFixed(digits)} ${units[index]}';
}

String formatDate(int millisecondsSinceEpoch) {
  final date = DateTime.fromMillisecondsSinceEpoch(millisecondsSinceEpoch);
  String two(int v) => v.toString().padLeft(2, '0');
  return '${date.year}-${two(date.month)}-${two(date.day)} '
      '${two(date.hour)}:${two(date.minute)}:${two(date.second)}';
}

String formatDuration(double? value) {
  if (value == null || !value.isFinite || value < 0) return '--:--';
  final totalSeconds = value.floor();
  final hours = totalSeconds ~/ 3600;
  final minutes = (totalSeconds % 3600) ~/ 60;
  final seconds = totalSeconds % 60;
  String two(int v) => v.toString().padLeft(2, '0');
  if (hours > 0) return '${two(hours)}:${two(minutes)}:${two(seconds)}';
  return '${two(minutes)}:${two(seconds)}';
}

int normalizePort(String value, int fallback) {
  final parsed = int.tryParse(value);
  if (parsed == null || parsed < 1025 || parsed > 65535) return fallback;
  return parsed;
}
