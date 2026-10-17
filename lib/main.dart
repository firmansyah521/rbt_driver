import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'constants/driver_theme.dart';
import 'screens/driver_auth_gate.dart';
import 'services/driver_foreground_service.dart';
import 'services/driver_network_service.dart';
import 'services/driver_notification_service.dart';
import 'services/driver_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Inisialisasi pemantau koneksi internet real-time
  DriverNetworkService.instance.initialize();

  // Inisialisasi format tanggal bahasa Indonesia (intl)
  try {
    await initializeDateFormatting('id_ID', null);
  } catch (e) {
    debugPrint('Error init date formatting: $e');
  }

  // Pelindung UI Global: Ganti Red Screen of Death dengan UI yang rapi
  ErrorWidget.builder = (FlutterErrorDetails details) {
    return Material(
      color: DriverTheme.darkBg,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: const [
              Icon(Icons.sync_problem_rounded, color: DriverTheme.alertAmber, size: 48),
              SizedBox(height: 12),
              Text(
                'Tampilan Sedang Menyesuaikan',
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
              ),
              SizedBox(height: 6),
              Text(
                'Tarik layar ke bawah untuk menyegarkan tampilan.',
                style: TextStyle(color: DriverTheme.textMuted, fontSize: 12),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  };

  // Inisialisasi Supabase dan muat data driver lokal
  await DriverService.instance.initialize();

  // Layanan khusus native mobile (Android/iOS)
  if (!kIsWeb) {
    // Inisialisasi Layanan Notifikasi Smartphone Sistem (Panel Notifikasi HP)
    await DriverNotificationService.instance.initialize();

    // Inisialisasi Layanan Background / Foreground Service
    FlutterForegroundTask.initCommunicationPort();
    await DriverForegroundService.instance.initialize();

    // Jika driver sebelumnya dalam status Online, pastikan foreground service aktif
    if (DriverService.instance.isLoggedIn && DriverService.instance.profile.isOnline) {
      DriverForegroundService.instance.startService();
    }
  }

  runApp(const RbtDriverApp());
}

class RbtDriverApp extends StatelessWidget {
  const RbtDriverApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'RBT Driver',
      debugShowCheckedModeBanner: false,
      theme: DriverTheme.themeData,
      home: const DriverAuthGate(),
    );
  }
}
