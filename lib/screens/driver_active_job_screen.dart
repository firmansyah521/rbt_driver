import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';
import '../constants/driver_theme.dart';
import '../models/driver_order_model.dart';
import '../services/driver_routing_service.dart';
import '../services/driver_service.dart';
import '../widgets/driver_offline_banner.dart';
import '../widgets/driver_tile_layer.dart';
import '../widgets/grab_slide_button.dart';

/// Layar Eksekusi Pesanan Aktif untuk Driver
/// Menyediakan peta rute navigasi, visualisasi posisi motor driver secara real-time,
/// broadcast GPS setiap interval 30 detik ke database Supabase,
/// tombol navigasi Google Maps (turn-by-turn), kontak WhatsApp, dan stepper penyelesaian order.
class DriverActiveJobScreen extends StatefulWidget {
  final DriverOrderModel order;

  const DriverActiveJobScreen({super.key, required this.order});

  @override
  State<DriverActiveJobScreen> createState() => _DriverActiveJobScreenState();
}

class _DriverActiveJobScreenState extends State<DriverActiveJobScreen> {
  final MapController _mapController = MapController();
  final GlobalKey<GrabSlideButtonState> _slideButtonKey = GlobalKey<GrabSlideButtonState>();
  late String _currentStatus;
  List<LatLng> _routePoints = [];
  bool _isLoadingRoute = true;
  bool _isUpdatingStatus = false;
  bool _foodPickedUp = false;
  bool _isCompletedDialogShowing = false;
  bool _isCancelledDialogShowing = false;

  // Pelacakan GPS Interval 30 Detik
  Timer? _gpsBroadcastTimer;
  StreamSubscription<Position>? _positionStreamSub;
  StreamSubscription? _orderStreamSub;
  LatLng? _currentDriverLocation;
  DateTime? _lastGpsSyncTime;

  @override
  void initState() {
    super.initState();
    final initial = widget.order.status;
    _currentStatus = (initial == 'searching' || initial.isEmpty) ? 'driverAssigned' : initial;
    _loadRoute();
    _startGpsTracking();
    _listenOrderStream();
    _fetchFreshOrderStatus();
  }

  @override
  void dispose() {
    _gpsBroadcastTimer?.cancel();
    _positionStreamSub?.cancel();
    _orderStreamSub?.cancel();
    super.dispose();
  }

  Future<void> _loadRoute() async {
    setState(() => _isLoadingRoute = true);
    final result = await DriverRoutingService.getRoute(
      widget.order.pickupLatLng,
      widget.order.destLatLng,
    );

    if (!mounted) return;
    setState(() {
      _routePoints = result.points;
      _isLoadingRoute = false;
    });
  }

  /// Memulai sinkronisasi dan pelacakan GPS driver setiap interval 30 detik
  Future<void> _startGpsTracking() async {
    // 1. Ambil lokasi awal dan kirimkan segera
    await _syncDriverLocation();

    // 2. Timer interval 30 detik untuk broadcast berkala ke database Supabase
    _gpsBroadcastTimer?.cancel();
    _gpsBroadcastTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted && _currentStatus != 'completed') {
        _syncDriverLocation();
      }
    });

    // 3. Dengarkan stream pergerakan GPS lokal untuk animasi motor di peta internal & broadcast saat background / Google Maps aktif
    try {
      _positionStreamSub?.cancel();
      final LocationSettings locationSettings;
      if (defaultTargetPlatform == TargetPlatform.android) {
        locationSettings = AndroidSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 10,
          intervalDuration: const Duration(seconds: 10),
          foregroundNotificationConfig: const ForegroundNotificationConfig(
            notificationText: "RBT Driver sedang membagikan lokasi perjalanan pesanan secara realtime",
            notificationTitle: "Navigasi Perjalanan Aktif",
            enableWakeLock: true,
          ),
        );
      } else {
        locationSettings = const LocationSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 10,
        );
      }

      _positionStreamSub = Geolocator.getPositionStream(
        locationSettings: locationSettings,
      ).listen((pos) {
        if (mounted) {
          setState(() {
            _currentDriverLocation = LatLng(pos.latitude, pos.longitude);
          });
        }
        // Pastikan koordinat tetap terkirim ke Supabase walaupun aplikasi berada di background (misal saat membuka Google Maps)
        final now = DateTime.now();
        if (_lastGpsSyncTime == null || now.difference(_lastGpsSyncTime!).inSeconds >= 10) {
          _lastGpsSyncTime = now;
          DriverService.instance.updateDriverLocation(
            pos.latitude,
            pos.longitude,
            activeOrderCode: widget.order.orderCode,
          );
        }
      });
    } catch (_) {}
  }

  /// Mengambil koordinat GPS akurat driver dan mengirimkannya ke cloud
  Future<void> _syncDriverLocation() async {
    try {
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 8),
        ),
      );
      if (!mounted) return;

      setState(() {
        _currentDriverLocation = LatLng(pos.latitude, pos.longitude);
        _lastGpsSyncTime = DateTime.now();
      });

      // Kirim koordinat ke Supabase (tabel orders & drivers)
      await DriverService.instance.updateDriverLocation(
        pos.latitude,
        pos.longitude,
        activeOrderCode: widget.order.orderCode,
      );
      debugPrint('[GPS 30s] Berhasil broadcast lokasi driver: ${pos.latitude}, ${pos.longitude}');
    } catch (e) {
      debugPrint('Error sinkronisasi GPS driver: $e');
    }
  }

  /// Membuka Navigasi Belokan demi Belokan (Google Maps Navigation)
  Future<void> _openTurnByTurnNavigation() async {
    final isDelivering = _currentStatus == 'delivering' || (widget.order.isFood && _foodPickedUp);
    final targetLat = isDelivering ? widget.order.destLat : widget.order.pickupLat;
    final targetLng = isDelivering ? widget.order.destLng : widget.order.pickupLng;
    final targetName = isDelivering ? widget.order.destinationAddress : widget.order.pickupAddress;

    // Intent navigasi Google Maps (Turn-by-Turn GPS)
    final googleNavUri = Uri.parse('google.navigation:q=$targetLat,$targetLng&mode=d');
    final googleMapsWebUri = Uri.parse(
      'https://www.google.com/maps/dir/?api=1&destination=$targetLat,$targetLng&travelmode=driving',
    );

    try {
      if (await canLaunchUrl(googleNavUri)) {
        await launchUrl(googleNavUri, mode: LaunchMode.externalApplication);
      } else if (await canLaunchUrl(googleMapsWebUri)) {
        await launchUrl(googleMapsWebUri, mode: LaunchMode.externalApplication);
      } else {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: DriverTheme.alertAmber,
            content: Text('Menuju: $targetName'),
          ),
        );
      }
    } catch (e) {
      debugPrint('Error buka navigasi: $e');
    }
  }

  void _openCustomerWhatsApp() async {
    final clean = DriverService.cleanPhone(widget.order.customerPhone);
    final phoneForWa = clean.startsWith('0') ? '62${clean.substring(1)}' : clean;
    final driverName = DriverService.instance.profile.name;
    final plate = DriverService.instance.profile.plateNumber;

    final message = Uri.encodeComponent(
      'Halo Kak ${widget.order.customerName}, saya $driverName (Plat: $plate) mitra driver RBT Pidie.\n'
      'Saya sudah menerima pesanan Anda (#${widget.order.orderCode}) dan sedang memproses penjemputan.\n'
      'Mohon ditunggu ya kak, terima kasih!',
    );

    final url = Uri.parse('https://wa.me/$phoneForWa?text=$message');
    if (await canLaunchUrl(url)) {
      await launchUrl(url, mode: LaunchMode.externalApplication);
    } else {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Nomor Pelanggan: ${widget.order.customerPhone}')),
      );
    }
  }

  void _callCustomerPhone() async {
    final clean = DriverService.cleanPhone(widget.order.customerPhone);
    final url = Uri.parse('tel:$clean');
    if (await canLaunchUrl(url)) {
      await launchUrl(url);
    }
  }

  Future<void> _advanceStatus(String nextStatus) async {
    if (_isUpdatingStatus) return;
    setState(() => _isUpdatingStatus = true);

    final success = await DriverService.instance.updateOrderStatus(
      widget.order.orderCode,
      nextStatus,
    );

    if (!mounted) return;
    setState(() => _isUpdatingStatus = false);

    if (success) {
      HapticFeedback.mediumImpact();
      setState(() => _currentStatus = nextStatus);

      // Kirim koordinat langsung saat status berubah
      _syncDriverLocation();

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: DriverTheme.onlineGreen,
          content: Text(
            'Status diperbarui: ${_getStatusLabel(nextStatus)}',
            style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
          ),
        ),
      );

      if (nextStatus == 'completed') {
        _showCompletedDialog();
      }
    } else {
      HapticFeedback.heavyImpact();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          backgroundColor: DriverTheme.offlineRed,
          content: Text('Gagal memperbarui status. Periksa koneksi internet.'),
        ),
      );
    }
  }

  void _confirmCompleteOrder() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: DriverTheme.surfaceDark,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.check_circle, color: DriverTheme.onlineGreen, size: 28),
            SizedBox(width: 10),
            Text('Selesaikan Pesanan', style: TextStyle(color: DriverTheme.textPrimary, fontSize: 16)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Pastikan Anda telah mengantar penumpang/makanan ke lokasi tujuan dengan selamat.',
              style: TextStyle(color: DriverTheme.textSecondary, fontSize: 13),
            ),
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: DriverTheme.darkBg,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: DriverTheme.onlineGreen.withValues(alpha: 0.5)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Terima Tunai:', style: TextStyle(color: DriverTheme.textMuted, fontSize: 12)),
                  Text(
                    widget.order.formattedTotalFee,
                    style: const TextStyle(
                      color: DriverTheme.onlineGreen,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            child: const Text('Batal', style: TextStyle(color: Colors.grey)),
            onPressed: () => Navigator.pop(ctx),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: DriverTheme.onlineGreen,
              minimumSize: const Size(120, 42),
            ),
            child: const Text('SELESAIKAN', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
            onPressed: () {
              Navigator.pop(ctx);
              _advanceStatus('completed');
            },
          ),
        ],
      ),
    ).then((_) {
      _slideButtonKey.currentState?.reset();
    });
  }

  void _showCompletedDialog() {
    if (_isCompletedDialogShowing || !mounted) return;
    _isCompletedDialogShowing = true;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: DriverTheme.surfaceDark,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(20),
              decoration: const BoxDecoration(
                color: DriverTheme.onlineGreen,
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.thumb_up_alt_rounded, color: Colors.white, size: 48),
            ),
            const SizedBox(height: 18),
            const Text(
              'Tarikan Selesai!',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: DriverTheme.textPrimary),
            ),
            const SizedBox(height: 8),
            Text(
              'Alhamdulillah, Anda telah mengantongi ${widget.order.formattedTotalFee} dari order ini.',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13, color: DriverTheme.textSecondary),
            ),
            const SizedBox(height: 22),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: DriverTheme.electricBlue,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: const Text('KEMBALI KE RADAR', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                onPressed: () {
                  Navigator.pop(ctx);
                  Navigator.pop(context);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _confirmEmergencyCancel() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: DriverTheme.surfaceDark,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Lepas Pesanan Ini?', style: TextStyle(color: DriverTheme.textPrimary, fontSize: 16)),
        content: const Text(
          'Pesanan akan dikembalikan ke radar pencarian agar dapat diambil oleh mitra driver lain di Pidie.',
          style: TextStyle(color: DriverTheme.textSecondary, fontSize: 13),
        ),
        actions: [
          TextButton(
            child: const Text('Tidak, Lanjutkan Kerja', style: TextStyle(color: Colors.grey)),
            onPressed: () => Navigator.pop(ctx),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: DriverTheme.offlineRed),
            child: const Text('YA, LEPAS PESANAN', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            onPressed: () async {
              Navigator.pop(ctx);
              await DriverService.instance.releaseOrCancelOrder(widget.order.orderCode, returnToRadar: true);
              if (mounted) {
                Navigator.pop(context);
              }
            },
          ),
        ],
      ),
    );
  }

  /// Sinkronisasi status terkini pesanan langsung dari Supabase
  Future<void> _fetchFreshOrderStatus() async {
    try {
      final c = DriverService.instance.client;
      if (c == null) return;
      final res = await c
          .from('orders')
          .select('status')
          .eq('order_code', widget.order.orderCode)
          .maybeSingle();
      if (res != null && mounted) {
        final status = res['status']?.toString();
        if (status != null && status.isNotEmpty && status != 'searching') {
          setState(() {
            _currentStatus = status;
          });
          if (status == 'cancelled') {
            _showOrderCancelledAlert();
          }
        }
      }
    } catch (e) {
      debugPrint('Catatan fetchFreshOrderStatus: $e');
    }
  }

  /// Mendengarkan perubahan status pesanan secara realtime
  void _listenOrderStream() {
    try {
      final c = DriverService.instance.client;
      if (c == null) return;
      _orderStreamSub = c
          .from('orders')
          .stream(primaryKey: ['id'])
          .eq('order_code', widget.order.orderCode)
          .listen((records) {
            if (!mounted || records.isEmpty) return;
            final status = records.first['status']?.toString();
            if (status != null && status.isNotEmpty && status != 'searching' && status != _currentStatus) {
              setState(() {
                _currentStatus = status;
              });
              if (status == 'cancelled') {
                _showOrderCancelledAlert();
              } else if (status == 'completed') {
                _showCompletedDialog();
              }
            }
          });
    } catch (e) {
      debugPrint('Catatan listenOrderStream: $e');
    }
  }

  /// Alert jika pesanan dibatalkan oleh pemesan
  void _showOrderCancelledAlert() {
    if (_isCancelledDialogShowing || !mounted) return;
    _isCancelledDialogShowing = true;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: DriverTheme.surfaceDark,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.cancel, color: DriverTheme.offlineRed, size: 28),
            SizedBox(width: 10),
            Text('Pesanan Dibatalkan', style: TextStyle(color: DriverTheme.textPrimary, fontSize: 16)),
          ],
        ),
        content: const Text(
          'Pesanan ini telah dibatalkan oleh pelanggan. Anda dapat kembali ke radar pencarian untuk mengambil order lain.',
          style: TextStyle(color: DriverTheme.textSecondary, fontSize: 13),
        ),
        actions: [
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: DriverTheme.offlineRed,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            onPressed: () {
              Navigator.pop(ctx);
              Navigator.pop(context);
            },
            child: const Text('KEMBALI KE RADAR', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  String _getStatusLabel(String status) {
    final isFood = widget.order.isFood;
    switch (status) {
      case 'searching':
      case 'driverAssigned':
        return isFood ? 'Driver Menuju Resto' : 'Mitra Ditugaskan (Menunggu Jalan)';
      case 'headingToLocation':
        if (isFood) {
          return _foodPickedUp ? 'Driver Menuju ke Tempat Antar' : 'Driver Mengambil Pesanan Makanan';
        }
        return 'Driver Menuju Titik Jemput';
      case 'delivering':
        return isFood ? 'Driver Mengantar ke Pelanggan' : 'Sedang Mengantar ke Tujuan';
      case 'completed':
        return 'Pesanan Telah Selesai';
      case 'cancelled':
        return 'Pesanan Dibatalkan Pelanggan';
      default:
        return 'Mitra Ditugaskan';
    }
  }

  @override
  Widget build(BuildContext context) {
    final isFood = widget.order.isFood;

    return Scaffold(
      appBar: AppBar(
        title: Column(
          children: [
            Text(
              'ORDER #${widget.order.orderCode}',
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, letterSpacing: 0.5),
            ),
            Text(
              _getStatusLabel(_currentStatus),
              style: const TextStyle(fontSize: 11, color: DriverTheme.textSecondary),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.cancel_outlined, color: DriverTheme.offlineRed, size: 22),
            tooltip: 'Lepas Pesanan',
            onPressed: _confirmEmergencyCancel,
          ),
        ],
      ),
      body: Column(
        children: [
          const DriverOfflineBanner(),
          Expanded(
            child: Stack(
              children: [
                // 1. Peta Rute OpenStreetMap Interaktif
                RepaintBoundary(
                  child: FlutterMap(
                    mapController: _mapController,
                    options: MapOptions(
                      initialCenter: _currentDriverLocation ?? widget.order.pickupLatLng,
                      initialZoom: 15.0,
                    ),
                    children: [
                      const DriverTileLayer(),
                      if (_routePoints.isNotEmpty)
                        PolylineLayer(
                          polylines: [
                            Polyline(
                              points: _routePoints,
                              color: DriverTheme.primaryBenhur,
                              strokeWidth: 5.0,
                            ),
                          ],
                        ),
                      MarkerLayer(
                        markers: [
                          // Marker Posisi Motor Driver Aktual (Live GPS)
                          if (_currentDriverLocation != null)
                            Marker(
                              point: _currentDriverLocation!,
                              width: 44,
                              height: 44,
                              child: Container(
                                decoration: BoxDecoration(
                                  color: DriverTheme.primaryBenhur,
                                  shape: BoxShape.circle,
                                  border: Border.all(color: Colors.white, width: 2.5),
                                  boxShadow: const [
                                    BoxShadow(
                                      color: Colors.black45,
                                      blurRadius: 8,
                                      offset: Offset(0, 2),
                                    ),
                                  ],
                                ),
                                child: const Icon(
                                  Icons.two_wheeler_rounded,
                                  color: Colors.white,
                                  size: 24,
                                ),
                              ),
                            ),

                          // Marker Titik Jemput (Lingkaran Hitam Dot Hijau)
                          Marker(
                            point: widget.order.pickupLatLng,
                            width: 36,
                            height: 36,
                            child: Container(
                              decoration: BoxDecoration(
                                color: DriverTheme.primaryBenhur,
                                shape: BoxShape.circle,
                                border: Border.all(color: Colors.white, width: 2.0),
                                boxShadow: const [BoxShadow(color: Color(0x330038A8), blurRadius: 4)],
                              ),
                              child: Center(
                                child: Container(
                                  width: 12,
                                  height: 12,
                                  decoration: const BoxDecoration(
                                    color: DriverTheme.onlineGreen,
                                    shape: BoxShape.circle,
                                  ),
                                ),
                              ),
                            ),
                          ),

                          // Marker Titik Tujuan (Kotak Hitam Dot Putih Ala Uber)
                          Marker(
                            point: widget.order.destLatLng,
                            width: 36,
                            height: 36,
                            child: Container(
                              decoration: BoxDecoration(
                                color: DriverTheme.primaryBenhur,
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: Colors.white, width: 2.0),
                                boxShadow: const [BoxShadow(color: Color(0x330038A8), blurRadius: 4)],
                              ),
                              child: Center(
                                child: Container(
                                  width: 10,
                                  height: 10,
                                  decoration: const BoxDecoration(
                                    color: Colors.white,
                                    shape: BoxShape.rectangle,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),

                // Indikator Status GPS 30 Detik
                Positioned(
                  top: 14,
                  left: 14,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: DriverTheme.cardDark,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: DriverTheme.cardBorder),
                      boxShadow: const [BoxShadow(color: Colors.black38, blurRadius: 6)],
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: const BoxDecoration(
                            color: DriverTheme.onlineGreen,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          _lastGpsSyncTime != null
                              ? 'GPS Aktif (${_lastGpsSyncTime!.minute.toString().padLeft(2, "0")}:${_lastGpsSyncTime!.second.toString().padLeft(2, "0")})'
                              : 'GPS Sync 30s',
                          style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                  ),
                ),

                // Tombol Pusatkan ke Posisi Driver (Re-center GPS)
                Positioned(
                  top: 14,
                  right: 14,
                  child: FloatingActionButton.small(
                    backgroundColor: DriverTheme.cardDark,
                    foregroundColor: Colors.white,
                    elevation: 3,
                    tooltip: 'Pusatkan ke Posisi Motor',
                    onPressed: () {
                      if (_currentDriverLocation != null) {
                        _mapController.move(_currentDriverLocation!, 16.5);
                      } else {
                        _syncDriverLocation();
                      }
                    },
                    child: const Icon(Icons.my_location_rounded, size: 20),
                  ),
                ),

                if (_isLoadingRoute)
                  Positioned(
                    top: 60,
                    left: 0,
                    right: 0,
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                        decoration: BoxDecoration(
                          color: DriverTheme.cardDark,
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: DriverTheme.cardBorder),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                            ),
                            SizedBox(width: 8),
                            Text('Memuat rute navigasi...', style: TextStyle(color: Colors.white, fontSize: 11)),
                          ],
                        ),
                      ),
                    ),
                  ),

                // 2. Bottom Sheet Aksi Driver, Navigasi Google Maps & Kontak Pelanggan
                Positioned(
                  bottom: 0,
                  left: 0,
                  right: 0,
                  child: Container(
                    padding: const EdgeInsets.all(18),
                    decoration: const BoxDecoration(
                      color: DriverTheme.cardDark,
                      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
                      border: Border(top: BorderSide(color: DriverTheme.cardBorder, width: 1.0)),
                      boxShadow: [
                        BoxShadow(color: Colors.black54, blurRadius: 16, offset: Offset(0, -4)),
                      ],
                    ),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight: MediaQuery.of(context).size.height * 0.75,
                      ),
                      child: SingleChildScrollView(
                        physics: const ClampingScrollPhysics(),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Kartu Pelanggan & Kontak Cepat WhatsApp Ala Uber
                            Row(
                              children: [
                                CircleAvatar(
                                  radius: 22,
                                  backgroundColor: DriverTheme.uberPillBg,
                                  child: const Icon(Icons.person, color: Colors.white, size: 24),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        widget.order.customerName,
                                        style: const TextStyle(
                                          fontSize: 15,
                                          fontWeight: FontWeight.bold,
                                          color: DriverTheme.textPrimary,
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      Text(
                                        widget.order.customerPhone,
                                        style: const TextStyle(fontSize: 12, color: DriverTheme.textSecondary),
                                      ),
                                    ],
                                  ),
                                ),
                                // Tombol WhatsApp Bulat
                                IconButton(
                                  style: IconButton.styleFrom(
                                    backgroundColor: DriverTheme.uberPillBg,
                                    side: const BorderSide(color: DriverTheme.cardBorder),
                                    padding: const EdgeInsets.all(10),
                                  ),
                                  icon: const Icon(Icons.chat_bubble_outline_rounded, color: Colors.white, size: 18),
                                  tooltip: 'Chat WhatsApp Pelanggan',
                                  onPressed: _openCustomerWhatsApp,
                                ),
                                const SizedBox(width: 8),
                                // Tombol Telepon Bulat
                                IconButton(
                                  style: IconButton.styleFrom(
                                    backgroundColor: DriverTheme.uberPillBg,
                                    side: const BorderSide(color: DriverTheme.cardBorder),
                                    padding: const EdgeInsets.all(10),
                                  ),
                                  icon: const Icon(Icons.phone_outlined, color: Colors.white, size: 18),
                                  tooltip: 'Telepon Seluler',
                                  onPressed: _callCustomerPhone,
                                ),
                              ],
                            ),

                            const Divider(color: DriverTheme.cardBorder, height: 22),

                            // Rute: Titik Jemput (Lingkaran) -> Garis -> Titik Antar (Kotak)
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Column(
                                  children: [
                                    Container(
                                      width: 10,
                                      height: 10,
                                      decoration: const BoxDecoration(
                                        color: DriverTheme.onlineGreen,
                                        shape: BoxShape.circle,
                                      ),
                                    ),
                                    Container(
                                      width: 1.5,
                                      height: 24,
                                      color: DriverTheme.cardBorder,
                                    ),
                                    Container(
                                      width: 9,
                                      height: 9,
                                      decoration: const BoxDecoration(
                                        color: Colors.white,
                                        shape: BoxShape.rectangle,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        widget.order.pickupAddress,
                                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.white),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      const SizedBox(height: 16),
                                      Text(
                                        widget.order.destinationAddress,
                                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.white),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),

                            // Catatan Makanan jika ada
                            if (isFood && widget.order.foodNotes != null && widget.order.foodNotes!.isNotEmpty) ...[
                              const SizedBox(height: 10),
                              Container(
                                width: double.infinity,
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                                decoration: BoxDecoration(
                                  color: DriverTheme.uberPillBg,
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(color: DriverTheme.cardBorder),
                                ),
                                child: Text(
                                  'Catatan: ${widget.order.foodNotes}',
                                  style: const TextStyle(fontSize: 11, color: DriverTheme.alertAmber, fontWeight: FontWeight.w500),
                                ),
                              ),
                            ],

                            const SizedBox(height: 12),

                            // Tagihan Tunai
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                              decoration: BoxDecoration(
                                color: DriverTheme.darkBg,
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(color: DriverTheme.cardBorder),
                              ),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  const Row(
                                    children: [
                                      Icon(Icons.payments_outlined, size: 18, color: Colors.white70),
                                      SizedBox(width: 8),
                                      Text(
                                        'Tagih Tunai ke Pelanggan:',
                                        style: TextStyle(fontSize: 12, color: DriverTheme.textMuted),
                                      ),
                                    ],
                                  ),
                                  FittedBox(
                                    fit: BoxFit.scaleDown,
                                    child: Text(
                                      widget.order.formattedTotalFee,
                                      style: const TextStyle(
                                        fontSize: 17,
                                        fontWeight: FontWeight.bold,
                                        color: Colors.white,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),

                            const SizedBox(height: 12),

                            // Tombol Cepat Navigasi Google Maps (Turn-by-Turn GPS)
                            SizedBox(
                              width: double.infinity,
                              height: 46,
                              child: ElevatedButton.icon(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: DriverTheme.uberPillBg,
                                  foregroundColor: Colors.white,
                                  elevation: 0,
                                  side: const BorderSide(color: DriverTheme.cardBorder),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                ),
                                icon: const Icon(Icons.navigation_rounded, color: Colors.white, size: 18),
                                label: FittedBox(
                                  fit: BoxFit.scaleDown,
                                  child: Text(
                                    _currentStatus == 'delivering'
                                        ? 'NAVIGASI KE TUJUAN (GOOGLE MAPS)'
                                        : 'NAVIGASI KE PENJEMPUTAN (GOOGLE MAPS)',
                                    style: const TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold,
                                      letterSpacing: 0.5,
                                      color: Colors.white,
                                    ),
                                  ),
                                ),
                                onPressed: _openTurnByTurnNavigation,
                              ),
                            ),

                            const SizedBox(height: 12),

                            // Stepper Indikator Visual Tahapan Pesanan
                            _buildStepProgressIndicator(),

                            // Stepper Tombol Aksi Bertahap Driver
                            _buildActionButton(),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Indikator Tahapan Visual Sesuai Alur Nyata Driver RBT
  Widget _buildStepProgressIndicator() {
    final bool isFood = widget.order.isFood;
    int activeStep = 1;
    if (isFood) {
      if (_currentStatus == 'driverAssigned' || _currentStatus == 'searching') {
        activeStep = 1;
      } else if (_currentStatus == 'headingToLocation') {
        activeStep = _foodPickedUp ? 3 : 2;
      } else if (_currentStatus == 'delivering') {
        activeStep = 3;
      } else if (_currentStatus == 'completed') {
        activeStep = 4;
      }
    } else {
      if (_currentStatus == 'headingToLocation') {
        activeStep = 1;
      } else if (_currentStatus == 'delivering') {
        activeStep = 2;
      } else if (_currentStatus == 'completed') {
        activeStep = 3;
      }
    }

    Widget buildStepItem(int stepNumber, String title, bool isDone, bool isCurrent) {
      final Color color = isDone
          ? DriverTheme.onlineGreen
          : isCurrent
              ? Colors.white
              : DriverTheme.textMuted.withValues(alpha: 0.5);

      return Expanded(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 18,
              height: 18,
              decoration: BoxDecoration(
                color: isDone
                    ? DriverTheme.onlineGreen
                    : isCurrent
                        ? DriverTheme.primaryBenhur
                        : Colors.transparent,
                shape: BoxShape.circle,
                border: Border.all(
                  color: color,
                  width: 1.5,
                ),
              ),
              child: Center(
                child: isDone
                    ? const Icon(Icons.check, size: 11, color: Colors.white)
                    : Text(
                        '$stepNumber',
                        style: TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.bold,
                          color: isCurrent ? Colors.white : DriverTheme.textMuted,
                        ),
                      ),
              ),
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                title,
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: isCurrent || isDone ? FontWeight.bold : FontWeight.normal,
                  color: isCurrent
                      ? Colors.white
                      : isDone
                          ? DriverTheme.onlineGreen
                          : DriverTheme.textMuted,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: DriverTheme.darkBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: DriverTheme.cardBorder),
      ),
      child: Row(
        children: isFood
            ? [
                buildStepItem(1, 'Menuju Resto', activeStep > 1, activeStep == 1),
                Container(width: 6, height: 1.5, color: activeStep > 1 ? DriverTheme.onlineGreen : DriverTheme.cardBorder),
                buildStepItem(2, 'Ambil Makanan', activeStep > 2, activeStep == 2),
                Container(width: 6, height: 1.5, color: activeStep > 2 ? DriverTheme.onlineGreen : DriverTheme.cardBorder),
                buildStepItem(3, 'Menuju Antar', activeStep > 3, activeStep == 3),
                Container(width: 6, height: 1.5, color: activeStep > 3 ? DriverTheme.onlineGreen : DriverTheme.cardBorder),
                buildStepItem(4, 'Selesai', _currentStatus == 'completed', activeStep == 4),
              ]
            : [
                buildStepItem(1, 'Jemput', activeStep > 1, activeStep == 1),
                Container(width: 12, height: 1.5, color: activeStep > 1 ? DriverTheme.onlineGreen : DriverTheme.cardBorder, margin: const EdgeInsets.symmetric(horizontal: 4)),
                buildStepItem(2, 'Antar', activeStep > 2, activeStep == 2),
                Container(width: 12, height: 1.5, color: activeStep > 2 ? DriverTheme.onlineGreen : DriverTheme.cardBorder, margin: const EdgeInsets.symmetric(horizontal: 4)),
                buildStepItem(3, 'Selesai', _currentStatus == 'completed', activeStep == 3),
              ],
      ),
    );
  }

  Widget _buildActionButton() {
    if (_isUpdatingStatus) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(12),
          child: CircularProgressIndicator(color: Colors.white),
        ),
      );
    }

    final bool isFood = widget.order.isFood;

    // TAHAP 1: Menuju Titik Jemput / Resto
    if (_currentStatus == 'driverAssigned' || _currentStatus == 'searching') {
      return SizedBox(
        width: double.infinity,
        height: 50,
        child: ElevatedButton.icon(
          style: ElevatedButton.styleFrom(
            backgroundColor: DriverTheme.primaryBenhur,
            foregroundColor: Colors.white,
            elevation: 0,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
          icon: Icon(isFood ? Icons.storefront_rounded : Icons.directions_bike),
          label: Text(
            isFood ? '1. MENUJU RESTO' : '1. MENUJU TITIK JEMPUT',
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, letterSpacing: 0.5),
          ),
          onPressed: () => _advanceStatus('headingToLocation'),
        ),
      );
    }

    // TAHAP 2: Khusus Makanan: (A) Driver Mengambil Pesanan, (B) Driver Menuju Tempat Antar
    if (isFood && _currentStatus == 'headingToLocation') {
      if (!_foodPickedUp) {
        return SizedBox(
          width: double.infinity,
          height: 50,
          child: ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: DriverTheme.primaryBenhur,
              foregroundColor: Colors.white,
              elevation: 0,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            icon: const Icon(Icons.takeout_dining_rounded),
            label: const Text(
              '2. AMBIL PESANAN MAKANAN',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, letterSpacing: 0.5),
            ),
            onPressed: () {
              setState(() => _foodPickedUp = true);
              HapticFeedback.mediumImpact();
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  backgroundColor: DriverTheme.onlineGreen,
                  content: Text('Pesanan makanan telah diambil! Lanjutkan menuju ke tempat antar.'),
                ),
              );
            },
          ),
        );
      } else {
        return SizedBox(
          width: double.infinity,
          height: 50,
          child: ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: DriverTheme.primaryBenhur,
              foregroundColor: Colors.white,
              elevation: 0,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            icon: const Icon(Icons.delivery_dining_rounded),
            label: const Text(
              '3. MENUJU KE TEMPAT ANTAR',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, letterSpacing: 0.5),
            ),
            onPressed: () => _advanceStatus('delivering'),
          ),
        );
      }
    }

    // TAHAP 2 (Ride): Sudah jalan menuju jemput -> tiba di titik jemput & mulai antar penumpang
    if (!isFood && _currentStatus == 'headingToLocation') {
      return SizedBox(
        width: double.infinity,
        height: 50,
        child: ElevatedButton.icon(
          style: ElevatedButton.styleFrom(
            backgroundColor: DriverTheme.primaryBenhur,
            foregroundColor: Colors.white,
            elevation: 0,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
          icon: const Icon(Icons.place),
          label: const Text(
            '2. TIBA DI JEMPUT (MULAI ANTAR)',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, letterSpacing: 0.5),
          ),
          onPressed: () => _advanceStatus('delivering'),
        ),
      );
    }

    // TAHAP 3: Sedang mengantar -> selesai pengantaran dan tagih pembayaran
    if (_currentStatus == 'delivering') {
      return GrabSlideButton(
        key: _slideButtonKey,
        label: isFood ? 'GESER UNTUK SELESAIKAN (MAKANAN)' : 'GESER UNTUK SELESAIKAN',
        sublabel: 'Terima ${widget.order.formattedTotalFee}',
        onSlideComplete: _confirmCompleteOrder,
      );
    }

    // TAHAP 4: Pesanan sudah benar-benar selesai
    if (_currentStatus == 'completed') {
      return SizedBox(
        width: double.infinity,
        height: 48,
        child: ElevatedButton.icon(
          style: ElevatedButton.styleFrom(
            backgroundColor: DriverTheme.onlineGreen,
            foregroundColor: Colors.white,
            elevation: 0,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
          icon: const Icon(Icons.check_circle_outline),
          label: const Text('PESANAN SUDAH SELESAI • KEMBALI KE RADAR', style: TextStyle(fontWeight: FontWeight.bold)),
          onPressed: () => Navigator.pop(context),
        ),
      );
    }

    // TAHAP 5: Pesanan dibatalkan
    if (_currentStatus == 'cancelled') {
      return SizedBox(
        width: double.infinity,
        height: 48,
        child: ElevatedButton.icon(
          style: ElevatedButton.styleFrom(
            backgroundColor: DriverTheme.offlineRed,
            foregroundColor: Colors.white,
            elevation: 0,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
          icon: const Icon(Icons.cancel_outlined),
          label: const Text('PESANAN TELAH DIBATALKAN • KEMBALI', style: TextStyle(fontWeight: FontWeight.bold)),
          onPressed: () => Navigator.pop(context),
        ),
      );
    }

    // FALLBACK AMAN: Jika status tidak dikenal, default ke tahap 1 (MENUJU TITIK JEMPUT)
    return SizedBox(
      width: double.infinity,
      height: 50,
      child: ElevatedButton.icon(
        style: ElevatedButton.styleFrom(
          backgroundColor: DriverTheme.primaryBenhur,
          foregroundColor: Colors.white,
          elevation: 0,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
        icon: const Icon(Icons.directions_bike),
        label: const Text(
          '1. MENUJU TITIK JEMPUT',
          style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, letterSpacing: 0.5),
        ),
        onPressed: () => _advanceStatus('headingToLocation'),
      ),
    );
  }
}
