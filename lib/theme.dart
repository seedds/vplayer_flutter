import 'package:flutter/cupertino.dart';

/// VPlayer palette (matches the original app).
abstract final class VColors {
  static const background = Color(0xFFEFE7DB);
  static const border = Color(0xFFDED1C2);
  static const accent = Color(0xFF1F6F68);
  static const ink = Color(0xFF1D1917);
  static const inactive = Color(0xFF4F463F);
  static const muted = Color(0xFF6B6158);
  static const cardBackground = Color(0xFFFFF8F1);
  static const cardBorder = Color(0xFFDDCFBF);
  static const cardPressed = Color(0xFFE6DDD2);
  static const cardSelected = Color(0xFFEEF7F5);
  static const thumbnailBackground = Color(0xFFD7CCC1);
  static const deleteRed = Color(0xFFC84630);
  static const deleteRedPressed = Color(0xFFA93523);
}

CupertinoThemeData buildAppTheme() {
  return const CupertinoThemeData(
    brightness: Brightness.light,
    primaryColor: VColors.accent,
    primaryContrastingColor: VColors.background,
    scaffoldBackgroundColor: VColors.background,
    barBackgroundColor: VColors.background,
    applyThemeToAll: true,
    textTheme: CupertinoTextThemeData(
      primaryColor: VColors.accent,
      textStyle: TextStyle(
        color: VColors.ink,
        fontSize: 16,
        letterSpacing: -0.2,
      ),
    ),
  );
}
