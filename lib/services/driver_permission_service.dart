import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import '../constants/driver_theme.dart';
import 'driver_network_service.dart';

/// Layanan Pengelolaan Izin Khusus Mitra Driver RBT
class DriverPermissionService {
  static final DriverPermissionService instance = DriverPermissionService._internal();
  factory DriverPermissionService() => instance;
  DriverPermissionService._internal();

  /// Status izin lokasi saat ini
  Future<bool> isLocationGranted() async {
    if (kIsWeb) {
      final perm = await Geolocator.checkPermission();
      return perm == LocationPermission.always || perm == LocationPermission.whileInUse;
    }
    final status = await Permission.location.status;
    return status.isGranted;
  }

  /// Status izin notifikasi saat ini
  Future<bool> isNotificationGranted() async {
    if (kIsWeb) return true;
    final status = await Permission.notification.status;
    return status.isGranted;
  }

  /// Status izin kamera & penyimpanan saat ini
  Future<bool> isMediaGranted() async {
    if (kIsWeb) return true;
    final cameraStatus = await Permission.camera.status;
    if (Platform.isAndroid) {
      final photosStatus = await Permission.photos.status;
      final storageStatus = await Permission.storage.status;
      return cameraStatus.isGranted && (photosStatus.isGranted || storageStatus.isGranted);
    }
    return cameraStatus.isGranted;
  }

  /// Meminta izin GPS presisi driver
  Future<bool> requestLocationPermission() async {
    if (kIsWeb) {
      final perm = await Geolocator.requestPermission();
      return perm == LocationPermission.always || perm == LocationPermission.whileInUse;
    }
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      await Geolocator.openLocationSettings();
      return false;
    }

    final status = await Permission.location.request();
    return status.isGranted;
  }

  /// Meminta izin Notifikasi & Getar driver
  Future<bool> requestNotificationPermission() async {
    if (kIsWeb) return true;
    final status = await Permission.notification.request();
    return status.isGranted;
  }

  /// Meminta izin Kamera & Galeri Foto
  Future<bool> requestMediaPermissions() async {
    if (kIsWeb) return true;
    final permissions = <Permission>[Permission.camera];
    if (Platform.isAndroid) {
      permissions.add(Permission.photos);
      permissions.add(Permission.storage);
    }
    final results = await permissions.request();
    return results.values.any((s) => s.isGranted);
  }

  /// Meminta seluruh izin penting driver sekaligus
  Future<Map<Permission, PermissionStatus>> requestAllDriverPermissions() async {
    if (kIsWeb) {
      await requestLocationPermission();
      return {};
    }
    final permissions = <Permission>[
      Permission.location,
      Permission.notification,
      Permission.camera,
    ];

    if (Platform.isAndroid) {
      permissions.add(Permission.photos);
      permissions.add(Permission.storage);
    }

    return await permissions.request();
  }

  /// Cek apakah GPS atau Notifikasi belum diizinkan
  Future<bool> hasMissingDriverPermissions() async {
    if (kIsWeb) {
      final loc = await isLocationGranted();
      return !loc;
    }
    final loc = await isLocationGranted();
    final notif = await isNotificationGranted();
    return !loc || !notif;
  }

  /// Menampilkan dialog edukasi izin mitra driver dengan tema Dark Theme RBT Driver
  Future<void> showDriverPermissionDialog(BuildContext context, {VoidCallback? onComplete}) async {
    if (kIsWeb) {
      await requestLocationPermission();
      onComplete?.call();
      return;
    }
    final hasInternet = DriverNetworkService.instance.isConnected;
    final isLoc = await isLocationGranted();
    final isNotif = await isNotificationGranted();
    final isMedia = await isMediaGranted();

    if (!context.mounted) return;

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 28),
        decoration: const BoxDecoration(
          color: DriverTheme.cardDark,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          border: Border(
            top: BorderSide(color: DriverTheme.brightCyan, width: 1.5),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: DriverTheme.electricBlue.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: DriverTheme.electricBlue),
                  ),
                  child: const Icon(Icons.shield_rounded, color: DriverTheme.brightCyan, size: 28),
                ),
                const SizedBox(width: 14),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Izin Operasional Mitra Driver',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
                      ),
                      Text(
                        'Wajib untuk radar pesanan & navigasi penjemputan',
                        style: TextStyle(fontSize: 11, color: DriverTheme.textSecondary),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            _buildPermissionItem(
              icon: Icons.wifi,
              color: hasInternet ? DriverTheme.onlineGreen : DriverTheme.offlineRed,
              title: 'Koneksi Data Seluler',
              subtitle: hasInternet ? 'Jaringan terhubung' : 'Offline / Paket Data Terputus',
              status: hasInternet ? 'Aktif' : 'Periksa Data',
              isSuccess: hasInternet,
            ),
            const SizedBox(height: 12),
            _buildPermissionItem(
              icon: Icons.gps_fixed_rounded,
              color: DriverTheme.brightCyan,
              title: 'GPS Presisi Driver',
              subtitle: 'Mengurutkan pesanan terdekat ke terjauh & rute jemput',
              status: isLoc ? 'Diizinkan' : 'Wajib Aktif',
              isSuccess: isLoc,
            ),
            const SizedBox(height: 12),
            _buildPermissionItem(
              icon: Icons.notifications_active_rounded,
              color: DriverTheme.alertAmber,
              title: 'Notifikasi Suara & Getar',
              subtitle: 'Peringatan seketika saat ada order masuk di radar',
              status: isNotif ? 'Diizinkan' : 'Wajib Aktif',
              isSuccess: isNotif,
            ),
            const SizedBox(height: 12),
            _buildPermissionItem(
              icon: Icons.camera_alt_outlined,
              color: Colors.purpleAccent,
              title: 'Kamera & Foto',
              subtitle: 'Foto profil mitra driver & verifikasi identitas',
              status: isMedia ? 'Diizinkan' : 'Direkomendasikan',
              isSuccess: isMedia,
            ),
            const SizedBox(height: 24),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: DriverTheme.textMuted,
                      side: const BorderSide(color: DriverTheme.cardBorder),
                      padding: const EdgeInsets.symmetric(vertical: 13),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('Nanti Saja'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: DriverTheme.electricBlue,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 13),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    onPressed: () async {
                      Navigator.pop(ctx);
                      await requestAllDriverPermissions();
                      onComplete?.call();
                    },
                    child: const Text('Izinkan Semua', style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static Widget _buildPermissionItem({
    required IconData icon,
    required Color color,
    required String title,
    required String subtitle,
    required String status,
    required bool isSuccess,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: DriverTheme.surfaceDark,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isSuccess ? DriverTheme.onlineGreen.withValues(alpha: 0.5) : DriverTheme.cardBorder,
        ),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 18,
            backgroundColor: color.withValues(alpha: 0.15),
            child: Icon(icon, size: 20, color: color),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.white)),
                Text(subtitle, style: const TextStyle(fontSize: 11, color: DriverTheme.textSecondary)),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: isSuccess
                  ? DriverTheme.onlineGreen.withValues(alpha: 0.2)
                  : DriverTheme.alertAmber.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: isSuccess ? DriverTheme.onlineGreen : DriverTheme.alertAmber,
              ),
            ),
            child: Text(
              status,
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.bold,
                color: isSuccess ? DriverTheme.onlineGreen : DriverTheme.alertAmber,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
