import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:intl/intl.dart';
import '../models/driver_order_model.dart';

/// Layanan Notifikasi Smartphone Sistem (Notification Panel / Status Bar Android)
/// Menampilkan notifikasi orderan masuk langsung di panel notifikasi smartphone driver
/// tanpa memblokir atau menampilkan banner besar di dalam layar aplikasi.
class DriverNotificationService {
  static final DriverNotificationService instance = DriverNotificationService._internal();
  factory DriverNotificationService() => instance;
  DriverNotificationService._internal();

  final FlutterLocalNotificationsPlugin _notificationsPlugin =
      FlutterLocalNotificationsPlugin();

  bool _isInitialized = false;

  // ID Channel khusus orderan masuk dengan prioritas MAX
  static const String channelId = 'rbt_incoming_orders';
  static const String channelName = 'Orderan Masuk RBT Driver';
  static const String channelDescription =
      'Notifikasi prioritas tinggi saat ada orderan masuk baru untuk mitra driver RBT Pidie';

  /// Inisialisasi plugin notifikasi dan channel Android
  Future<void> initialize({void Function(String? orderCode)? onSelectNotification}) async {
    if (kIsWeb) return;
    if (_isInitialized) return;

    try {
      const AndroidInitializationSettings androidSettings =
          AndroidInitializationSettings('@mipmap/ic_launcher');

      const DarwinInitializationSettings darwinSettings =
          DarwinInitializationSettings(
        requestAlertPermission: true,
        requestBadgePermission: true,
        requestSoundPermission: true,
      );

      const InitializationSettings initSettings = InitializationSettings(
        android: androidSettings,
        iOS: darwinSettings,
      );

      await _notificationsPlugin.initialize(
        settings: initSettings,
        onDidReceiveNotificationResponse: (NotificationResponse response) {
          final payload = response.payload;
          if (payload != null && onSelectNotification != null) {
            onSelectNotification(payload);
          }
        },
      );

      // Buat Android Notification Channel dengan Priority High & Max Importance
      if (Platform.isAndroid) {
        final androidImplementation = _notificationsPlugin
            .resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin>();

        if (androidImplementation != null) {
          await androidImplementation.createNotificationChannel(
            const AndroidNotificationChannel(
              channelId,
              channelName,
              description: channelDescription,
              importance: Importance.max,
              playSound: true,
              enableVibration: true,
              showBadge: true,
            ),
          );

          // Minta izin notifikasi di Android 13+
          await androidImplementation.requestNotificationsPermission();
        }
      }

      _isInitialized = true;
      debugPrint('[DriverNotificationService] Berhasil diinisialisasi.');
    } catch (e) {
      debugPrint('[DriverNotificationService] Gagal inisialisasi: $e');
    }
  }

  /// Menampilkan notifikasi pesanan masuk baru di PANEL NOTIFIKASI SMARTPHONE
  Future<void> showIncomingOrderNotification(DriverOrderModel order, {double? distanceKm}) async {
    if (kIsWeb) return;
    if (!_isInitialized) {
      await initialize();
    }

    try {
      final orderTypeName = _getOrderTypeName(order.orderType);
      final feeFormatted = NumberFormat.currency(
        locale: 'id_ID',
        symbol: 'Rp ',
        decimalDigits: 0,
      ).format(order.deliveryFee);

      final distText = distanceKm != null
          ? ' • ${distanceKm.toStringAsFixed(1)} km dari Anda'
          : ' • ${order.distanceKm.toStringAsFixed(1)} km';

      final title = '🔔 Orderan Masuk: $orderTypeName ($feeFormatted)';
      final body = '💰 Ongkir: $feeFormatted$distText\n📍 Jemput: ${order.pickupAddress}\n🏁 Antar: ${order.destinationAddress}';

      final bigTextStyleInformation = BigTextStyleInformation(
        '💰 Ongkir: $feeFormatted$distText\n'
        '📍 Titik Jemput: ${order.pickupAddress}\n'
        '🏁 Tujuan Antar: ${order.destinationAddress}'
        '${order.isFood && order.restaurantName != null ? '\n🍴 Tempat Makanan: ${order.restaurantName}' : ''}',
        contentTitle: title,
        summaryText: 'Order #${order.orderCode}',
      );

      final androidDetails = AndroidNotificationDetails(
        channelId,
        channelName,
        channelDescription: channelDescription,
        importance: Importance.max,
        priority: Priority.high,
        ticker: 'Orderan Baru Masuk!',
        styleInformation: bigTextStyleInformation,
        category: AndroidNotificationCategory.call,
        autoCancel: true,
        fullScreenIntent: true,
        visibility: NotificationVisibility.public,
        color: const Color(0xFF0D47A1),
      );

      const darwinDetails = DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
      );

      final notificationDetails = NotificationDetails(
        android: androidDetails,
        iOS: darwinDetails,
      );

      // Gunakan hash dari orderCode sebagai notification id
      final notificationId = order.orderCode.hashCode.abs() % 100000;

      await _notificationsPlugin.show(
        id: notificationId,
        title: title,
        body: body,
        notificationDetails: notificationDetails,
        payload: order.orderCode,
      );

      debugPrint('[DriverNotificationService] Notifikasi order #${order.orderCode} berhasil dikirim ke panel notifikasi smartphone.');
    } catch (e) {
      debugPrint('[DriverNotificationService] Gagal menampilkan notifikasi: $e');
    }
  }

  /// Menghapus notifikasi spesifik saat order diklaim / selesai
  Future<void> cancelOrderNotification(String orderCode) async {
    try {
      final notificationId = orderCode.hashCode.abs() % 100000;
      await _notificationsPlugin.cancel(id: notificationId);
    } catch (_) {}
  }

  /// Menghapus semua notifikasi
  Future<void> cancelAll() async {
    try {
      await _notificationsPlugin.cancelAll();
    } catch (_) {}
  }

  String _getOrderTypeName(String type) {
    switch (type.toLowerCase()) {
      case 'food':
        return 'RBT Makanan';
      case 'express':
        return 'RBT Express';
      case 'ride':
      default:
        return 'RBT Motor';
    }
  }
}
