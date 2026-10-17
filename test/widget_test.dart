import 'package:flutter_test/flutter_test.dart';
import 'package:rbt_driver/models/driver_profile_model.dart';
import 'package:rbt_driver/models/driver_order_model.dart';

void main() {
  group('Driver Models Unit Tests', () {
    test('DriverProfileModel empty and custom values test', () {
      final emptyProfile = DriverProfileModel.empty();
      expect(emptyProfile.hasAccount, isFalse);
      expect(emptyProfile.isOnline, isFalse);

      const customProfile = DriverProfileModel(
        id: 'driver-pidie-01',
        name: 'Fauzan Mitra',
        phone: '081234567890',
        plateNumber: 'BL 1234 AB',
        vehicleType: 'Honda Vario 160',
        photoUrl: 'preset:helmet',
        rating: 5.0,
        isOnline: true,
      );

      expect(customProfile.name, equals('Fauzan Mitra'));
      expect(customProfile.plateNumber, equals('BL 1234 AB'));
      expect(customProfile.hasAccount, isTrue);
      expect(customProfile.hasValidVehicle, isTrue);
      expect(customProfile.isOnline, isTrue);
    });

    test('DriverOrderModel parsing and formatting test', () {
      final orderMap = {
        'id': 'test-uuid-1',
        'order_code': 'RBT-MTR-999',
        'customer_name': 'Teuku Rian',
        'customer_phone': '081234567890',
        'order_type': 'ride',
        'pickup_address': 'Pasar Sigli',
        'pickup_lat': 5.38,
        'pickup_lng': 95.96,
        'destination_address': 'Simpang Empat',
        'destination_lat': 5.37,
        'destination_lng': 95.97,
        'distance_km': 2.5,
        'delivery_fee': 15000,
        'total_fee': 15000,
        'status': 'searching',
        'created_at': DateTime.now().toIso8601String(),
      };

      final order = DriverOrderModel.fromMap(orderMap);
      expect(order.orderCode, equals('RBT-MTR-999'));
      expect(order.isSearching, isTrue);
      expect(order.formattedTotalFee, contains('15.000'));
      expect(order.typeLabel, equals('RBT Motor'));
    });
  });
}
