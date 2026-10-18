import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:http/http.dart' as http;
import '../models/driver_order_model.dart';
import 'driver_notification_service.dart';

/// Top-level callback entrypoint untuk background task runner
@pragma('vm:entry-point')
void driverForegroundCallback() {
  FlutterForegroundTask.setTaskHandler(DriverTaskHandler());
}

/// Handler yang berjalan di dalam service foreground Android
/// Memastikan radar terus memantau pesanan baru di latar belakang meskipun aplikasi di-minimize
class DriverTaskHandler extends TaskHandler {
  final Set<String> _seenOrderCodes = {};
  bool _isFirstCheck = true;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    debugPrint('[DriverForegroundTask] Service dimulai: ${starter.name}');
    _seenOrderCodes.clear();
    _isFirstCheck = true;
  }

  @override
  void onRepeatEvent(DateTime timestamp) async {
    // Pengecekan radar langsung di dalam background isolate
    try {
      final uri = Uri.parse(
        'https://fmmvtzwigwgfsbmqbqml.supabase.co/rest/v1/orders?status=eq.searching&select=*&order=created_at.desc&limit=10',
      );
      final res = await http.get(uri, headers: {
        'apikey': 'sb_publishable_1tdhGEJNmf8TDU2C__KXTQ_xpn54beP',
        'Authorization': 'Bearer sb_publishable_1tdhGEJNmf8TDU2C__KXTQ_xpn54beP',
      }).timeout(const Duration(seconds: 6));

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        if (data is List) {
          final orders = data
              .map((m) {
                try {
                  return DriverOrderModel.fromMap(m as Map<String, dynamic>);
                } catch (_) {
                  return null;
                }
              })
              .whereType<DriverOrderModel>()
              .toList();

          if (_isFirstCheck) {
            for (final o in orders) {
              _seenOrderCodes.add(o.orderCode);
            }
            _isFirstCheck = false;
            return;
          }

          final newOrders = orders.where((o) => !_seenOrderCodes.contains(o.orderCode)).toList();
          for (final o in orders) {
            _seenOrderCodes.add(o.orderCode);
          }

          if (newOrders.isNotEmpty) {
            final first = newOrders.first;
            debugPrint('[DriverForegroundTask] Pesanan baru terdeteksi di background: #${first.orderCode}');

            // Tampilkan notifikasi di panel status bar smartphone
            await DriverNotificationService.instance.showIncomingOrderNotification(first);

            // Perbarui teks notifikasi persisten Foreground Task
            FlutterForegroundTask.updateService(
              notificationTitle: '🔔 Order Masuk: ${first.typeLabel} (Rp ${first.deliveryFee})',
              notificationText: 'Jemput: ${first.pickupAddress}',
            );
          }
        }
      }
    } catch (e) {
      debugPrint('[DriverForegroundTask] Error background check: $e');
    }
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    debugPrint('[DriverForegroundTask] Service dihentikan (timeout: $isTimeout)');
  }

  @override
  void onReceiveData(Object data) {
    debugPrint('[DriverForegroundTask] Menerima data: $data');
  }
}

/// Singleton Service untuk mengelola Foreground Task RBT Driver
class DriverForegroundService {
  static final DriverForegroundService instance = DriverForegroundService._internal();
  factory DriverForegroundService() => instance;
  DriverForegroundService._internal();

  bool _isInitialized = false;

  /// Inisialisasi konfigurasi notifikasi foreground service
  Future<void> initialize() async {
    if (kIsWeb) return;
    if (_isInitialized) return;
    if (!Platform.isAndroid) return;

    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'rbt_driver_foreground_channel',
        channelName: 'RBT Driver Layanan Aktif',
        channelDescription:
            'Menjaga aplikasi driver tetap aktif memantau orderan baru di latar belakang',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(25000),
        autoRunOnBoot: false,
        autoRunOnMyPackageReplaced: false,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );

    _isInitialized = true;
    debugPrint('[DriverForegroundService] Terinisialisasi.');
  }

  /// Memulai foreground service saat driver Online
  Future<bool> startService() async {
    if (kIsWeb || !Platform.isAndroid) return true;

    try {
      if (!_isInitialized) {
        await initialize();
      }

      final isRunning = await FlutterForegroundTask.isRunningService;
      if (isRunning) {
        debugPrint('[DriverForegroundService] Service sudah berjalan.');
        return true;
      }

      // Pastikan izin notifikasi diizinkan di Android 13+
      final notificationPermission =
          await FlutterForegroundTask.checkNotificationPermission();
      if (notificationPermission != NotificationPermission.granted) {
        await FlutterForegroundTask.requestNotificationPermission();
      }

      final startResult = await FlutterForegroundTask.startService(
        serviceId: 256,
        notificationTitle: 'RBT Driver: Siap Terima Order 🟢',
        notificationText: 'Radar pesanan aktif memantau di latar belakang...',
        callback: driverForegroundCallback,
      );

      debugPrint('[DriverForegroundService] startService: $startResult');
      return true;
    } catch (e) {
      debugPrint('[DriverForegroundService] Gagal memulai service: $e');
      return false;
    }
  }

  /// Menghentikan foreground service saat driver Offline
  Future<bool> stopService() async {
    if (kIsWeb || !Platform.isAndroid) return true;

    try {
      final isRunning = await FlutterForegroundTask.isRunningService;
      if (!isRunning) return true;

      final stopResult = await FlutterForegroundTask.stopService();
      debugPrint('[DriverForegroundService] stopService: $stopResult');
      return true;
    } catch (e) {
      debugPrint('[DriverForegroundService] Gagal menghentikan service: $e');
      return false;
    }
  }

  /// Meminta izin pengabaian optimasi baterai (Doze Mode exception)
  Future<void> requestIgnoreBatteryOptimization() async {
    if (kIsWeb || !Platform.isAndroid) return;

    try {
      final isIgnoring = await FlutterForegroundTask.isIgnoringBatteryOptimizations;
      if (!isIgnoring) {
        await FlutterForegroundTask.requestIgnoreBatteryOptimization();
      }
    } catch (e) {
      debugPrint('[DriverForegroundService] Gagal request battery optimization: $e');
    }
  }
}
