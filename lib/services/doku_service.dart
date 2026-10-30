import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:pointycastle/asn1.dart';
import 'package:pointycastle/export.dart';

/// Model hasil inisiasi pembayaran QRIS dari DOKU (Direct SNAP QRIS atau Checkout)
class DokuQrisResult {
  final bool isSuccess;
  final String orderId;
  final int grossAmount;
  final String? paymentUrl;
  final String? qrImageUrl;
  final String? qrString;
  final String? transactionStatus;
  final String? expiredDate;
  final String? errorMessage;
  final bool isDirectSnap;
  final bool isSimulated;

  const DokuQrisResult({
    required this.isSuccess,
    required this.orderId,
    required this.grossAmount,
    this.paymentUrl,
    this.qrImageUrl,
    this.qrString,
    this.transactionStatus,
    this.expiredDate,
    this.errorMessage,
    this.isDirectSnap = false,
    this.isSimulated = false,
  });
}

/// Service komunikasi API DOKU (Mendukung Direct QRIS MPM Standar SNAP BI & Checkout API)
/// Otomatis mengecek pelunasan transaksi secara real-time
class DokuService {
  static final DokuService instance = DokuService._internal();
  factory DokuService() => instance;
  DokuService._internal();

  /// Mode Produksi DOKU (Live)
  bool isProduction = const bool.fromEnvironment('DOKU_IS_PRODUCTION', defaultValue: true);

  /// Client ID DOKU
  String clientId = const String.fromEnvironment('DOKU_CLIENT_ID', defaultValue: 'BRN-0230-1793112691734');

  /// Secret Key DOKU (Digunakan untuk HMAC-SHA256 & HMAC-SHA512)
  String secretKey = const String.fromEnvironment('DOKU_SECRET_KEY', defaultValue: 'SK-owbMU2NnPQIaleD0nSLK');

  /// API Key DOKU
  String apiKey = const String.fromEnvironment('DOKU_API_KEY', defaultValue: 'doku_key_f117f91abcd04675898965ddc26985b8');

  /// Merchant Private Key RSA 2048-bit (Digunakan untuk tanda tangan SNAP B2B Token Asymmetric)
  String merchantPrivateKey = const String.fromEnvironment(
    'DOKU_MERCHANT_PRIVATE_KEY',
    defaultValue: _defaultMerchantPrivateKey,
  );

  /// URL Endpoint DOKU API
  String get baseUrl => isProduction
      ? 'https://api.doku.com'
      : 'https://api-sandbox.doku.com';

  /// Cache token B2B SNAP
  String? _cachedB2bToken;
  DateTime? _tokenExpiry;

  /// Format waktu ISO8601 UTC tanpa milidetik (contoh: 2026-10-28T12:00:00Z)
  String _generateUtcTimestamp() {
    final now = DateTime.now().toUtc();
    return '${now.toIso8601String().split('.').first}Z';
  }

  /// Format waktu ISO8601 dengan offset WIB (+07:00) untuk standar SNAP BI
  String _generateSnapTimestamp() {
    final now = DateTime.now();
    final offsetHours = now.timeZoneOffset.inHours.toString().padLeft(2, '0');
    final offsetMins = (now.timeZoneOffset.inMinutes % 60).toString().padLeft(2, '0');
    final sign = now.timeZoneOffset.isNegative ? '-' : '+';
    final iso = now.toIso8601String().split('.').first;
    return '$iso$sign$offsetHours:$offsetMins';
  }

  /// Menandatangani string menggunakan Private Key RSA 2048-bit (SHA256withRSA)
  String _signSha256WithRsa(String dataToSign) {
    try {
      final cleanPem = merchantPrivateKey
          .split('\n')
          .where((l) => !l.startsWith('---') && l.trim().isNotEmpty)
          .join('');
      final derBytes = base64Decode(cleanPem);
      final parser = ASN1Parser(derBytes);
      final seq = parser.nextObject() as ASN1Sequence;
      final modulus = (seq.elements![1] as ASN1Integer).integer!;
      final privateExponent = (seq.elements![3] as ASN1Integer).integer!;
      final p = (seq.elements![4] as ASN1Integer).integer;
      final q = (seq.elements![5] as ASN1Integer).integer;
      final privKey = RSAPrivateKey(modulus, privateExponent, p, q);

      final signer = RSASigner(SHA256Digest(), '0609608648016503040201');
      signer.init(true, PrivateKeyParameter<RSAPrivateKey>(privKey));
      final sig = signer.generateSignature(Uint8List.fromList(utf8.encode(dataToSign)));
      return base64Encode(sig.bytes);
    } catch (e) {
      debugPrint('[DokuService] Error signing RSA SHA256: $e');
      return '';
    }
  }

  /// Membuat HMAC-SHA512 Signature untuk transaksi SNAP BI
  String _generateSnapSignature({
    required String httpMethod,
    required String endpointUrl,
    required String accessToken,
    required String requestBody,
    required String timestamp,
  }) {
    final bodySha256Hex = sha256.convert(utf8.encode(requestBody)).toString().toLowerCase();
    final stringToSign = '$httpMethod:$endpointUrl:$accessToken:$bodySha256Hex:$timestamp';
    final hmac = Hmac(sha512, utf8.encode(secretKey));
    final signatureBytes = hmac.convert(utf8.encode(stringToSign)).bytes;
    return base64Encode(signatureBytes);
  }

  /// Mendapatkan B2B Access Token SNAP dari DOKU
  Future<String?> getB2BAccessToken() async {
    if (_cachedB2bToken != null && _tokenExpiry != null && DateTime.now().isBefore(_tokenExpiry!)) {
      return _cachedB2bToken;
    }

    try {
      final timestamp = _generateSnapTimestamp();
      final stringToSign = '$clientId|$timestamp';
      final signature = _signSha256WithRsa(stringToSign);

      if (signature.isEmpty) {
        debugPrint('[DokuService] RSA signature gagal dibuat.');
        return null;
      }

      final url = Uri.parse('$baseUrl/authorization/v1/access-token/b2b');
      final response = await http.post(
        url,
        headers: {
          'Content-Type': 'application/json',
          'X-CLIENT-KEY': clientId,
          'X-TIMESTAMP': timestamp,
          'X-SIGNATURE': signature,
        },
        body: jsonEncode({'grantType': 'client_credentials'}),
      ).timeout(const Duration(seconds: 12));

      debugPrint('[DokuService] Token B2B response code: ${response.statusCode}');

      if (response.statusCode == 200 || response.statusCode == 201) {
        final data = jsonDecode(response.body);
        final token = data['accessToken']?.toString();
        final expiresIn = int.tryParse(data['expiresIn']?.toString() ?? '900') ?? 900;
        _cachedB2bToken = token;
        _tokenExpiry = DateTime.now().add(Duration(seconds: expiresIn - 60));
        return token;
      } else {
        debugPrint('[DokuService] Respons error token B2B: ${response.body}');
        return null;
      }
    } catch (e) {
      debugPrint('[DokuService] Exception getB2BAccessToken: $e');
      return null;
    }
  }

  /// OPSI A: Membuat Tagihan Langsung Direct QRIS MPM Standar SNAP BI
  /// QRIS raw string langsung diperoleh dan digambar di aplikasi driver
  Future<DokuQrisResult?> createDirectSnapQris({
    required String driverId,
    required int amount,
    required String invoiceNumber,
  }) async {
    final token = await getB2BAccessToken();
    if (token == null || token.isEmpty) {
      debugPrint('[DokuService] Token B2B SNAP belum didapat. Beralih ke fallback...');
      return null;
    }

    try {
      final timestamp = _generateSnapTimestamp();
      final externalId = '${DateTime.now().millisecondsSinceEpoch}${Random().nextInt(9999)}';
      const endpoint = '/snap-adapter/b2b/v1.0/qr/qr-mpm-generate';

      final validityPeriod = DateTime.now().add(const Duration(minutes: 60));
      final validityOffset = '${validityPeriod.timeZoneOffset.isNegative ? '-' : '+'}${validityPeriod.timeZoneOffset.inHours.toString().padLeft(2, '0')}:${(validityPeriod.timeZoneOffset.inMinutes % 60).toString().padLeft(2, '0')}';
      final validityStr = '${validityPeriod.toIso8601String().split('.').first}$validityOffset';

      final payload = {
        'partnerReferenceNo': invoiceNumber,
        'amount': {
          'value': amount.toStringAsFixed(2),
          'currency': 'IDR',
        },
        'merchantId': clientId,
        'validityPeriod': validityStr,
        'additionalInfo': {
          'postalCode': '24111',
          'feeType': '1',
        },
      };

      final jsonBody = jsonEncode(payload);
      final signature = _generateSnapSignature(
        httpMethod: 'POST',
        endpointUrl: endpoint,
        accessToken: token,
        requestBody: jsonBody,
        timestamp: timestamp,
      );

      final url = Uri.parse('$baseUrl$endpoint');
      final response = await http.post(
        url,
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
          'X-PARTNER-ID': clientId,
          'X-EXTERNAL-ID': externalId,
          'X-TIMESTAMP': timestamp,
          'CHANNEL-ID': 'H2H',
          'X-SIGNATURE': signature,
        },
        body: jsonBody,
      ).timeout(const Duration(seconds: 15));

      debugPrint('[DokuService] Direct QRIS MPM response (${response.statusCode}): ${response.body}');
      final data = jsonDecode(response.body);

      if (response.statusCode == 200 || response.statusCode == 201) {
        final qrContent = data['qrContent']?.toString();
        if (qrContent != null && qrContent.isNotEmpty) {
          final qrImageUrl = 'https://api.qrserver.com/v1/create-qr-code/?size=300x300&data=${Uri.encodeComponent(qrContent)}';
          return DokuQrisResult(
            isSuccess: true,
            orderId: invoiceNumber,
            grossAmount: amount,
            qrString: qrContent,
            qrImageUrl: qrImageUrl,
            transactionStatus: 'pending',
            isDirectSnap: true,
          );
        }
      }
    } catch (e) {
      debugPrint('[DokuService] Exception createDirectSnapQris: $e');
    }
    return null;
  }

  /// Membuat signature HMAC-SHA256 untuk DOKU Checkout API
  String _generateCheckoutSignature({
    required String clientId,
    required String requestId,
    required String timestamp,
    required String requestTarget,
    String? digest,
  }) {
    final buffer = StringBuffer();
    buffer.write('Client-Id:$clientId\n');
    buffer.write('Request-Id:$requestId\n');
    buffer.write('Request-Timestamp:$timestamp\n');
    buffer.write('Request-Target:$requestTarget');
    if (digest != null && digest.isNotEmpty) {
      buffer.write('\nDigest:$digest');
    }

    final stringToSign = buffer.toString();
    final hmac = Hmac(sha256, utf8.encode(secretKey));
    final signatureBytes = hmac.convert(utf8.encode(stringToSign)).bytes;
    return 'HMACSHA256=${base64Encode(signatureBytes)}';
  }

  /// Menghitung Digest Base64(SHA256(jsonBody))
  String _generateDigest(String jsonBody) {
    final bodyBytes = utf8.encode(jsonBody);
    final digestBytes = sha256.convert(bodyBytes).bytes;
    return base64Encode(digestBytes);
  }

  /// MEMBUAT TRANSAKSI QRIS DOKU
  /// Mencoba Direct SNAP QRIS terlebih dahulu agar gambar QRIS langsung tampil di modal.
  /// Jika SNAP belum diverifikasi di DOKU, otomatis fallback ke DOKU Checkout QRIS.
  Future<DokuQrisResult> createQrisCharge({
    required String driverId,
    required int amount,
    String driverName = 'Mitra RBT Driver',
    String driverPhone = '',
  }) async {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final shortDriverId = driverId.length > 8 ? driverId.substring(0, 8) : driverId;
    final invoiceNumber = 'TOPUP-RBT-$shortDriverId-$timestamp';

    // 1. Prioritaskan OPSI A: Direct SNAP QRIS
    debugPrint('[DokuService] Memulai pembuatan Direct QRIS SNAP...');
    final snapResult = await createDirectSnapQris(
      driverId: driverId,
      amount: amount,
      invoiceNumber: invoiceNumber,
    );

    if (snapResult != null && snapResult.isSuccess) {
      debugPrint('[DokuService] Berhasil mendapatkan QRIS Langsung via SNAP BI!');
      return snapResult;
    }

    // 2. OPSI B: DOKU Hosted Checkout khusus QRIS
    debugPrint('[DokuService] Menjalankan DOKU Checkout QRIS...');
    final requestId = 'REQ-$timestamp-${Random().nextInt(999999)}';
    final utcTimestamp = _generateUtcTimestamp();
    const requestTarget = '/checkout/v1/payment';

    try {
      final payload = {
        'order': {
          'amount': amount,
          'invoice_number': invoiceNumber,
          'currency': 'IDR',
          'callback_url': 'https://rbt.web.id/finish',
          'auto_redirect': true,
        },
        'payment': {
          'payment_due_date': 60,
          'payment_method_types': ['QRIS'], // HANYA QRIS DOKU!
        },
        'customer': {
          'id': driverId.isNotEmpty ? driverId : 'DRIVER-$shortDriverId',
          'name': driverName.isNotEmpty ? driverName : 'Mitra RBT Driver',
          if (driverPhone.isNotEmpty) 'phone': driverPhone,
        },
      };

      final jsonBody = jsonEncode(payload);
      final digest = _generateDigest(jsonBody);
      final signature = _generateCheckoutSignature(
        clientId: clientId,
        requestId: requestId,
        timestamp: utcTimestamp,
        requestTarget: requestTarget,
        digest: digest,
      );

      final url = Uri.parse('$baseUrl$requestTarget');
      final headers = {
        'Client-Id': clientId,
        'Request-Id': requestId,
        'Request-Timestamp': utcTimestamp,
        'Digest': digest,
        'Signature': signature,
        'Content-Type': 'application/json',
      };

      final response = await http.post(
        url,
        headers: headers,
        body: jsonBody,
      ).timeout(const Duration(seconds: 15));

      debugPrint('[DokuService] Response DOKU Checkout (${response.statusCode}): ${response.body}');
      final data = jsonDecode(response.body);

      if (response.statusCode == 200 || response.statusCode == 201) {
        final paymentObj = data['payment'] as Map<String, dynamic>?;
        final paymentUrl = paymentObj?['url']?.toString();
        final expiredDate = paymentObj?['expired_date']?.toString();

        final qrImageUrl = paymentUrl != null && paymentUrl.isNotEmpty
            ? 'https://api.qrserver.com/v1/create-qr-code/?size=300x300&data=${Uri.encodeComponent(paymentUrl)}'
            : null;

        return DokuQrisResult(
          isSuccess: true,
          orderId: invoiceNumber,
          grossAmount: amount,
          paymentUrl: paymentUrl,
          qrImageUrl: qrImageUrl,
          qrString: paymentUrl,
          transactionStatus: 'pending',
          expiredDate: expiredDate,
          errorMessage: null,
        );
      } else {
        final errorMsg = data['message'] ?? data['status_message'] ?? 'Gagal membuat QRIS DOKU (HTTP ${response.statusCode})';
        return DokuQrisResult(
          isSuccess: false,
          orderId: invoiceNumber,
          grossAmount: amount,
          errorMessage: errorMsg.toString(),
        );
      }
    } catch (e) {
      debugPrint('[DokuService] Exception saat membuat QRIS DOKU: $e');
      return DokuQrisResult(
        isSuccess: false,
        orderId: invoiceNumber,
        grossAmount: amount,
        errorMessage: 'Gagal terhubung ke server DOKU: $e',
      );
    }
  }

  /// Memeriksa status transaksi QRIS ke DOKU API
  /// Mengembalikan status: 'settlement' (Berhasil Bayar), 'pending', 'expire', 'failed'
  Future<String> checkTransactionStatus(String invoiceNumber) async {
    // 1. Coba periksa via Query SNAP QRIS jika token aktif
    if (_cachedB2bToken != null) {
      try {
        final timestamp = _generateSnapTimestamp();
        final externalId = '${DateTime.now().millisecondsSinceEpoch}${Random().nextInt(9999)}';
        const endpoint = '/snap-adapter/b2b/v1.0/qr/qr-mpm-query';

        final payload = {
          'originalPartnerReferenceNo': invoiceNumber,
          'serviceCode': '51',
        };
        final jsonBody = jsonEncode(payload);
        final signature = _generateSnapSignature(
          httpMethod: 'POST',
          endpointUrl: endpoint,
          accessToken: _cachedB2bToken!,
          requestBody: jsonBody,
          timestamp: timestamp,
        );

        final url = Uri.parse('$baseUrl$endpoint');
        final response = await http.post(
          url,
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $_cachedB2bToken',
            'X-PARTNER-ID': clientId,
            'X-EXTERNAL-ID': externalId,
            'X-TIMESTAMP': timestamp,
            'CHANNEL-ID': 'H2H',
            'X-SIGNATURE': signature,
          },
          body: jsonBody,
        ).timeout(const Duration(seconds: 8));

        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          final latestStatus = data['latestTransactionStatus']?.toString();
          debugPrint('[DokuService] Status SNAP $invoiceNumber: $latestStatus');
          if (latestStatus == '00') {
            return 'settlement';
          }
        }
      } catch (_) {}
    }

    // 2. Periksa via Order Status API
    try {
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final requestId = 'STATUS-$timestamp-${Random().nextInt(999999)}';
      final utcTimestamp = _generateUtcTimestamp();
      final requestTarget = '/orders/v1/status/$invoiceNumber';

      final signature = _generateCheckoutSignature(
        clientId: clientId,
        requestId: requestId,
        timestamp: utcTimestamp,
        requestTarget: requestTarget,
      );

      final url = Uri.parse('$baseUrl$requestTarget');
      final headers = {
        'Client-Id': clientId,
        'Request-Id': requestId,
        'Request-Timestamp': utcTimestamp,
        'Signature': signature,
        'Content-Type': 'application/json',
      };

      final response = await http.get(
        url,
        headers: headers,
      ).timeout(const Duration(seconds: 8));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final txStatus = data['transaction']?['status']?.toString().toUpperCase();
        final orderStatus = data['order']?['status']?.toString().toUpperCase();

        if (txStatus == 'SUCCESS' || orderStatus == 'COMPLETED' || orderStatus == 'PAID') {
          return 'settlement';
        } else if (txStatus == 'FAILED' || orderStatus == 'FAILED' || orderStatus == 'EXPIRED') {
          return 'expire';
        }
      }
    } catch (e) {
      debugPrint('[DokuService] Gagal periksa status DOKU: $e');
    }
    return 'pending';
  }
}

/// Kunci Privat Merchant RSA 2048-bit (Format PKCS#1) yang dibuat khusus untuk akun BRN-0230-1793112691734
const String _defaultMerchantPrivateKey = '''
-----BEGIN RSA PRIVATE KEY-----
MIIEpQIBAAKCAQEAx4T0sRBXPiTFZF46Yud3649pz8kZIm/x4YvY47OZCPhD1c8n
Gi6VVdBbz5A2jgpBxGgDnCzvTj61HrNJ0sk707Ho1YzRIz1sbMA+Y2tW708N0oTT
ZqRJwFHMYWcTN08BQ3A1/aEhR5RYkxaRr06ahE+aFD5QSGQyJHtVY0hGpyiFzfap
a9vGnQcc+OdQZ4TO5Z7ZYmrVuhRaHfsg7DTpzOtRmLkqPbqKuFBeW5i2oBfAIqxU
jjGT2rzsTzzR5QGtFI8msxVYhzQpRgZrhH4wMlL1/aIjrCtCnEe8Ti/zbHrKOnk4
GE72jP4Fwy62iP8NEG0KubR8300sLzyjnsSVFwIDAQABAoIBAQCq66RvVy9V5kxP
ekWMWvypiLc9sOneTYYqERKhpkawn3YFYSv/Su7Vj+RHASUrM3A54F1PWlM7dY7V
mQPiFlAxP1TWNIcpKEKNO3d21gqogdG2ieFMKeugXLK4soOMuxq6+hLWj0WiO1xR
zWDKjIzkUgkN1IAUM/mctSdmIRGduhwKIdDDWqqDkGWdsqVUtLVRCYPb3gUi9c06
fChup3C/sR31MQqAxgr3ri2fudv+OzCIpjCcO4WRZGRbWkKHTE7mMl7kzpNSK9d9
gPkpq2O31PNnFRK2DHuw46VpIImnk6+/g7KtplqOM7BaawEXDMROa/ilO85l4QFN
jDg7fWHBAoGBAP/ai2es9Z94g9N4qtz0jXTPBXQ05zY/ZLwPB0esvF5OKe5spoc3
xx2+XGLgCsfiHMBRRIZY2N/Vgk1Bnto+S2B1qqC+9obrVOZ84Qf/09wJPIYQqkDC
BkRE47/2jM0WZfbW7Z1rgGy/v7tDc+SaKj2OjXC6aVwrSuX2G+oHyBlhAoGBAMei
Kg1oYAqGPRH2WgMNqCAjnj9PxI8QaVBUvP/VbK7dYp97p5xmEr5UKcXS0mrSk4Ca
9Cw4WKK+aUFforp01CySe/i2pKqHMoKqr0A0TkT9NK5irCPi7hcgbOYSyOfgNG2Z
kCUV8QzknHGHvDCy3cAtLJax7PAdkz9NrlNVWGl3AoGBAIQ9H8pxMe6/qlsVxjI3
0BksmyQJ5+s47sboeZnJJP8VJUUPMS84XBj6d+O+6rOPIc8g8esCZu2h/BwUK5ef
lPQBPTSiHudzIMmUh/bLemQC/h5I5MZdwkFs3c4tD289AWyIf/3aP2F15hJS9caV
C/oPAPnfz28NDUQ4ZQscBIdhAoGACbIflr0eBQTWDHxJjOJp6v2v3uVR55zlcIhd
EZPdDnUkKBjKYDc469OMn9YIcDXAAjwEZe1qqKTU2d76OVIZR/zpVoAQaVPdqSj/
EAA6WPFvUJTsRWXtKGRjxZzd8x0ZjsUpkhOJvJWR35W3FypoyL+o7bzAhDz7fNSa
BeQcQisCgYEAgZgQhA2CkjEaG6ACEr0opNWNymtrX432Ixcx758yEvUajnR0Hf2B
RsHLNJJerFMW9t5A8Z5Kx4WLLQxD+ghfNr7nAWj/XQLBjyvZ6aMURX7vYmGduD85
uLAE634l9zTHSWbbfn03AbdHZR5Xuctq/RCqL/1qA6epNKOTVMJqb+s=
-----END RSA PRIVATE KEY-----
''';
