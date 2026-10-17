class DriverProfileModel {
  final String id;
  final String name;
  final String phone;
  final String plateNumber;
  final String vehicleType;
  final String photoUrl;
  final double rating;
  final int totalTrips;
  final bool isOnline;
  final int depositBalance;

  const DriverProfileModel({
    required this.id,
    required this.name,
    required this.phone,
    required this.plateNumber,
    required this.vehicleType,
    this.photoUrl = '',
    this.rating = 5.0,
    this.totalTrips = 0,
    this.isOnline = true,
    this.depositBalance = 0,
  });

  bool get hasValidVehicle => plateNumber.isNotEmpty && vehicleType.isNotEmpty;
  bool get hasAccount => id.isNotEmpty && phone.isNotEmpty;

  factory DriverProfileModel.empty() {
    return const DriverProfileModel(
      id: '',
      name: 'Mitra RBT',
      phone: '',
      plateNumber: '',
      vehicleType: '',
      photoUrl: '',
      rating: 5.0,
      totalTrips: 0,
      isOnline: false,
      depositBalance: 0,
    );
  }

  factory DriverProfileModel.defaultProfile() {
    return DriverProfileModel.empty();
  }

  DriverProfileModel copyWith({
    String? id,
    String? name,
    String? phone,
    String? plateNumber,
    String? vehicleType,
    String? photoUrl,
    double? rating,
    int? totalTrips,
    bool? isOnline,
    int? depositBalance,
  }) {
    return DriverProfileModel(
      id: id ?? this.id,
      name: name ?? this.name,
      phone: phone ?? this.phone,
      plateNumber: plateNumber ?? this.plateNumber,
      vehicleType: vehicleType ?? this.vehicleType,
      photoUrl: photoUrl ?? this.photoUrl,
      rating: rating ?? this.rating,
      totalTrips: totalTrips ?? this.totalTrips,
      isOnline: isOnline ?? this.isOnline,
      depositBalance: depositBalance ?? this.depositBalance,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'phone': phone,
      'plateNumber': plateNumber,
      'vehicleType': vehicleType,
      'photoUrl': photoUrl,
      'rating': rating,
      'totalTrips': totalTrips,
      'isOnline': isOnline,
      'depositBalance': depositBalance,
      'deposit_balance': depositBalance,
    };
  }

  factory DriverProfileModel.fromJson(Map<String, dynamic> json) {
    double parseRating(dynamic v) {
      if (v == null) return 5.0;
      if (v is num) return v.toDouble();
      return double.tryParse(v.toString()) ?? 5.0;
    }

    int parseTrips(dynamic v) {
      if (v == null) return 0;
      if (v is int) return v;
      if (v is num) return v.toInt();
      return int.tryParse(v.toString()) ?? 0;
    }

    int parseDeposit(dynamic v) {
      if (v == null) return 0;
      if (v is int) return v;
      if (v is num) return v.toInt();
      return int.tryParse(v.toString()) ?? 0;
    }

    bool parseOnline(dynamic v) {
      if (v == null) return false;
      if (v is bool) return v;
      if (v is num) return v != 0;
      final s = v.toString().toLowerCase().trim();
      return s == 'true' || s == '1';
    }

    return DriverProfileModel(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? json['nickname']?.toString() ?? 'Mitra RBT Pidie',
      phone: json['phone']?.toString() ?? '',
      plateNumber: json['plateNumber']?.toString() ?? json['plate_number']?.toString() ?? '',
      vehicleType: json['vehicleType']?.toString() ?? json['vehicle_type']?.toString() ?? '',
      photoUrl: json['photoUrl']?.toString() ?? json['photo_url']?.toString() ?? '',
      rating: parseRating(json['rating']),
      totalTrips: parseTrips(json['totalTrips'] ?? json['total_trips']),
      isOnline: parseOnline(json['isOnline'] ?? json['is_online']),
      depositBalance: parseDeposit(json['depositBalance'] ?? json['deposit_balance']),
    );
  }
}
