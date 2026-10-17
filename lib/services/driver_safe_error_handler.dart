import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Utilitas Keamanan untuk Aplikasi Mitra Driver RBT Pidie
/// Menjamin API Key, Token, dan Detail Teknis Backend TIDAK AKAN PERNAH bocor ke layar driver
class DriverSafeErrorHandler {
  static const String _defaultAnonKey = 'sb_publishable_1tdhGEJNmf8TDU2C__KXTQ_xpn54beP';
  static const String _defaultUrl = 'fmmvtzwigwgfsbmqbqml.supabase.co';

  /// Memeriksa apakah suatu error merupakan gangguan internet / offline
  static bool isNetworkError(dynamic error) {
    if (error == null) return false;
    if (!kIsWeb) {
      if (error is SocketException ||
          error is TimeoutException ||
          error is HandshakeException) {
        return true;
      }
    } else {
      if (error is TimeoutException) {
        return true;
      }
    }

    final str = error.toString().toLowerCase();
    return str.contains('socketexception') ||
        str.contains('failed host lookup') ||
        str.contains('network is unreachable') ||
        str.contains('connection refused') ||
        str.contains('connection closed') ||
        str.contains('connection reset') ||
        str.contains('no address associated with hostname') ||
        str.contains('clientexception') ||
        str.contains('xmlhttprequest') ||
        str.contains('timed out') ||
        str.contains('network_error') ||
        str.contains('offline');
  }

  /// Membersihkan teks agar tidak ada API Key, bearer token, atau URL backend yang bocor
  static String sanitize(String text) {
    var result = text;

    // Sensor anon key / publishable key / JWT
    result = result.replaceAll(_defaultAnonKey, '[PROTECTED_KEY]');
    result = result.replaceAll(RegExp(r'sb_publishable_[a-zA-Z0-9_\-]+'), '[PROTECTED_KEY]');
    result = result.replaceAll(RegExp(r'apikey=[a-zA-Z0-9_\-\.]+'), 'apikey=[PROTECTED]');
    result = result.replaceAll(RegExp(r'Bearer\s+[a-zA-Z0-9_\-\.]+', caseSensitive: false), 'Bearer [PROTECTED]');
    result = result.replaceAll(RegExp(r'eyJ[a-zA-Z0-9_\-]{20,}\.[a-zA-Z0-9_\-]{20,}\.[a-zA-Z0-9_\-]+'), '[JWT_TOKEN_PROTECTED]');

    // Sensor Midtrans keys
    result = result.replaceAll(RegExp(r'Mid-(client|server)-[a-zA-Z0-9_\-]+', caseSensitive: false), '[MIDTRANS_KEY_PROTECTED]');

    // Sensor domain backend & email internal
    result = result.replaceAll(_defaultUrl, '[SERVER_URL]');
    result = result.replaceAll(RegExp(r'https?://[a-zA-Z0-9\-_\.]+\.supabase\.co[^\s]*'), '[SERVER_ENDPOINT]');
    result = result.replaceAll(RegExp(r'[0-9]+@rbtpidie\.app'), '[NOMOR_AKUN]');

    return result;
  }

  /// Mendeteksi apakah pesan mengandung kata kunci teknis / database internal
  static bool hasTechnicalKeywords(String text) {
    final lower = text.toLowerCase();
    const technicalTerms = [
      'exception',
      'error:',
      'postgrest',
      'postgres',
      'sql',
      'column',
      'relation',
      'table',
      'syntax',
      'null value',
      'violates',
      'foreign key',
      'constraint',
      'row-level security',
      'rls',
      'http',
      '500',
      '502',
      '503',
      'type \'',
      'nosuchmethod',
      'formatexception',
      'stacktrace',
      'select ',
      'insert ',
      'update ',
      'delete from',
      'pg_',
      'jwt',
    ];

    for (final term in technicalTerms) {
      if (lower.contains(term)) return true;
    }
    return false;
  }

  /// Mengonversi error apa pun menjadi pesan bahasa Indonesia yang ramah bagi Driver
  static String getUserFriendlyMessage(
    dynamic error, {
    String fallback = 'Terjadi kendala teknis. Silakan coba kembali.',
  }) {
    if (error == null) return fallback;

    // 1. Tangani jika terdeteksi error jaringan / offline
    if (isNetworkError(error)) {
      return 'Koneksi internet mitra terputus. Harap periksa paket data seluler Anda.';
    }

    // 2. Tangani AuthException
    if (error is AuthException) {
      final msg = error.message.toLowerCase();
      if (msg.contains('invalid login credentials') || msg.contains('invalid_credentials')) {
        return 'Nomor WhatsApp atau kata sandi driver salah.';
      }
      if (msg.contains('user already registered') || msg.contains('already registered')) {
        return 'Nomor WhatsApp sudah terdaftar sebagai mitra. Silakan langsung Masuk.';
      }
      if (msg.contains('rate limit')) {
        return 'Terlalu banyak percobaan. Harap tunggu 1 menit.';
      }
      if (hasTechnicalKeywords(error.message)) {
        return 'Terjadi kendala autentikasi. Silakan periksa data login Anda.';
      }
      return sanitize(error.message);
    }

    // 3. Tangani PostgrestException (Pencegahan Kebocoran RLS & Schema)
    if (error is PostgrestException) {
      debugPrint('[DriverSafeErrorHandler] PostgrestException: ${error.message} - ${error.details}');
      return 'Gagal memproses data server mitra. Silakan coba kembali.';
    }

    final raw = error.toString();
    if (isNetworkError(raw)) {
      return 'Koneksi internet mitra terputus. Harap periksa paket data seluler Anda.';
    }

    // Jika mengandung kata kunci teknis, WAJIB gunakan pesan fallback ramah pengguna
    if (hasTechnicalKeywords(raw)) {
      debugPrint('[DriverSafeErrorHandler] Technical exception disensor: ${sanitize(raw)}');
      return fallback;
    }

    final cleaned = sanitize(raw);
    if (cleaned.length > 80) {
      return fallback;
    }
    return cleaned;
  }
}
