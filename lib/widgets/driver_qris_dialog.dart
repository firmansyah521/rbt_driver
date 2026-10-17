import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import '../constants/driver_theme.dart';
import '../services/driver_service.dart';
import '../services/midtrans_service.dart';

/// Modal Dialog Top Up Saldo Deposit Driver via QRIS Midtrans
/// Dilengkapi pengecekan otomatis (auto-polling) status pelunasan real-time.
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
  MidtransQrisResult? _qrisResult;

  // Timer auto check
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

  /// Memulai tagihan QRIS ke Midtrans
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
      _qrisResult = res;
    });

    if (res.isSuccess) {
      _startAutoCheckPolling(res.orderId, amount);
      _startCountdown();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: DriverTheme.offlineRed,
          content: Text(res.errorMessage ?? 'Gagal membuat tagihan QRIS Midtrans.'),
        ),
      );
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

  /// AUTO CHECK POLLING: Otomatis memeriksa status Midtrans setiap 4 detik
  void _startAutoCheckPolling(String orderId, int amount) {
    _pollingTimer?.cancel();

    _pollingTimer = Timer.periodic(const Duration(milliseconds: 4000), (timer) async {
      if (!mounted || _isSuccess) {
        timer.cancel();
        return;
      }

      final status = await MidtransService.instance.checkTransactionStatus(orderId);

      // Jika Midtrans mengembalikan settlement / capture (Lunas)
      if (status == 'settlement' || status == 'capture') {
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

    // 1. Tambahkan saldo ke Supabase Database
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
                color: DriverTheme.brightCyan.withValues(alpha: 0.15),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.account_balance_wallet_rounded, color: DriverTheme.brightCyan, size: 24),
            ),
            const SizedBox(width: 12),
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Top Up Saldo Deposit',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: Colors.white),
                  ),
                  Text(
                    'Saldo kas untuk potongan admin 5% orderan',
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
            color: DriverTheme.darkBg,
            borderRadius: BorderRadius.circular(12),
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
        const SizedBox(height: 18),

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
                  color: isSelected ? Colors.black : Colors.white70,
                ),
              ),
              selected: isSelected,
              selectedColor: DriverTheme.brightCyan,
              backgroundColor: DriverTheme.darkBg,
              side: BorderSide(
                color: isSelected ? DriverTheme.brightCyan : DriverTheme.cardBorder,
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
          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
          decoration: InputDecoration(
            labelText: 'Atau Masukkan Nominal Lain',
            labelStyle: const TextStyle(color: DriverTheme.textMuted, fontSize: 12),
            prefixText: 'Rp ',
            prefixStyle: const TextStyle(color: DriverTheme.brightCyan, fontWeight: FontWeight.bold, fontSize: 16),
            filled: true,
            fillColor: DriverTheme.darkBg,
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
              borderSide: const BorderSide(color: DriverTheme.brightCyan, width: 1.5),
            ),
          ),
          onChanged: (val) {
            final n = int.tryParse(val) ?? 0;
            setState(() => _selectedAmount = n);
          },
        ),
        const SizedBox(height: 14),

        // Info Aturan Admin 5%
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: DriverTheme.electricBlue.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: DriverTheme.electricBlue.withValues(alpha: 0.3)),
          ),
          child: const Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.info_outline, color: DriverTheme.brightCyan, size: 16),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Saldo ini dipotong 5% dari nilai ongkos kirim setiap kali Anda berhasil mengambil orderan pelanggan.',
                  style: TextStyle(fontSize: 11, color: Colors.white70, height: 1.3),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),

        // Tombol Buat Tagihan QRIS
        ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: DriverTheme.electricBlue,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 14),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            elevation: 4,
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
                    Icon(Icons.qr_code_2_rounded, size: 22),
                    SizedBox(width: 8),
                    Text(
                      'Bayar dengan QRIS Midtrans',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                    ),
                  ],
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
                  'Scan QRIS Pembayaran',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
                ),
                Text(
                  'Order #${res.orderId}',
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
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
          decoration: BoxDecoration(
            color: DriverTheme.darkBg,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: DriverTheme.cardBorder),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Total Pembayaran:', style: TextStyle(color: Colors.white70, fontSize: 12)),
              Text(
                currencyFormat.format(res.grossAmount),
                style: const TextStyle(
                  color: DriverTheme.brightCyan,
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
            borderRadius: BorderRadius.circular(16),
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
              // Logo QRIS Nasional
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
                  const Text(
                    'Pembayaran Nasional',
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
                              child: CircularProgressIndicator(color: DriverTheme.electricBlue),
                            ),
                          );
                        },
                        errorBuilder: (ctx, err, stack) {
                          return Container(
                            width: 220,
                            height: 220,
                            color: Colors.grey.shade200,
                            child: const Center(
                              child: Text('Gagal memuat gambar QRIS', style: TextStyle(color: Colors.red, fontSize: 12)),
                            ),
                          );
                        },
                      )
                    : const SizedBox(
                        width: 220,
                        height: 220,
                        child: Center(child: Text('QR Code tidak tersedia')),
                      ),
              ),
              const SizedBox(height: 8),
              const Text(
                'NMID: ID1020000000000 • RBT Pidie',
                style: TextStyle(color: Colors.black54, fontSize: 9),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),

        // Status Polling Real-time
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: DriverTheme.onlineGreen.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: DriverTheme.onlineGreen.withValues(alpha: 0.4)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(
                  color: DriverTheme.onlineGreen,
                  strokeWidth: 2,
                ),
              ),
              const SizedBox(width: 8),
              const Text(
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
        const SizedBox(height: 14),

        // Tombol simulasi bayar (berguna untuk testing jika server key belum aktif)
        if (res.isSimulated || MidtransService.instance.serverKey.contains('DEMO_TESTING_KEY'))
          TextButton.icon(
            style: TextButton.styleFrom(
              foregroundColor: DriverTheme.brightCyan,
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

  /// TAMPILAN 3: STATUS SUKSES DENGAN ANIMASI CENTANG
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
          'PEMBAYARAN QRIS BERHASIL!',
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
          style: TextStyle(fontSize: 11, color: DriverTheme.brightCyan),
        ),
        const SizedBox(height: 24),
      ],
    );
  }
}
