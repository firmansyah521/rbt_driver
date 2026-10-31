import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import '../constants/driver_theme.dart';
import '../services/driver_service.dart';
import '../services/midtrans_service.dart';

/// Modal Dialog Top Up Saldo Deposit Driver via QRIS Midtrans
/// Dilengkapi pengecekan otomatis (auto-polling) status pelunasan real-time
/// serta penanganan kondisi gagal memuat QRIS dengan opsi Coba Lagi.
class DriverQrisDialog extends StatefulWidget {
  final int? initialAmount;
  final VoidCallback? onSuccessRedirect;

  const DriverQrisDialog({
    super.key,
    this.initialAmount,
    this.onSuccessRedirect,
  });

  static Future<bool?> show(
    BuildContext context, {
    int? initialAmount,
    VoidCallback? onSuccessRedirect,
  }) {
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => DriverQrisDialog(
        initialAmount: initialAmount,
        onSuccessRedirect: onSuccessRedirect,
      ),
    );
  }

  @override
  State<DriverQrisDialog> createState() => _DriverQrisDialogState();
}

class _DriverQrisDialogState extends State<DriverQrisDialog> {
  // Pilihan nominal cepat
  final List<int> _presetAmounts = [10000, 20000, 50000, 100000, 200000];

  int _selectedAmount = 20000;
  final TextEditingController _customAmountController = TextEditingController();

  // Status proses
  bool _isLoadingQris = false;
  bool _isSuccess = false;
  String? _loadErrorMessage;
  MidtransQrisResult? _qrisResult;

  // Timer auto check & countdown
  Timer? _pollingTimer;
  Timer? _countdownTimer;
  int _secondsRemaining = 900; // 15 menit

  final currencyFormat = NumberFormat.currency(
    locale: 'id_ID',
    symbol: 'Rp ',
    decimalDigits: 0,
  );

  @override
  void initState() {
    super.initState();
    if (widget.initialAmount != null && widget.initialAmount! > 0) {
      _selectedAmount = widget.initialAmount!;
      _customAmountController.text = widget.initialAmount.toString();
    }
  }

  @override
  void dispose() {
    _pollingTimer?.cancel();
    _countdownTimer?.cancel();
    _customAmountController.dispose();
    super.dispose();
  }

  String get _formattedCountdown {
    final m = (_secondsRemaining ~/ 60).toString().padLeft(2, '0');
    final s = (_secondsRemaining % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  /// Memulai pembuatan tagihan QRIS ke Midtrans
  Future<void> _generateQris() async {
    final amount = int.tryParse(_customAmountController.text.replaceAll(RegExp(r'[^0-9]'), '')) ?? _selectedAmount;
    if (amount < 5000) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          backgroundColor: DriverTheme.offlineRed,
          content: Text('Minimal nominal top up deposit adalah Rp 5.000'),
        ),
      );
      return;
    }
    if (amount > 5000000) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          backgroundColor: DriverTheme.offlineRed,
          content: Text('Maksimal nominal top up deposit adalah Rp 5.000.000 per transaksi.'),
        ),
      );
      return;
    }

    final profile = DriverService.instance.profile;
    if (!DriverService.instance.isLoggedIn || profile.id.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          backgroundColor: DriverTheme.offlineRed,
          content: Text('Sesi akun driver tidak aktif. Silakan masuk kembali.'),
        ),
      );
      return;
    }

    setState(() {
      _isLoadingQris = true;
      _loadErrorMessage = null;
      _selectedAmount = amount;
    });

    final res = await MidtransService.instance.createQrisCharge(
      driverId: profile.id,
      amount: amount,
      driverName: profile.name,
      driverPhone: profile.phone,
    );

    if (!mounted) return;

    setState(() {
      _isLoadingQris = false;
      if (res.isSuccess) {
        _qrisResult = res;
        _loadErrorMessage = null;
      } else {
        _qrisResult = null;
        _loadErrorMessage = res.errorMessage ?? 'Gagal membuat tagihan QRIS Midtrans.';
      }
    });

    if (res.isSuccess) {
      _startAutoCheckPolling(res.orderId, amount);
      _startCountdown();
    }
  }

  /// Menjalankan hitung mundur kedaluwarsa QRIS (15 menit)
  void _startCountdown() {
    _secondsRemaining = 900;
    _countdownTimer?.cancel();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      if (_secondsRemaining > 0) {
        setState(() => _secondsRemaining--);
      } else {
        t.cancel();
        _pollingTimer?.cancel();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            backgroundColor: DriverTheme.offlineRed,
            content: Text('Kode QRIS telah kedaluwarsa. Silakan buat QRIS baru.'),
          ),
        );
      }
    });
  }

  /// AUTO CHECK POLLING: Otomatis memeriksa status Midtrans setiap 3.5 detik
  void _startAutoCheckPolling(String orderId, int amount) {
    _pollingTimer?.cancel();

    _pollingTimer = Timer.periodic(const Duration(milliseconds: 3500), (timer) async {
      if (!mounted || _isSuccess) {
        timer.cancel();
        return;
      }

      final status = await MidtransService.instance.checkTransactionStatus(orderId);

      // Jika Midtrans mengembalikan settlement / capture / success (Lunas)
      if (status == 'settlement' || status == 'capture' || status == 'success') {
        timer.cancel();
        await _handlePaymentSuccess(orderId, amount);
      }
    });
  }

  /// Eksekusi saat pembayaran lunas terverifikasi
  Future<void> _handlePaymentSuccess(String orderId, int amount) async {
    if (_isSuccess) return;
    setState(() => _isSuccess = true);

    _pollingTimer?.cancel();
    _countdownTimer?.cancel();

    // 1. Tambahkan saldo ke Supabase Database dengan metode qris_midtrans
    await DriverService.instance.topUpDeposit(
      amount: amount,
      referenceId: orderId,
      paymentMethod: 'qris_midtrans',
    );

    HapticFeedback.heavyImpact();

    if (!mounted) return;

    // Tunggu sejenak agar driver melihat centang hijau sukses
    await Future.delayed(const Duration(milliseconds: 1400));
    if (!mounted) return;

    // Tutup modal dan arahkan langsung ke halaman radar pesanan
    Navigator.of(context).pop(true);

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: DriverTheme.onlineGreen,
        behavior: SnackBarBehavior.floating,
        content: Row(
          children: [
            const Icon(Icons.check_circle, color: Colors.white),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Top Up ${currencyFormat.format(amount)} Berhasil! Saldo deposit Anda siap digunakan.',
                style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
              ),
            ),
          ],
        ),
      ),
    );

    widget.onSuccessRedirect?.call();
  }

  @override
  Widget build(BuildContext context) {
    final profile = DriverService.instance.profile;

    return Dialog(
      backgroundColor: DriverTheme.surfaceDark,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: const BorderSide(color: DriverTheme.cardBorder, width: 1.2),
      ),
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: _isSuccess
              ? _buildSuccessView()
              : _loadErrorMessage != null
                  ? _buildErrorView()
                  : _qrisResult == null
                      ? _buildSelectAmountView(profile.depositBalance)
                      : _buildQrisDisplayView(),
        ),
      ),
    );
  }

  /// TAMPILAN 1: PILIH NOMINAL TOP UP DEPOSIT
  Widget _buildSelectAmountView(int currentBalance) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Header
        Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: DriverTheme.uberPillBg,
                shape: BoxShape.circle,
                border: Border.all(color: DriverTheme.cardBorder),
              ),
              child: const Icon(Icons.account_balance_wallet_outlined, color: Colors.white, size: 22),
            ),
            const SizedBox(width: 12),
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Top Up Saldo Deposit',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
                  ),
                  Text(
                    'Saldo dompet operasional mitra driver via Midtrans QRIS',
                    style: TextStyle(fontSize: 11, color: DriverTheme.textMuted),
                  ),
                ],
              ),
            ),
            IconButton(
              icon: const Icon(Icons.close, color: Colors.white60, size: 20),
              onPressed: () => Navigator.pop(context, false),
            ),
          ],
        ),
        const SizedBox(height: 16),

        // Saldo Saat Ini
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: DriverTheme.uberPillBg,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: DriverTheme.cardBorder),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Saldo Deposit Saat Ini:',
                style: TextStyle(fontSize: 12, color: Colors.white70),
              ),
              Text(
                currencyFormat.format(currentBalance),
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                  color: currentBalance > 5000 ? DriverTheme.onlineGreen : DriverTheme.alertAmber,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),

        const Text(
          'Pilih Nominal Top Up:',
          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.white),
        ),
        const SizedBox(height: 10),

        // Chips Nominal Cepat
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: _presetAmounts.map((amt) {
            final isSelected = _selectedAmount == amt;
            return ChoiceChip(
              label: Text(
                currencyFormat.format(amt),
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                  color: isSelected ? Colors.white : Colors.white70,
                ),
              ),
              selected: isSelected,
              selectedColor: DriverTheme.primaryBenhur,
              backgroundColor: DriverTheme.uberPillBg,
              side: BorderSide(
                color: isSelected ? DriverTheme.primaryBenhurLight : DriverTheme.cardBorder,
              ),
              onSelected: (selected) {
                if (selected) {
                  setState(() {
                    _selectedAmount = amt;
                    _customAmountController.text = amt.toString();
                  });
                }
              },
            );
          }).toList(),
        ),
        const SizedBox(height: 14),

        // Input Manual
        TextField(
          controller: _customAmountController,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15),
          decoration: InputDecoration(
            labelText: 'Atau Masukkan Nominal Lain',
            labelStyle: const TextStyle(color: DriverTheme.textMuted, fontSize: 12),
            prefixText: 'Rp ',
            prefixStyle: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15),
            filled: true,
            fillColor: DriverTheme.uberPillBg,
            contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: DriverTheme.cardBorder),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: DriverTheme.cardBorder),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: Colors.white, width: 1.2),
            ),
          ),
          onChanged: (val) {
            final n = int.tryParse(val) ?? 0;
            setState(() => _selectedAmount = n);
          },
        ),
        const SizedBox(height: 14),

        // Info Aturan Admin Deposit Operasional
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: DriverTheme.uberPillBg,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: DriverTheme.cardBorder),
          ),
          child: const Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.verified_user_outlined, color: DriverTheme.brightCyan, size: 16),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Saldo ini digunakan sebagai deposit operasional akun Anda setiap kali menerima dan menyelesaikan orderan via QRIS Midtrans.',
                  style: TextStyle(fontSize: 11, color: DriverTheme.textSecondary, height: 1.3),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),

        // Tombol Buat Tagihan QRIS Midtrans
        SizedBox(
          height: 48,
          child: ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF002B49), // Midtrans Deep Navy
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
                side: const BorderSide(color: Color(0xFF0070BA), width: 1.2), // Midtrans Accent Blue
              ),
              elevation: 0,
            ),
            onPressed: _isLoadingQris ? null : _generateQris,
            child: _isLoadingQris
                ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                  )
                : const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.qr_code_2_rounded, size: 20, color: Color(0xFF00D1FF)),
                      SizedBox(width: 8),
                      Text(
                        'Bayar dengan QRIS Midtrans',
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                      ),
                    ],
                  ),
          ),
        ),
      ],
    );
  }

  /// TAMPILAN 2: DISPLAY QRIS MIDTRANS DENGAN AUTO-CHECKING STATUS
  Widget _buildQrisDisplayView() {
    final res = _qrisResult!;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        // Header QRIS
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Scan QRIS Midtrans',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
                ),
                Text(
                  'Invoice #${res.orderId}',
                  style: const TextStyle(fontSize: 10, color: DriverTheme.textMuted),
                ),
              ],
            ),
            IconButton(
              icon: const Icon(Icons.close, color: Colors.white60),
              onPressed: () {
                _pollingTimer?.cancel();
                _countdownTimer?.cancel();
                Navigator.pop(context, false);
              },
            ),
          ],
        ),
        const SizedBox(height: 12),

        // Box Total Nominal
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
          decoration: BoxDecoration(
            color: DriverTheme.uberPillBg,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: DriverTheme.cardBorder),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Total Pembayaran:', style: TextStyle(color: Colors.white70, fontSize: 12)),
              Text(
                currencyFormat.format(res.grossAmount),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),

        // Frame QRIS
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.3),
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Column(
            children: [
              // Logo QRIS Nasional + Midtrans
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                    decoration: BoxDecoration(
                      color: const Color(0xFFED1C24),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: const Text(
                      'QRIS',
                      style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 13, letterSpacing: 1),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: const Color(0xFF002B49),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: const Text(
                      'midtrans',
                      style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 11),
                    ),
                  ),
                  const SizedBox(width: 8),
                  const Text(
                    'QRIS Universal GPN',
                    style: TextStyle(color: Colors.black87, fontSize: 11, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              const SizedBox(height: 12),

              // Gambar QR Code Midtrans
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: res.qrImageUrl != null
                    ? Image.network(
                        res.qrImageUrl!,
                        width: 220,
                        height: 220,
                        fit: BoxFit.contain,
                        loadingBuilder: (ctx, child, progress) {
                          if (progress == null) return child;
                          return const SizedBox(
                            width: 220,
                            height: 220,
                            child: Center(
                              child: CircularProgressIndicator(color: Color(0xFF0070BA)),
                            ),
                          );
                        },
                        errorBuilder: (ctx, err, stack) {
                          return Container(
                            width: 220,
                            height: 220,
                            color: Colors.grey.shade100,
                            child: const Center(
                              child: Text(
                                'QR Code siap di tautan checkout',
                                style: TextStyle(color: Colors.black54, fontSize: 11),
                                textAlign: TextAlign.center,
                              ),
                            ),
                          );
                        },
                      )
                    : const SizedBox(
                        width: 220,
                        height: 220,
                        child: Center(child: Text('QR Code dimuat via Checkout Link')),
                      ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Midtrans Official Payment Gateway • RBT Driver',
                style: TextStyle(color: Colors.black54, fontSize: 9, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.blue.shade50,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Text(
                  'Bisa di-scan / dibayar via BCA, Mandiri, BRI, BNI, BSI, DANA, OVO, ShopeePay & GoPay',
                  style: TextStyle(color: Color(0xFF005596), fontSize: 9.5, fontWeight: FontWeight.bold),
                  textAlign: TextAlign.center,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),

        // Tombol Utama Buka Halaman Checkout Midtrans (Semua Bank & E-Wallet)
        if (res.paymentUrl != null && res.paymentUrl!.isNotEmpty) ...[
          SizedBox(
            width: double.infinity,
            height: 48,
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF0070BA), // Midtrans Interactive Blue
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                elevation: 2,
              ),
              icon: const Icon(Icons.qr_code_scanner_rounded, size: 20, color: Colors.white),
              label: const Text(
                'Buka QRIS & Bayar via Semua Bank',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13.5),
              ),
              onPressed: () async {
                final uri = Uri.parse(res.paymentUrl!);
                if (await canLaunchUrl(uri)) {
                  await launchUrl(uri, mode: LaunchMode.externalApplication);
                }
              },
            ),
          ),
          const SizedBox(height: 10),
        ],

        // Status Polling Real-time
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: DriverTheme.onlineGreen.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: DriverTheme.onlineGreen.withValues(alpha: 0.4)),
          ),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(
                  color: DriverTheme.onlineGreen,
                  strokeWidth: 2,
                ),
              ),
              SizedBox(width: 8),
              Text(
                'Menunggu pembayaran... Terverifikasi Otomatis',
                style: TextStyle(color: DriverTheme.onlineGreen, fontSize: 11, fontWeight: FontWeight.bold),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),

        // Timer Hitung Mundur
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.timer_outlined, color: Colors.white70, size: 14),
            const SizedBox(width: 4),
            Text(
              'Kedaluwarsa dalam $_formattedCountdown',
              style: const TextStyle(color: Colors.white70, fontSize: 11),
            ),
          ],
        ),
        const SizedBox(height: 12),

        // Instruksi pembayaran
        const Text(
          'Dapat di-scan memakai Mobile Banking (BCA, Mandiri, BRI, BSI) & E-Wallet (GoPay, OVO, DANA, ShopeePay)',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 10, color: DriverTheme.textMuted),
        ),
        const SizedBox(height: 10),

        // Tombol simulasi bayar (berguna untuk testing bila server belum aktif)
        if (res.isSimulated || MidtransService.instance.serverKey.isEmpty)
          TextButton.icon(
            style: TextButton.styleFrom(
              foregroundColor: Colors.white70,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            ),
            icon: const Icon(Icons.flash_on, size: 16),
            label: const Text(
              'Simulasi Pembayaran Berhasil (Uji Coba)',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
            ),
            onPressed: () => _handlePaymentSuccess(res.orderId, res.grossAmount),
          ),
      ],
    );
  }

  /// TAMPILAN 3: KONDISI GAGAL MEMUAT QRIS DENGAN OPSI COBA LAGI
  Widget _buildErrorView() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            IconButton(
              icon: const Icon(Icons.close, color: Colors.white60, size: 20),
              onPressed: () => Navigator.pop(context, false),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Container(
          width: 64,
          height: 64,
          decoration: BoxDecoration(
            color: DriverTheme.offlineRed.withValues(alpha: 0.15),
            shape: BoxShape.circle,
            border: Border.all(color: DriverTheme.offlineRed.withValues(alpha: 0.6), width: 1.5),
          ),
          child: const Icon(Icons.error_outline_rounded, color: DriverTheme.offlineRed, size: 36),
        ),
        const SizedBox(height: 16),
        const Text(
          'Gagal Memuat QRIS Midtrans',
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: DriverTheme.uberPillBg,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: DriverTheme.cardBorder),
          ),
          child: Text(
            _loadErrorMessage ?? 'Terjadi kendala saat menghubungkan ke server gateway Midtrans.',
            style: const TextStyle(fontSize: 12, color: Colors.white70, height: 1.4),
            textAlign: TextAlign.center,
          ),
        ),
        const SizedBox(height: 20),
        // Tombol Coba Lagi
        SizedBox(
          width: double.infinity,
          height: 46,
          child: ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: DriverTheme.primaryBenhur,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              elevation: 0,
            ),
            icon: const Icon(Icons.refresh_rounded, size: 20),
            label: const Text(
              'Coba Lagi',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
            ),
            onPressed: _isLoadingQris ? null : _generateQris,
          ),
        ),
        const SizedBox(height: 10),
        // Tombol Ganti Nominal / Kembali
        SizedBox(
          width: double.infinity,
          height: 42,
          child: TextButton(
            style: TextButton.styleFrom(
              foregroundColor: Colors.white70,
            ),
            child: const Text('Kembali & Pilih Nominal Lain'),
            onPressed: () {
              setState(() {
                _loadErrorMessage = null;
                _qrisResult = null;
              });
            },
          ),
        ),
      ],
    );
  }

  /// TAMPILAN 4: STATUS SUKSES DENGAN ANIMASI CENTANG
  Widget _buildSuccessView() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        const SizedBox(height: 20),
        Container(
          width: 72,
          height: 72,
          decoration: const BoxDecoration(
            color: DriverTheme.onlineGreen,
            shape: BoxShape.circle,
          ),
          child: const Icon(Icons.check, color: Colors.white, size: 44),
        ),
        const SizedBox(height: 20),
        const Text(
          'PEMBAYARAN QRIS MIDTRANS BERHASIL!',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.bold,
            color: Colors.white,
            letterSpacing: 0.5,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Saldo deposit bertambah sebesar ${currencyFormat.format(_selectedAmount)}',
          style: const TextStyle(fontSize: 13, color: Colors.white70),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 6),
        const Text(
          'Membawa Anda kembali ke radar orderan...',
          style: TextStyle(fontSize: 11, color: Colors.white70),
        ),
        const SizedBox(height: 24),
      ],
    );
  }
}
