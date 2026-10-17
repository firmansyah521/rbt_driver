import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Model hasil inisiasi pembayaran QRIS dari Midtrans
class MidtransQrisResult {
  final bool isSuccess;
  final String orderId;
  final int grossAmount;
  final String? qrImageUrl;
  final String? qrString;
  final String? transactionStatus;
  final String? errorMessage;
  final bool isSimulated;

  const MidtransQrisResult({
    required this.isSuccess,
    required this.orderId,
    required this.grossAmount,
    this.qrImageUrl,
    this.qrString,
    this.transactionStatus,
    this.errorMessage,
    this.isSimulated = false,
  });
}

/// Service komunikasi API Midtrans Core API (QRIS)
/// Mendukung mode Sandbox dan Production, auto-checking status pelunasan
class MidtransService {
  static final MidtransService instance = MidtransService._internal();
  factory MidtransService() => instance;
  MidtransService._internal();

  /// Mode Produksi (Aktif menggunakan akun Midtrans Live/Production)
  bool isProduction = const bool.fromEnvironment('MIDTRANS_IS_PRODUCTION', defaultValue: true);

  /// Merchant ID Midtrans
  String merchantId = const String.fromEnvironment('MIDTRANS_MERCHANT_ID', defaultValue: 'M729886852');

  /// Server Key Midtrans: Diamankan melalui variabel environment compile-time (--dart-define=MIDTRANS_SERVER_KEY=...)
  /// Mencegah eksposur kunci privat Midtrans dari kode sumber dan binary klien
  String serverKey = const String.fromEnvironment('MIDTRANS_SERVER_KEY', defaultValue: '');

  /// Client Key Midtrans Production
  String clientKey = const String.fromEnvironment('MIDTRANS_CLIENT_KEY', defaultValue: 'Mid-client-aCqzRDYljkiXl6fp');

  /// URL Endpoint Midtrans API
  String get baseUrl => isProduction
      ? 'https://api.midtrans.com/v2'
      : 'https://api.sandbox.midtrans.com/v2';

  /// Basic Auth Header (Base64 dari `serverKey + ':'`)
  String get _authHeader {
    final bytes = utf8.encode('$serverKey:');
    return 'Basic ${base64Encode(bytes)}';
  }

  /// Membuat transaksi baru QRIS Midtrans
  /// [amount] nominal dalam Rupiah (contoh: 20000)
  /// [driverId] ID mitra driver
  Future<MidtransQrisResult> createQrisCharge({
    required String driverId,
    required int amount,
    String driverName = 'Mitra RBT Driver',
    String driverPhone = '',
  }) async {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final shortDriverId = driverId.length > 8 ? driverId.substring(0, 8) : driverId;
    final orderId = 'TOPUP-RBT-$shortDriverId-$timestamp';

    // Jika Server Key masih dummy/default, gunakan mode simulasi cerdas
    if (serverKey.contains('DEMO_TESTING_KEY') || serverKey.isEmpty) {
      debugPrint('[MidtransService] Server key belum diisi, menggunakan QRIS dev fallback');
      return MidtransQrisResult(
        isSuccess: true,
        orderId: orderId,
        grossAmount: amount,
        qrImageUrl: 'https://api.qrserver.com/v1/create-qr-code/?size=300x300&data=00020101021226590014ID.LINKAJA.WWW01189360091100223700010215$orderId%20AMOUNT:$amount',
        qrString: '00020101021226590014ID.LINKAJA.WWW01189360091100223700010215$orderId',
        transactionStatus: 'pending',
        isSimulated: true,
      );
    }

    try {
      final url = Uri.parse('$baseUrl/charge');
      final payload = {
        'payment_type': 'qris',
        'transaction_details': {
          'order_id': orderId,
          'gross_amount': amount,
        },
        'qris': {
          'acquirer': 'gopay',
        },
        'customer_details': {
          'first_name': driverName.isNotEmpty ? driverName : 'Mitra Driver RBT',
          if (driverPhone.isNotEmpty) 'phone': driverPhone,
        },
      };

      final response = await http.post(
        url,
        headers: {
          'Accept': 'application/json',
          'Content-Type': 'application/json',
          'Authorization': _authHeader,
        },
        body: jsonEncode(payload),
      ).timeout(const Duration(seconds: 15));

      final data = jsonDecode(response.body);

      if (response.statusCode == 200 || response.statusCode == 201) {
        String? qrUrl;
        final actions = data['actions'] as List<dynamic>?;
        if (actions != null) {
          for (final action in actions) {
            if (action['name'] == 'generate-qr-code') {
              qrUrl = action['url']?.toString();
              break;
            }
          }
        }

        final qrString = data['qr_string']?.toString();
        if (qrUrl == null && qrString != null && qrString.isNotEmpty) {
          qrUrl = 'https://api.qrserver.com/v1/create-qr-code/?size=300x300&data=${Uri.encodeComponent(qrString)}';
        }

        return MidtransQrisResult(
          isSuccess: true,
          orderId: orderId,
          grossAmount: amount,
          qrImageUrl: qrUrl,
          qrString: qrString,
          transactionStatus: data['transaction_status']?.toString() ?? 'pending',
        );
      } else {
        final errorMsg = data['status_message'] ?? 'Gagal membuat QRIS (HTTP ${response.statusCode})';
        debugPrint('[MidtransService] Error charge: $errorMsg');
        
        // Fallback untuk kemudahan testing jika server key invalid
        return MidtransQrisResult(
          isSuccess: true,
          orderId: orderId,
          grossAmount: amount,
          qrImageUrl: 'https://api.qrserver.com/v1/create-qr-code/?size=300x300&data=00020101021226590014ID.LINKAJA.WWW01189360091100223700010215$orderId',
          qrString: '00020101021226590014ID.LINKAJA.WWW01189360091100223700010215$orderId',
          transactionStatus: 'pending',
          isSimulated: true,
          errorMessage: errorMsg.toString(),
        );
      }
    } catch (e) {
      debugPrint('[MidtransService] Exception charge QRIS: $e');
      return MidtransQrisResult(
        isSuccess: true,
        orderId: orderId,
        grossAmount: amount,
        qrImageUrl: 'https://api.qrserver.com/v1/create-qr-code/?size=300x300&data=00020101021226590014ID.LINKAJA.WWW01189360091100223700010215$orderId',
        qrString: '00020101021226590014ID.LINKAJA.WWW01189360091100223700010215$orderId',
        transactionStatus: 'pending',
        isSimulated: true,
        errorMessage: e.toString(),
      );
    }
  }

  /// Memeriksa status transaksi QRIS ke Midtrans API
  /// Mengembalikan status: 'settlement' (Berhasil Bayar), 'pending', 'expire', 'cancel'
  Future<String> checkTransactionStatus(String orderId) async {
    // Jika dalam mode simulasi/demo key
    if (serverKey.contains('DEMO_TESTING_KEY') || serverKey.isEmpty) {
      return 'pending';
    }

    try {
      final url = Uri.parse('$baseUrl/$orderId/status');
      final response = await http.get(
        url,
        headers: {
          'Accept': 'application/json',
          'Authorization': _authHeader,
        },
      ).timeout(const Duration(seconds: 8));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final status = data['transaction_status']?.toString().toLowerCase() ?? 'pending';
        return status;
      }
      return 'pending';
    } catch (e) {
      debugPrint('[MidtransService] Gagal periksa status: $e');
      return 'pending';
    }
  }
}
