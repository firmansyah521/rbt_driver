import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:geolocator/geolocator.dart';
import '../constants/driver_theme.dart';
import '../models/driver_order_model.dart';
import '../services/driver_foreground_service.dart';
import '../services/driver_permission_service.dart';
import '../services/driver_notification_service.dart';
import '../services/driver_service.dart';
import '../widgets/driver_offline_banner.dart';
import '../widgets/driver_qris_dialog.dart';
import 'driver_active_job_screen.dart';
import 'driver_auth_screen.dart';
import 'package:intl/intl.dart';

/// Layar Radar Pesanan Masuk (Beranda Utama Driver)
/// Menggabungkan Realtime Stream Supabase + REST Polling Fallback + Pull-to-Refresh
/// Menjamin pesanan berstatus 'searching' langsung muncul dan dapat diambil secara instan
class DriverRadarScreen extends StatefulWidget {
  final VoidCallback? onOpenHistory;
  final VoidCallback? onOpenProfile;

  const DriverRadarScreen({
    super.key,
    this.onOpenHistory,
    this.onOpenProfile,
  });

  @override
  State<DriverRadarScreen> createState() => _DriverRadarScreenState();
}

class _DriverRadarScreenState extends State<DriverRadarScreen> {
  bool _isClaiming = false;
  Map<String, dynamic> _todaySummary = {'count': 0, 'earnings': 0, 'distanceKm': 0.0};

  final Set<String> _knownOrderCodes = {};
  bool _isInitialOrderFetch = true;

  List<DriverOrderModel> _manualOrders = [];
  bool _isLoadingManual = false;
  Timer? _pollingTimer;

  // Posisi GPS driver aktual untuk mengurutkan pesanan terdekat ke terjauh
  Position? _driverPosition;
  StreamSubscription<Position>? _positionStreamSub;
  Timer? _standbyGpsTimer;
  Position? _lastBroadcastPosition;
  DateTime? _lastBroadcastTime;

  // Pelacakan pesanan aktif yang sedang dikerjakan driver ini
  DriverOrderModel? _currentActiveJob;
  StreamSubscription<DriverOrderModel?>? _activeJobSub;

  @override
  void initState() {
    super.initState();
    _loadTodaySummary();
    _fetchManualOrders();
    _initDriverLocation();

    // Inisialisasi callback saat notifikasi di panel smartphone diklik
    DriverNotificationService.instance.initialize(
      onSelectNotification: (orderCode) {
        if (mounted) {
          _fetchManualOrders();
        }
      },
    );

    // Pantau pesanan aktif secara realtime untuk aturan 1 order
    _activeJobSub = DriverService.instance.streamActiveJob().listen((job) {
      if (mounted) {
        setState(() => _currentActiveJob = job);
      }
    });

    // Periksa apakah ada izin penting (GPS & Notifikasi) yang belum diizinkan
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final missing = await DriverPermissionService.instance.hasMissingDriverPermissions();
      if (missing && mounted) {
        await DriverPermissionService.instance.showDriverPermissionDialog(context);
        _initDriverLocation();
      }
    });

    // Timer polling setiap 25 detik sebagai jaminan dual-sync jika realtime terputus (hemat kuota & query Supabase)
    _pollingTimer = Timer.periodic(const Duration(seconds: 25), (_) {
      if (mounted &&
          DriverService.instance.profile.isOnline &&
          DriverService.instance.isLoggedIn &&
          _currentActiveJob == null) {
        _fetchManualOrders(silent: true);
      }
    });
  }

  /// Mengirim koordinat posisi terakhir driver ke tabel public.drivers Supabase saat standby di radar
  Future<void> _broadcastStandbyLocation({bool force = false}) async {
    if (!DriverService.instance.profile.isOnline || !DriverService.instance.isLoggedIn) return;

    final pos = _driverPosition;
    if (pos == null) return;

    // Jika tidak dipaksa (force), hanya kirim jika sudah 45 detik atau berpindah > 50 meter (hemat baterai & kuota)
    if (!force && _lastBroadcastPosition != null && _lastBroadcastTime != null) {
      final elapsedSec = DateTime.now().difference(_lastBroadcastTime!).inSeconds;
      final distanceMoved = Geolocator.distanceBetween(
        _lastBroadcastPosition!.latitude,
        _lastBroadcastPosition!.longitude,
        pos.latitude,
        pos.longitude,
      );

      if (elapsedSec < 45 && distanceMoved < 50) {
        return;
      }
    }

    try {
      await DriverService.instance.updateDriverLocation(pos.latitude, pos.longitude);
      _lastBroadcastPosition = pos;
      _lastBroadcastTime = DateTime.now();
      debugPrint('[Standby GPS Radar] Koordinat driver diperbarui di cloud: ${pos.latitude}, ${pos.longitude}');
    } catch (e) {
      debugPrint('[Standby GPS Radar] Gagal kirim koordinat driver: $e');
    }
  }

  /// Inisialisasi pelacakan sensor GPS driver secara realtime & broadcast berkala saat standby
  Future<void> _initDriverLocation() async {
    try {
      final isGranted = await DriverPermissionService.instance.isLocationGranted();
      if (!isGranted) {
        await DriverPermissionService.instance.requestLocationPermission();
      }

      // 1. Ambil lokasi terakhir (Last Known) terlebih dahulu untuk respons 0ms
      try {
        final last = await Geolocator.getLastKnownPosition();
        if (last != null && mounted) {
          setState(() => _driverPosition = last);
          _broadcastStandbyLocation(force: true);
        }
      } catch (_) {}

      // 2. Ambil lokasi GPS akurat saat ini
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 8),
        ),
      );
      if (mounted) {
        setState(() => _driverPosition = pos);
        _broadcastStandbyLocation(force: true);
      }

      // 3. Dengarkan perpindahan pergerakan driver (update setiap 25 meter)
      _positionStreamSub?.cancel();
      _positionStreamSub = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 25,
        ),
      ).listen((updatedPos) {
        if (mounted) {
          setState(() => _driverPosition = updatedPos);
          _broadcastStandbyLocation();
        }
      });

      // 4. Timer berkala 45 detik saat online standby untuk memastikan server selalu punya koordinat segar
      _standbyGpsTimer?.cancel();
      _standbyGpsTimer = Timer.periodic(const Duration(seconds: 45), (_) {
        if (mounted && DriverService.instance.profile.isOnline) {
          _broadcastStandbyLocation();
        }
      });
    } catch (e) {
      debugPrint('[DriverRadar] Catatan deteksi GPS driver: $e');
    }
  }

  /// Menghitung jarak dari lokasi driver saat ini ke titik jemput pesanan (dalam meter)
  double _getDistanceToPickupMeters(DriverOrderModel order) {
    final driverLat = _driverPosition?.latitude ?? 5.3850;
    final driverLng = _driverPosition?.longitude ?? 95.9600;
    return Geolocator.distanceBetween(driverLat, driverLng, order.pickupLat, order.pickupLng);
  }

  /// Format teks jarak ke titik jemput pesanan
  String _formatDistanceToPickup(DriverOrderModel order) {
    final meters = _getDistanceToPickupMeters(order);
    if (meters < 1000) {
      return '${meters.toInt()} m';
    } else {
      return '${(meters / 1000).toStringAsFixed(1)} km';
    }
  }

  /// Mengurutkan daftar pesanan dari yang paling dekat dengan driver ke yang paling jauh dalam radius 20 km
  List<DriverOrderModel> _sortOrdersByProximity(List<DriverOrderModel> rawOrders) {
    if (rawOrders.isEmpty) return rawOrders;
    final driverLat = _driverPosition?.latitude ?? 5.3850;
    final driverLng = _driverPosition?.longitude ?? 95.9600;

    // Filter pesanan hanya dalam radius operasional 20 KM
    final nearby = rawOrders.where((o) {
      final dist = Geolocator.distanceBetween(driverLat, driverLng, o.pickupLat, o.pickupLng);
      return dist <= 20000;
    }).toList();

    nearby.sort((a, b) {
      final distA = Geolocator.distanceBetween(driverLat, driverLng, a.pickupLat, a.pickupLng);
      final distB = Geolocator.distanceBetween(driverLat, driverLng, b.pickupLat, b.pickupLng);
      return distA.compareTo(distB);
    });
    return nearby;
  }

  @override
  void dispose() {
    _standbyGpsTimer?.cancel();
    _activeJobSub?.cancel();
    _pollingTimer?.cancel();
    _positionStreamSub?.cancel();
    super.dispose();
  }

  Future<void> _loadTodaySummary() async {
    final summary = await DriverService.instance.fetchTodaySummary();
    if (mounted) {
      setState(() => _todaySummary = summary);
    }
  }

  Future<void> _fetchManualOrders({bool silent = false}) async {
    if (!silent && mounted) {
      setState(() => _isLoadingManual = true);
    }
    final orders = await DriverService.instance.fetchIncomingOrders();
    if (mounted) {
      setState(() {
        _manualOrders = orders;
        _isLoadingManual = false;
      });

      _checkNewOrders(orders);
    }
  }

  void _checkNewOrders(List<DriverOrderModel> orders) {
    if (orders.isEmpty) return;
    if (!DriverService.instance.profile.isOnline) return;

    if (_isInitialOrderFetch) {
      for (final o in orders) {
        _knownOrderCodes.add(o.orderCode);
      }
      _isInitialOrderFetch = false;
      return;
    }

    final newOrders = orders.where((o) => !_knownOrderCodes.contains(o.orderCode)).toList();
    for (final o in orders) {
      _knownOrderCodes.add(o.orderCode);
    }

    // ATURAN 1: Jangan ganggu driver dengan alert notifikasi jika sedang membawa/mengerjakan pesanan
    if (_currentActiveJob != null) return;

    // ATURAN 2 (20 KM): Hanya bunyikan dan tampilkan notifikasi untuk pesanan baru dalam radius 20 KM dari posisi driver
    final nearbyNewOrders = newOrders.where((o) {
      final distMeters = _getDistanceToPickupMeters(o);
      return distMeters <= 20000; // Maksimal 20 KM
    }).toList();

    if (nearbyNewOrders.isNotEmpty) {
      // Prioritaskan order yang paling dekat dengan driver saat ini
      nearbyNewOrders.sort((a, b) {
        final distA = _getDistanceToPickupMeters(a);
        final distB = _getDistanceToPickupMeters(b);
        return distA.compareTo(distB);
      });
      _triggerNewOrderAlert(nearbyNewOrders.first);
    }
  }

  void _triggerNewOrderAlert(DriverOrderModel newOrder) {
    // 1. Tampilkan notifikasi di PANEL NOTIFIKASI SMARTPHONE (Status Bar & Drawer Android)
    final distKm = _getDistanceToPickupMeters(newOrder) / 1000.0;
    DriverNotificationService.instance.showIncomingOrderNotification(
      newOrder,
      distanceKm: distKm,
    );

    // 2. Suara Alert & Getar Hardware
    try {
      SystemSound.play(SystemSoundType.alert);
    } catch (_) {}

    HapticFeedback.heavyImpact();
    Future.delayed(const Duration(milliseconds: 180), () {
      HapticFeedback.heavyImpact();
    });
  }

  void _openAuthScreen({bool isRegister = false}) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => DriverAuthScreen(initialIsRegister: isRegister)),
    ).then((_) {
      if (mounted) {
        setState(() {});
        _loadTodaySummary();
        _fetchManualOrders();
      }
    });
  }

  Future<void> _handleClaimOrder(DriverOrderModel order) async {
    if (!DriverService.instance.isLoggedIn) {
      _showLoginRequiredDialog();
      return;
    }

    // ATURAN MITRA: Jika driver belum menyelesaikan pesanan pertama, tidak boleh mengambil orderan lain
    if (_currentActiveJob != null) {
      _showActiveOrderBlockDialog(_currentActiveJob!);
      return;
    }

    if (_isClaiming) return;
    setState(() => _isClaiming = true);

    final errorMsg = await DriverService.instance.claimOrder(order.orderCode);
    if (!mounted) return;
    setState(() => _isClaiming = false);

    if (errorMsg == null) {
      // Hapus notifikasi dari panel smartphone karena sudah diambil
      DriverNotificationService.instance.cancelOrderNotification(order.orderCode);

      HapticFeedback.mediumImpact();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: DriverTheme.onlineGreen,
          content: Text(
            'Order #${order.orderCode} Berhasil Diambil! Menuju ke layar navigasi...',
            style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
          ),
        ),
      );
      // Buka layar eksekusi aktif dengan status yang sudah driverAssigned
      final assignedOrder = order.copyWith(status: 'driverAssigned');
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => DriverActiveJobScreen(order: assignedOrder),
        ),
      ).then((_) {
        _loadTodaySummary();
        _fetchManualOrders();
      });
    } else {
      HapticFeedback.heavyImpact();
      if (errorMsg.contains('Saldo deposit') || errorMsg.contains('INSUFFICIENT_DEPOSIT')) {
        _showInsufficientDepositDialog(order);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: DriverTheme.offlineRed,
            content: Text(
              errorMsg,
              style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
            ),
          ),
        );
      }
      _fetchManualOrders();
    }
  }

  /// Dialog interaktif jika saldo deposit mitra tidak mencukupi untuk potongan admin 5%
  void _showInsufficientDepositDialog(DriverOrderModel order) {
    final adminFee = (order.deliveryFee * 0.05).round();
    final profile = DriverService.instance.profile;
    final depositBalance = profile.depositBalance;
    final currency = NumberFormat.currency(locale: 'id_ID', symbol: 'Rp ', decimalDigits: 0);

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: DriverTheme.surfaceDark,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: DriverTheme.alertAmber, width: 1.5),
        ),
        title: const Row(
          children: [
            Icon(Icons.account_balance_wallet_outlined, color: DriverTheme.alertAmber, size: 24),
            SizedBox(width: 8),
            Text(
              'Saldo Deposit Kurang',
              style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Untuk mengambil orderan ini, Anda membutuhkan saldo deposit untuk potongan biaya admin aplikasi sebesar 5%.',
              style: TextStyle(color: Colors.white70, fontSize: 13),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: DriverTheme.darkBg,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: DriverTheme.cardBorder),
              ),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Biaya Admin (5%):', style: TextStyle(color: Colors.white70, fontSize: 12)),
                      Text(
                        currency.format(adminFee),
                        style: const TextStyle(color: DriverTheme.alertAmber, fontWeight: FontWeight.bold, fontSize: 13),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Saldo Deposit Anda:', style: TextStyle(color: Colors.white70, fontSize: 12)),
                      Text(
                        currency.format(depositBalance),
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              'Silakan lakukan Top Up via QRIS Midtrans terlebih dahulu untuk melanjutkan.',
              style: TextStyle(color: DriverTheme.textMuted, fontSize: 11),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Nanti', style: TextStyle(color: Colors.white60)),
          ),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: DriverTheme.brightCyan,
              foregroundColor: Colors.black,
              minimumSize: Size.zero,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            icon: const Icon(Icons.qr_code_2, size: 18),
            label: const Text('Top Up Sekarang', style: TextStyle(fontWeight: FontWeight.bold)),
            onPressed: () {
              Navigator.pop(ctx);
              DriverQrisDialog.show(
                context,
                initialAmount: 20000,
                onSuccessRedirect: () {
                  _loadTodaySummary();
                  _fetchManualOrders();
                },
              );
            },
          ),
        ],
      ),
    );
  }

  /// Dialog peringatan bahwa driver belum menyelesaikan pesanan pertama
  void _showActiveOrderBlockDialog(DriverOrderModel activeJob) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: DriverTheme.surfaceDark,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: DriverTheme.warningYellow, width: 1.5),
        ),
        title: const Row(
          children: [
            Icon(Icons.lock_clock, color: DriverTheme.warningYellow, size: 24),
            SizedBox(width: 8),
            Text(
              'Pesanan Belum Selesai',
              style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Sesuai aturan operasional mitra, Anda tidak dapat mengambil orderan lain sebelum menyelesaikan pesanan pertama yang sedang berjalan.',
              style: TextStyle(color: Colors.white70, fontSize: 13),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.white10,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.white24),
              ),
              child: Row(
                children: [
                  const Icon(Icons.two_wheeler, color: DriverTheme.brightCyan, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Order #${activeJob.orderCode}',
                          style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white, fontSize: 13),
                        ),
                        Text(
                          'Pelanggan: ${activeJob.customerName}',
                          style: const TextStyle(color: Colors.white70, fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Tutup', style: TextStyle(color: Colors.white60)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: DriverTheme.electricBlue,
              foregroundColor: Colors.white,
              minimumSize: Size.zero,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            onPressed: () {
              Navigator.pop(ctx);
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => DriverActiveJobScreen(order: activeJob)),
              );
            },
            child: const Text('Buka Tarikan Aktif', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  /// Banner informasi di radar ketika driver sedang memiliki pesanan yang berjalan
  Widget _buildActiveJobLockBanner(DriverOrderModel activeJob) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(16, 10, 16, 6),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: DriverTheme.warningYellow.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: DriverTheme.warningYellow, width: 1.2),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(7),
            decoration: BoxDecoration(
              color: DriverTheme.warningYellow.withValues(alpha: 0.2),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.lock_clock_rounded, color: DriverTheme.warningYellow, size: 20),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'TARIKAN PERTAMA SEDANG BERJALAN',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w900,
                    color: DriverTheme.warningYellow,
                    letterSpacing: 0.5,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  'Order #${activeJob.orderCode} (${activeJob.customerName}). Selesaikan order ini terlebih dahulu sebelum mengambil order baru.',
                  style: const TextStyle(fontSize: 11, color: Colors.white70, height: 1.2),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: DriverTheme.warningYellow,
              foregroundColor: Colors.black87,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              visualDensity: VisualDensity.compact,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => DriverActiveJobScreen(order: activeJob)),
              );
            },
            child: const Text('Buka Order', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  void _showLoginRequiredDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: DriverTheme.cardDark,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.lock_person, color: DriverTheme.brightCyan),
            SizedBox(width: 10),
            Text('Masuk Diperlukan', style: TextStyle(color: Colors.white, fontSize: 16)),
          ],
        ),
        content: const Text(
          'Untuk mengambil orderan transaksi nyata, silakan Masuk atau Daftarkan identitas mitra driver Anda.',
          style: TextStyle(color: DriverTheme.textSecondary, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Nanti', style: TextStyle(color: DriverTheme.textMuted)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: DriverTheme.electricBlue,
              foregroundColor: Colors.white,
            ),
            onPressed: () {
              Navigator.pop(ctx);
              _openAuthScreen();
            },
            child: const Text('Masuk / Daftar'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final profile = DriverService.instance.profile;
    final isOnline = profile.isOnline;
    final isLoggedIn = DriverService.instance.isLoggedIn;

    return WithForegroundTask(
      child: Scaffold(
      appBar: AppBar(
        title: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Image.asset(
                  'assets/images/app_logo.png',
                  width: 26,
                  height: 26,
                  fit: BoxFit.cover,
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: DriverTheme.electricBlue.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: DriverTheme.electricBlue),
                ),
                child: const Text(
                  'MITRA PIDIE',
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: DriverTheme.brightCyan),
                ),
              ),
              const SizedBox(width: 8),
              const Text('RADAR ORDER'),
            ],
          ),
        ),
        actions: [
          IconButton(
            icon: _isLoadingManual
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(color: DriverTheme.brightCyan, strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
            tooltip: 'Segarkan Radar',
            onPressed: () {
              _loadTodaySummary();
              _fetchManualOrders();
            },
          ),
        ],
      ),
      body: Stack(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Banner Peringatan jika koneksi internet terputus
              const DriverOfflineBanner(),

              // Banner jika belum login
              if (!isLoggedIn) _buildLoginPromptBanner(),

              // 1. Header Status Dinas & Rekap Hari Ini
              _buildDriverHeader(profile, isLoggedIn),

              // Banner Pengunci jika sedang ada order aktif
              if (_currentActiveJob != null && isOnline)
                _buildActiveJobLockBanner(_currentActiveJob!),

              // 2. Radar Content Area
              Expanded(
                child: !isOnline
                    ? _buildOfflineState()
                    : RefreshIndicator(
                        color: DriverTheme.brightCyan,
                        backgroundColor: DriverTheme.surfaceDark,
                        onRefresh: () async {
                          await _loadTodaySummary();
                          await _fetchManualOrders();
                        },
                        child: StreamBuilder<List<DriverOrderModel>>(
                          stream: DriverService.instance.streamIncomingOrders(),
                          builder: (context, snapshot) {
                            // Jika stream ada data, prioritaskan stream
                            List<DriverOrderModel> orders = [];
                            if (snapshot.hasData && snapshot.data != null) {
                              orders = snapshot.data!;
                            } else if (_manualOrders.isNotEmpty) {
                              // Fallback ke REST polling cache
                              orders = _manualOrders;
                            }

                            // URUTKAN PESANAN TERDEKAT KE TERJAUH DARI POSISI DRIVER SAAT INI
                            orders = _sortOrdersByProximity(orders);

                            if (snapshot.connectionState == ConnectionState.waiting &&
                                orders.isEmpty &&
                                _isLoadingManual) {
                              return const Center(
                                child: CircularProgressIndicator(color: DriverTheme.brightCyan),
                              );
                            }

                            // Deteksi ada order baru masuk untuk getar/suara/heads-up banner
                            WidgetsBinding.instance.addPostFrameCallback((_) {
                              if (mounted) _checkNewOrders(orders);
                            });

                            if (orders.isEmpty) {
                              return _buildEmptyRadarState();
                            }

                            return ListView.builder(
                              padding: const EdgeInsets.all(16),
                              physics: const AlwaysScrollableScrollPhysics(),
                              itemCount: orders.length,
                              itemBuilder: (context, index) {
                                return _buildOrderCard(orders[index], index);
                              },
                            );
                          },
                        ),
                      ),
              ),
            ],
          ),
        ],
      ),
    ),
  );
  }

  Widget _buildLoginPromptBanner() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: DriverTheme.alertAmber.withValues(alpha: 0.15),
        border: Border(bottom: BorderSide(color: DriverTheme.alertAmber.withValues(alpha: 0.4))),
      ),
      child: Row(
        children: [
          const Icon(Icons.info_outline, color: DriverTheme.alertAmber, size: 22),
          const SizedBox(width: 12),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Akun Mitra Belum Masuk',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: DriverTheme.alertAmber),
                ),
                Text(
                  'Masuk atau daftar akun mitra untuk membaca & menerima orderan di Pidie.',
                  style: TextStyle(fontSize: 11, color: Colors.white70),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: DriverTheme.alertAmber,
              foregroundColor: Colors.black,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              minimumSize: Size.zero,
            ),
            onPressed: () => _openAuthScreen(),
            child: const Text('Masuk', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
          ),
        ],
      ),
    );
  }

  Widget _buildDriverHeader(dynamic profile, bool isLoggedIn) {
    final isOnline = (profile.isOnline as bool?) ?? false;
    final earnings = (_todaySummary['earnings'] as num?)?.toInt() ?? 0;
    final count = (_todaySummary['count'] as num?)?.toInt() ?? 0;

    final name = profile.name.toString().isNotEmpty ? profile.name : 'Mitra RBT';
    final plate = profile.plateNumber.toString().isNotEmpty ? profile.plateNumber : 'Belum Ada Plat';
    final int depositBalance = (profile?.depositBalance is num)
        ? (profile.depositBalance as num).toInt()
        : int.tryParse(profile?.depositBalance?.toString() ?? '0') ?? 0;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: DriverTheme.surfaceDark,
        border: Border(bottom: BorderSide(color: DriverTheme.cardBorder.withValues(alpha: 0.6))),
      ),
      child: Column(
        children: [
          // Switch Online / Offline
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Row(
                  children: [
                    Container(
                      width: 14,
                      height: 14,
                      decoration: BoxDecoration(
                        color: isOnline ? DriverTheme.onlineGreen : DriverTheme.offlineRed,
                        shape: BoxShape.circle,
                        boxShadow: isOnline ? DriverTheme.glowGreen : null,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            isOnline ? 'SIAP TERIMA ORDER' : 'STATUS: OFFLINE',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 14,
                              color: isOnline ? DriverTheme.onlineGreen : DriverTheme.offlineRed,
                              letterSpacing: 0.5,
                            ),
                          ),
                          Text(
                            '$name • $plate',
                            style: const TextStyle(fontSize: 12, color: DriverTheme.textSecondary),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Transform.scale(
                scale: 0.9,
                child: Switch(
                  value: isOnline,
                  activeThumbColor: DriverTheme.onlineGreen,
                  activeTrackColor: DriverTheme.onlineGreen.withValues(alpha: 0.4),
                  inactiveThumbColor: Colors.grey,
                  onChanged: (val) async {
                    await DriverService.instance.setDutyStatus(val);
                    if (mounted) setState(() {});
                    if (val) {
                      _fetchManualOrders();
                      DriverForegroundService.instance.requestIgnoreBatteryOptimization();
                      _broadcastStandbyLocation(force: true);
                    }
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // Mini Statistik Penghasilan
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: DriverTheme.darkBg,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: DriverTheme.cardBorder),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                Expanded(
                  child: Column(
                    children: [
                      const Text(
                        'Order Selesai Hari Ini',
                        style: TextStyle(fontSize: 11, color: DriverTheme.textMuted),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '$count Pesanan',
                        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: DriverTheme.textPrimary),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                Container(width: 1, height: 28, color: DriverTheme.cardBorder),
                Expanded(
                  child: Column(
                    children: [
                      const Text(
                        'Pendapatan Bersih',
                        style: TextStyle(fontSize: 11, color: DriverTheme.textMuted),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 2),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          'Rp ${earnings.toString().replaceAllMapped(RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'), (m) => '${m[1]}.')}',
                          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: DriverTheme.brightCyan),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),

          // KARTU SALDO DEPOSIT (POTONGAN ADMIN 5%) & TOMBOL TOP UP QRIS
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  DriverTheme.electricBlue.withValues(alpha: 0.18),
                  DriverTheme.darkBg,
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: DriverTheme.electricBlue.withValues(alpha: 0.4)),
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(7),
                  decoration: BoxDecoration(
                    color: DriverTheme.brightCyan.withValues(alpha: 0.15),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.account_balance_wallet_rounded, color: DriverTheme.brightCyan, size: 20),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Saldo Deposit (Biaya Admin 5%)',
                        style: TextStyle(fontSize: 10, color: DriverTheme.textMuted),
                      ),
                      Text(
                        'Rp ${depositBalance.toString().replaceAllMapped(RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'), (m) => '${m[1]}.')}',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                          color: depositBalance > 5000 ? DriverTheme.onlineGreen : DriverTheme.alertAmber,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: DriverTheme.brightCyan,
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    visualDensity: VisualDensity.compact,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    elevation: 2,
                  ),
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('Top Up', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                  onPressed: () {
                    DriverQrisDialog.show(
                      context,
                      onSuccessRedirect: () {
                        _loadTodaySummary();
                        _fetchManualOrders();
                      },
                    );
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildOfflineState() {
    return Center(
      child: SingleChildScrollView(
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: DriverTheme.surfaceDark,
                shape: BoxShape.circle,
                border: Border.all(color: DriverTheme.offlineRed.withValues(alpha: 0.5), width: 2),
              ),
              child: const Icon(Icons.power_settings_new_rounded, size: 60, color: DriverTheme.offlineRed),
            ),
            const SizedBox(height: 20),
            const Text(
              'Anda Sedang Offline',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: DriverTheme.textPrimary),
            ),
            const SizedBox(height: 8),
            const Text(
              'Nyalakan status di atas menjadi ONLINE untuk mulai mendeteksi pesanan yang masuk di Pidie.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: DriverTheme.textSecondary, height: 1.4),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: DriverTheme.onlineGreen,
                minimumSize: const Size(200, 48),
              ),
              icon: const Icon(Icons.bolt, color: Colors.white),
              label: const Text('AKTIFKAN RADAR', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
              onPressed: () async {
                await DriverService.instance.setDutyStatus(true);
                if (mounted) setState(() {});
                _fetchManualOrders();
                DriverForegroundService.instance.requestIgnoreBatteryOptimization();
                _broadcastStandbyLocation(force: true);
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyRadarState() {
    return Center(
      child: SingleChildScrollView(
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: DriverTheme.surfaceDark,
                shape: BoxShape.circle,
                border: Border.all(color: DriverTheme.brightCyan.withValues(alpha: 0.4), width: 2),
              ),
              child: const Icon(Icons.radar_rounded, size: 54, color: DriverTheme.brightCyan),
            ),
            const SizedBox(height: 20),
            const Text(
              'Radar Aktif • Mencari Orderan',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: DriverTheme.textPrimary),
            ),
            const SizedBox(height: 6),
            const Text(
              'Tetap aktif di layar ini. Pesanan baru dari pelanggan di wilayah Pidie akan bergetar dan muncul otomatis.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: DriverTheme.textSecondary, height: 1.4),
            ),
            const SizedBox(height: 16),
            TextButton.icon(
              onPressed: _fetchManualOrders,
              icon: const Icon(Icons.sync, color: DriverTheme.brightCyan, size: 16),
              label: const Text('Cek Sekarang (Manual)', style: TextStyle(color: DriverTheme.brightCyan, fontSize: 12)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildOrderCard(DriverOrderModel order, [int index = 0]) {
    final isFood = order.isFood;
    final isNearest = index == 0;
    final pickupDistanceText = _formatDistanceToPickup(order);

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: DriverTheme.surfaceDark,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isNearest
              ? DriverTheme.brightCyan
              : (isFood ? DriverTheme.foodOrange : DriverTheme.electricBlue),
          width: isNearest ? 2.2 : 1.5,
        ),
        boxShadow: isNearest
            ? [
                BoxShadow(
                  color: DriverTheme.brightCyan.withValues(alpha: 0.25),
                  blurRadius: 12,
                  spreadRadius: 1,
                  offset: const Offset(0, 2),
                ),
              ]
            : DriverTheme.softShadow,
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Badge Spesial Khusus Orderan Pertama (Paling Dekat dengan Posisi Driver)
            if (isNearest)
              Container(
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [DriverTheme.electricBlue, DriverTheme.brightCyan],
                  ),
                  borderRadius: BorderRadius.circular(8),
                  boxShadow: [
                    BoxShadow(
                      color: DriverTheme.brightCyan.withValues(alpha: 0.3),
                      blurRadius: 6,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Row(
                  children: [
                    const Icon(Icons.bolt_rounded, color: Colors.white, size: 15),
                    const SizedBox(width: 4),
                    const Expanded(
                      child: Text(
                        '🌟 TERDEKAT • EFISIEN',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 11,
                          letterSpacing: 0.3,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        '📍 $pickupDistanceText',
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 11,
                        ),
                      ),
                    ),
                  ],
                ),
              ),

            // Header Kartu: Tipe Layanan & Tarif Tunai
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Flexible(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: isFood
                          ? DriverTheme.foodOrange.withValues(alpha: 0.2)
                          : DriverTheme.electricBlue.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: isFood ? DriverTheme.foodOrange : DriverTheme.electricBlue,
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          isFood ? Icons.restaurant : Icons.two_wheeler,
                          size: 15,
                          color: isFood ? DriverTheme.foodOrange : DriverTheme.brightCyan,
                        ),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            order.typeLabel,
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                              color: isFood ? DriverTheme.foodOrange : DriverTheme.brightCyan,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        order.formattedTotalFee,
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: DriverTheme.onlineGreen,
                        ),
                      ),
                    ),
                    Text(
                      'Admin 5%: Rp ${((order.deliveryFee * 0.05).round()).toString().replaceAllMapped(RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'), (m) => '${m[1]}.')}',
                      style: const TextStyle(
                        fontSize: 10,
                        color: DriverTheme.textMuted,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 10),

            // Order Code, Pelanggan, & Jarak
            Row(
              children: [
                Text(
                  '#${order.orderCode}',
                  style: const TextStyle(
                    fontSize: 12,
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.bold,
                    color: DriverTheme.textSecondary,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '• ${order.customerName}',
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: DriverTheme.textPrimary,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: DriverTheme.cardDark,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: isNearest
                          ? DriverTheme.brightCyan.withValues(alpha: 0.6)
                          : DriverTheme.cardBorder,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.near_me_rounded,
                        size: 11,
                        color: isNearest ? DriverTheme.brightCyan : DriverTheme.onlineGreen,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        'Jemput: $pickupDistanceText',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: isNearest ? DriverTheme.brightCyan : DriverTheme.onlineGreen,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const Divider(color: DriverTheme.cardBorder, height: 20),

            // Titik Jemput
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.my_location, size: 16, color: DriverTheme.onlineGreen),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        isFood ? 'Titik Usaha Makanan / Resto:' : 'Titik Penjemputan:',
                        style: const TextStyle(fontSize: 10, color: DriverTheme.textMuted),
                      ),
                      Text(
                        order.pickupAddress,
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: DriverTheme.textPrimary),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),

            // Titik Antar
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.location_on, size: 16, color: DriverTheme.offlineRed),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Titik Antar Tujuan:',
                        style: TextStyle(fontSize: 10, color: DriverTheme.textMuted),
                      ),
                      Text(
                        order.destinationAddress,
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: DriverTheme.textPrimary),
                      ),
                    ],
                  ),
                ),
              ],
            ),

            // Catatan Makanan jika ada
            if (isFood && order.foodNotes != null && order.foodNotes!.isNotEmpty) ...[
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: DriverTheme.alertAmber.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: DriverTheme.alertAmber.withValues(alpha: 0.4)),
                ),
                child: Text(
                  'Pesanan: ${order.foodNotes}',
                  style: const TextStyle(fontSize: 11, color: DriverTheme.alertAmber, fontWeight: FontWeight.w600),
                ),
              ),
            ],

            const SizedBox(height: 14),

            // Tombol Terima Order (Otomatis terkunci jika masih ada pesanan pertama yang berjalan)
            SizedBox(
              width: double.infinity,
              height: 48,
              child: _currentActiveJob != null
                  ? OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: DriverTheme.warningYellow, width: 1.2),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        backgroundColor: DriverTheme.warningYellow.withValues(alpha: 0.1),
                      ),
                      icon: const Icon(Icons.lock_clock, color: DriverTheme.warningYellow, size: 18),
                      label: Text(
                        'SELESAIKAN ORDER #${_currentActiveJob!.orderCode} DAHULU',
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: DriverTheme.warningYellow,
                        ),
                      ),
                      onPressed: () => _showActiveOrderBlockDialog(_currentActiveJob!),
                    )
                  : ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: isFood ? DriverTheme.foodOrange : DriverTheme.electricBlue,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      icon: _isClaiming
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                            )
                          : const Icon(Icons.check_circle_outline, size: 20),
                      label: Text(
                        _isClaiming ? 'MENGAMBIL PESANAN...' : 'TERIMA ORDER INI',
                        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, letterSpacing: 0.5),
                      ),
                      onPressed: _isClaiming ? null : () => _handleClaimOrder(order),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
