import 'package:flutter/material.dart';

/// Tema Khusus Driver RBT Online Pidie
/// Dirancang High-Contrast (Dark Theme) agar sangat jelas terbaca di bawah terik matahari Pidie
/// serta hemat daya baterai saat mitra bekerja di jalanan seharian.
class DriverTheme {
  // Warna Primer & Latar Belakang
  static const Color darkBg = Color(0xFF0B132B);
  static const Color surfaceDark = Color(0xFF1C2541);
  static const Color cardDark = Color(0xFF243054);
  static const Color cardBorder = Color(0xFF3A4B7C);

  // Aksen Sinyal & Status
  static const Color electricBlue = Color(0xFF2563EB);
  static const Color brightCyan = Color(0xFF00B4D8);
  static const Color onlineGreen = Color(0xFF10B981);
  static const Color offlineRed = Color(0xFFEF4444);
  static const Color alertAmber = Color(0xFFF59E0B);
  static const Color warningYellow = Color(0xFFF59E0B);
  static const Color foodOrange = Color(0xFFEA580C);

  // Tipografi & Warna Teks
  static const Color textPrimary = Color(0xFFF8FAFC);
  static const Color textSecondary = Color(0xFF94A3B8);
  static const Color textMuted = Color(0xFF64748B);

  // Box Shadow & Elevasi
  static List<BoxShadow> softShadow = [
    BoxShadow(
      color: Colors.black.withValues(alpha: 0.35),
      blurRadius: 10,
      offset: const Offset(0, 4),
    ),
  ];

  static List<BoxShadow> glowGreen = [
    BoxShadow(
      color: onlineGreen.withValues(alpha: 0.4),
      blurRadius: 12,
      spreadRadius: 2,
    ),
  ];

  static ThemeData get themeData {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: darkBg,
      primaryColor: electricBlue,
      colorScheme: const ColorScheme.dark(
        primary: electricBlue,
        secondary: brightCyan,
        surface: surfaceDark,
        error: offlineRed,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: surfaceDark,
        elevation: 0,
        centerTitle: true,
        titleTextStyle: TextStyle(
          color: textPrimary,
          fontSize: 17,
          fontWeight: FontWeight.bold,
          letterSpacing: 0.5,
        ),
        iconTheme: IconThemeData(color: textPrimary),
      ),
      cardTheme: CardThemeData(
        color: cardDark,
        elevation: 3,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: cardBorder, width: 1),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: electricBlue,
          foregroundColor: Colors.white,
          minimumSize: const Size(64, 48),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          textStyle: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
            letterSpacing: 0.5,
          ),
        ),
      ),
    );
  }
}
