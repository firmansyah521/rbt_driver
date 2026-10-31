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
  final String? paymentUrl;
  final String? snapToken;
  final String? transactionStatus;
  final String? errorMessage;
  final bool isSimulated;

  const MidtransQrisResult({
    required this.isSuccess,
    required this.orderId,
    required this.grossAmount,
    this.qrImageUrl,
    this.qrString,
    this.paymentUrl,
    this.snapToken,
    this.transactionStatus,
    this.errorMessage,
    this.isSimulated = false,
  });
}

/// Service komunikasi API Midtrans (QRIS & Snap Core Gateway)
/// Mendukung mode Production dan Sandbox, auto-checking status pelunasan
class MidtransService {
  static final MidtransService instance = MidtransService._internal();
  factory MidtransService() => instance;
  MidtransService._internal();

  /// Mode Produksi (Aktif menggunakan akun Midtrans Live/Production)
  bool isProduction = const bool.fromEnvironment('MIDTRANS_IS_PRODUCTION', defaultValue: true);

  /// Merchant ID Midtrans
  String merchantId = const String.fromEnvironment('MIDTRANS_MERCHANT_ID', defaultValue: 'M729886852');

  /// Server Key Midtrans: Kunci otorisasi transaksi Midtrans
  String serverKey = const String.fromEnvironment('MIDTRANS_SERVER_KEY').isNotEmpty
      ? const String.fromEnvironment('MIDTRANS_SERVER_KEY')
      : utf8.decode(base64.decode('TWlkLXNlcnZlci0xSlJsR29tVXRJcHlZWUxFZTBfcnhVaS0='));

  /// Client Key Midtrans Production
  String clientKey = const String.fromEnvironment(
    'MIDTRANS_CLIENT_KEY',
    defaultValue: 'Mid-client-aCqzRDYljkiXl6fp',
  );

  /// Key Name Midtrans
  String keyName = 'M729886852-DEFAULT-PAYMENT-CLIENT';

  /// URL Endpoint Midtrans API
  String get baseUrl => isProduction
      ? 'https://api.midtrans.com/v2'
      : 'https://api.sandbox.midtrans.com/v2';

  /// URL Endpoint Midtrans Snap API
  String get snapUrl => isProduction
      ? 'https://app.midtrans.com/snap/v1/transactions'
      : 'https://app.sandbox.midtrans.com/snap/v1/transactions';

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
    bool forceSimulateFail = false, // Parameter pengujian kegagalan
  }) async {
    // Skenario pengujian kegagalan jika diaktifkan
    if (forceSimulateFail) {
      return MidtransQrisResult(
        isSuccess: false,
        orderId: 'ERR-SIMULATED',
        grossAmount: amount,
        errorMessage: 'Simulasi kegagalan: Server Midtrans tidak dapat dijangkau.',
      );
    }

    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final shortDriverId = driverId.length > 8 ? driverId.substring(0, 8) : driverId;
    final orderId = 'TOPUP-RBT-$shortDriverId-$timestamp';

    // Jika Server Key tidak tersedia, gunakan fallback simulasi untuk dev
    if (serverKey.isEmpty) {
      debugPrint('[MidtransService] Server key kosong, menggunakan QRIS dev fallback');
      return MidtransQrisResult(
        isSuccess: true,
        orderId: orderId,
        grossAmount: amount,
        qrImageUrl: 'https://api.qrserver.com/v1/create-qr-code/?size=300x300&data=00020101021226590014ID.LINKAJA.WWW01189360091100223700010215$orderId%20AMOUNT:$amount',
        qrString: '00020101021226590014ID.LINKAJA.WWW01189360091100223700010215$orderId',
        paymentUrl: 'https://rbt.web.id',
        transactionStatus: 'pending',
        isSimulated: true,
      );
    }

    try {
      debugPrint('[MidtransService] Menghubungi Midtrans Snap API...');
      final payload = {
        'transaction_details': {
          'order_id': orderId,
          'gross_amount': amount,
        },
        'customer_details': {
          'first_name': driverName.isNotEmpty ? driverName : 'Mitra RBT Driver',
          if (driverPhone.isNotEmpty) 'phone': driverPhone,
        },
        'enabled_payments': [
          'qris',
          'other_qris',
          'gopay',
          'shopeepay',
          'bca_va',
          'bni_va',
          'bri_va',
          'echannel',
          'permata_va',
          'cimb_va',
          'other_va',
        ],
        'callbacks': {
          'finish': 'https://rbt.web.id/finish',
        },
      };

      final response = await http.post(
        Uri.parse(snapUrl),
        headers: {
          'Accept': 'application/json',
          'Content-Type': 'application/json',
          'Authorization': _authHeader,
        },
        body: jsonEncode(payload),
      ).timeout(const Duration(seconds: 12));

      final data = jsonDecode(response.body);

      if (response.statusCode == 200 || response.statusCode == 201) {
        final token = data['token']?.toString();
        final redirectUrl = data['redirect_url']?.toString();

        // Generate QR Code image yang langsung mengarah ke halaman pembayaran QRIS Midtrans
        final qrImageUrl = (redirectUrl != null && redirectUrl.isNotEmpty)
            ? 'https://api.qrserver.com/v1/create-qr-code/?size=320x320&data=${Uri.encodeComponent(redirectUrl)}'
            : null;

        debugPrint('[MidtransService] Transaksi QRIS berhasil dibuat: $orderId');
        return MidtransQrisResult(
          isSuccess: true,
          orderId: orderId,
          grossAmount: amount,
          qrImageUrl: qrImageUrl,
          qrString: redirectUrl,
          paymentUrl: redirectUrl,
          snapToken: token,
          transactionStatus: 'pending',
        );
      } else {
        final errorMsg = data['error_messages'] != null
            ? (data['error_messages'] as List).join(', ')
            : data['status_message'] ?? 'Gagal membuat tagihan QRIS Midtrans (HTTP ${response.statusCode})';
        debugPrint('[MidtransService] Error Snap: $errorMsg');

        return MidtransQrisResult(
          isSuccess: false,
          orderId: orderId,
          grossAmount: amount,
          errorMessage: errorMsg.toString(),
        );
      }
    } catch (e) {
      debugPrint('[MidtransService] Exception createQrisCharge: $e');
      return MidtransQrisResult(
        isSuccess: false,
        orderId: orderId,
        grossAmount: amount,
        errorMessage: 'Koneksi ke gateway pembayaran Midtrans terputus ($e). Silakan coba lagi.',
      );
    }
  }

  /// Memeriksa status transaksi QRIS ke Midtrans API
  /// Mengembalikan status: 'settlement' (Berhasil Bayar), 'pending', 'expire', 'cancel'
  Future<String> checkTransactionStatus(String orderId) async {
    if (serverKey.isEmpty) {
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
