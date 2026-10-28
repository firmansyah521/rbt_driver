import 'package:flutter/material.dart';

/// Tema Aplikasi Driver RBT Online Pidie
/// Modern Minimalis Dark — Elegan, Hangat, Tidak Kaku
/// OLED-friendly dark dengan aksen Biru Benhur yang presisi
class DriverTheme {
  // Latar Belakang Utama (Dark)
  static const Color darkBg = Color(0xFF0A0C10); // Near-black dengan sedikit biru
  static const Color surfaceDark = Color(0xFF111520); // Deep navy-dark surface
  static const Color cardDark = Color(0xFF171D2C); // Card dark dengan nuansa biru
  static const Color cardBorder = Color(0xFF252D40); // Border halus biru-navy

  // Palet Uber-like
  static const Color uberBlack = Color(0xFF000000);
  static const Color uberWhite = Color(0xFFFFFFFF);
  static const Color uberPillBg = Color(0xFF1A2236);
  static const Color uberBorder = Color(0xFF2A3450);
  static const Color uberGrey = Color(0xFF6B7A99);

  // Aksen Brand Biru Benhur RBT Pidie
  static const Color primaryBenhur = Color(0xFF0038A8);
  static const Color primaryBenhurDark = Color(0xFF002270);
  static const Color primaryBenhurLight = Color(0xFF3D7EFF); // Biru Benhur terang untuk kontras OLED
  static const Color electricBlue = Color(0xFF0038A8);
  static const Color brightCyan = Color(0xFF60A5FA); // Soft blue accent
  static const Color onlineGreen = Color(0xFF00D563); // Active green
  static const Color offlineRed = Color(0xFFFF4040);
  static const Color alertAmber = Color(0xFFFBBF24);
  static const Color warningYellow = Color(0xFFFBBF24);
  static const Color foodOrange = Color(0xFFFB923C);

  // Tipografi (High Contrast OLED)
  static const Color textPrimary = Color(0xFFF0F4FF); // Slightly blue-white
  static const Color textSecondary = Color(0xFF8FA3C8);
  static const Color textMuted = Color(0xFF4A5878);

  // Shadow Tokens
  static const List<BoxShadow> softShadow = [
    BoxShadow(
      color: Color(0x22000000),
      blurRadius: 12,
      offset: Offset(0, 3),
    ),
  ];

  static const List<BoxShadow> glowGreen = [
    BoxShadow(
      color: Color(0x4400D563),
      blurRadius: 12,
      spreadRadius: 1,
    ),
  ];

  static const List<BoxShadow> glowBlue = [
    BoxShadow(
      color: Color(0x330038A8),
      blurRadius: 12,
      spreadRadius: 1,
    ),
  ];

  static ThemeData get themeData {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: darkBg,
      primaryColor: primaryBenhur,
      colorScheme: const ColorScheme.dark(
        primary: primaryBenhur,
        secondary: onlineGreen,
        surface: surfaceDark,
        error: offlineRed,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: primaryBenhur,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        titleTextStyle: TextStyle(
          color: Colors.white,
          fontSize: 16,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.2,
        ),
        iconTheme: IconThemeData(color: Colors.white),
      ),
      cardTheme: CardThemeData(
        color: cardDark,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: cardBorder, width: 1),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: primaryBenhur,
          foregroundColor: Colors.white,
          minimumSize: const Size(64, 48),
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          textStyle: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.2,
          ),
        ),
      ),
      dividerTheme: const DividerThemeData(
        color: cardBorder,
        thickness: 1,
        space: 1,
      ),
    );
  }
}
