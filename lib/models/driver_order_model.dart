import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';

/// Model representasi data pesanan pada sisi aplikasi Driver
class DriverOrderModel {
  final String id;
  final String orderCode;
  final String customerName;
  final String customerPhone;
  final String orderType; // 'ride', 'food', 'express'
  final String pickupAddress;
  final double pickupLat;
  final double pickupLng;
  final String destinationAddress;
  final double destLat;
  final double destLng;
  final double distanceKm;
  final int deliveryFee;
  final int foodFee;
  final int totalFee;
  final String status;
  final String? foodNotes;
  final String? restaurantName;
  final DateTime createdAt;

  const DriverOrderModel({
    required this.id,
    required this.orderCode,
    required this.customerName,
    required this.customerPhone,
    required this.orderType,
    required this.pickupAddress,
    required this.pickupLat,
    required this.pickupLng,
    required this.destinationAddress,
    required this.destLat,
    required this.destLng,
    required this.distanceKm,
    required this.deliveryFee,
    this.foodFee = 0,
    required this.totalFee,
    required this.status,
    this.foodNotes,
    this.restaurantName,
    required this.createdAt,
  });

  bool get isFood => orderType == 'food';
  LatLng get pickupLatLng => LatLng(pickupLat, pickupLng);
  LatLng get destLatLng => LatLng(destLat, destLng);

  bool get isSearching => status == 'searching';
  bool get isAssigned => status == 'driverAssigned';
  bool get isHeading => status == 'headingToLocation';
  bool get isDelivering => status == 'delivering';
  bool get isCompleted => status == 'completed';
  bool get isCancelled => status == 'cancelled';

  String get typeLabel {
    if (orderType == 'food') return 'RBT Makanan';
    if (orderType == 'express') return 'RBT Express';
    return 'RBT Motor';
  }

  /// Potongan biaya bagi hasil platform aplikasi RBT (5% dari ongkir)
  int get platformFee => (deliveryFee * 0.05).round();

  /// Pendapatan / omzet bersih mitra driver setelah dipotong platform 5%
  int get netEarnings => deliveryFee - platformFee;

  String get formattedTotalFee {
    try {
      final formatter = NumberFormat.currency(
        locale: 'id_ID',
        symbol: 'Rp ',
        decimalDigits: 0,
      );
      return formatter.format(totalFee);
    } catch (_) {
      return 'Rp ${totalFee.toString().replaceAllMapped(RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'), (Match m) => '${m[1]}.')}';
    }
  }

  DriverOrderModel copyWith({
    String? id,
    String? orderCode,
    String? customerName,
    String? customerPhone,
    String? orderType,
    String? pickupAddress,
    double? pickupLat,
    double? pickupLng,
    String? destinationAddress,
    double? destLat,
    double? destLng,
    double? distanceKm,
    int? deliveryFee,
    int? foodFee,
    int? totalFee,
    String? status,
    String? foodNotes,
    String? restaurantName,
    DateTime? createdAt,
  }) {
    return DriverOrderModel(
      id: id ?? this.id,
      orderCode: orderCode ?? this.orderCode,
      customerName: customerName ?? this.customerName,
      customerPhone: customerPhone ?? this.customerPhone,
      orderType: orderType ?? this.orderType,
      pickupAddress: pickupAddress ?? this.pickupAddress,
      pickupLat: pickupLat ?? this.pickupLat,
      pickupLng: pickupLng ?? this.pickupLng,
      destinationAddress: destinationAddress ?? this.destinationAddress,
      destLat: destLat ?? this.destLat,
      destLng: destLng ?? this.destLng,
      distanceKm: distanceKm ?? this.distanceKm,
      deliveryFee: deliveryFee ?? this.deliveryFee,
      foodFee: foodFee ?? this.foodFee,
      totalFee: totalFee ?? this.totalFee,
      status: status ?? this.status,
      foodNotes: foodNotes ?? this.foodNotes,
      restaurantName: restaurantName ?? this.restaurantName,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  factory DriverOrderModel.fromMap(Map<String, dynamic> map) {
    double parseDouble(dynamic v, double fallback) {
      if (v == null) return fallback;
      if (v is num) return v.toDouble();
      return double.tryParse(v.toString()) ?? fallback;
    }

    int parseInt(dynamic v, int fallback) {
      if (v == null) return fallback;
      if (v is num) return v.toInt();
      return int.tryParse(v.toString()) ?? fallback;
    }

    return DriverOrderModel(
      id: map['id']?.toString() ?? '',
      orderCode: map['order_code']?.toString() ?? '',
      customerName: map['customer_name']?.toString() ?? 'Pelanggan RBT',
      customerPhone: map['customer_phone']?.toString() ?? '',
      orderType: map['order_type']?.toString() ?? 'ride',
      pickupAddress: map['pickup_address']?.toString() ?? 'Lokasi Jemput',
      pickupLat: parseDouble(map['pickup_lat'], 5.3815),
      pickupLng: parseDouble(map['pickup_lng'], 95.9608),
      destinationAddress: map['destination_address']?.toString() ?? 'Lokasi Tujuan',
      destLat: parseDouble(map['destination_lat'], 5.3780),
      destLng: parseDouble(map['destination_lng'], 95.9640),
      distanceKm: parseDouble(map['distance_km'], 1.0),
      deliveryFee: parseInt(map['delivery_fee'], 5000),
      foodFee: parseInt(map['food_fee'], 0),
      totalFee: parseInt(map['total_fee'], 5000),
      status: map['status']?.toString() ?? 'searching',
      foodNotes: map['food_notes']?.toString(),
      restaurantName: map['restaurant_name']?.toString(),
      createdAt: map['created_at'] != null
          ? DateTime.tryParse(map['created_at'].toString())?.toLocal() ?? DateTime.now()
          : DateTime.now(),
    );
  }
}
