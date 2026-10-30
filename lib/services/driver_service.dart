import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/driver_order_model.dart';
import '../models/driver_profile_model.dart';
import 'driver_foreground_service.dart';
import 'driver_network_service.dart';
import 'driver_safe_error_handler.dart';

/// Layanan Sentral Khusus Driver RBT Online Pidie
/// Mengelola Autentikasi Driver, Radar Order Realtime, Klaim Pesanan, dan Riwayat Transaksi
class DriverService {
  static final DriverService instance = DriverService._internal();
  factory DriverService() => instance;
  DriverService._internal();

  static const String supabaseUrl = String.fromEnvironment(
    'SUPABASE_URL',
    defaultValue: 'https://fmmvtzwigwgfsbmqbqml.supabase.co',
  );
  static const String supabaseAnonKey = String.fromEnvironment(
    'SUPABASE_ANON_KEY',
    defaultValue: 'sb_publishable_1tdhGEJNmf8TDU2C__KXTQ_xpn54beP',
  );

  DriverProfileModel _profile = DriverProfileModel.empty();
  DriverProfileModel get profile => _profile;
  final ValueNotifier<DriverProfileModel> profileNotifier =
      ValueNotifier<DriverProfileModel>(DriverProfileModel.empty());

  bool _isInitialized = false;
  bool get isInitialized => _isInitialized;

  SupabaseClient? get client {
    try {
      return Supabase.instance.client;
    } catch (_) {
      return null;
    }
  }

  User? get currentUser => client?.auth.currentUser;
  bool get isLoggedIn => currentUser != null;

  /// Membersihkan format nomor telepon
  static String cleanPhone(String phone) {
    String cleaned = phone.replaceAll(RegExp(r'[^0-9]'), '');
    if (cleaned.startsWith('62')) {
      cleaned = '0${cleaned.substring(2)}';
    }
    return cleaned;
  }

  /// Validasi nomor HP standar Indonesia (08xx, 10-14 digit)
  static bool isValidIndonesianPhone(String input) {
    final cleaned = cleanPhone(input);
    final regex = RegExp(r'^08[1-9][0-9]{7,11}$');
    return regex.hasMatch(cleaned);
  }

  /// Mengonversi nomor HP menjadi email internal Supabase Auth
  /// Format: $cleanedPhone@rbtpidie.app
  static String phoneToAuthEmail(String phone) {
    final cleaned = cleanPhone(phone);
    return '$cleaned@rbtpidie.app';
  }

  /// Inisialisasi Supabase dan muat data profil driver lokal
  Future<void> initialize() async {
    try {
      await Supabase.initialize(
        url: supabaseUrl,
        publishableKey: supabaseAnonKey,
      );
      _isInitialized = true;
    } catch (e) {
      debugPrint('Supabase already initialized or note: $e');
      _isInitialized = true;
    }

    // Dengarkan perubahan status autentikasi Supabase secara global
    client?.auth.onAuthStateChange.listen((data) {
      if (data.session == null) {
        // Jika sesi habis atau signed out, pastikan foreground service mati dan profil dinetralkan
        DriverForegroundService.instance.stopService();
        if (_profile.id.isNotEmpty) {
          _profile = DriverProfileModel.empty();
          profileNotifier.value = _profile;
        }
      }
    });

    // 1. Muat data profil dari penyimpanan lokal
    await loadProfile();

    // 2. Jika sesi login aktif, sinkronkan profil dari cloud
    if (isLoggedIn) {
      await fetchDriverProfile();
    }
  }

  /// Memuat profil driver dari berkas lokal
  Future<void> loadProfile() async {
    if (kIsWeb) return;
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/.driver_profile.json');
      if (await file.exists()) {
        final content = await file.readAsString();
        final data = jsonDecode(content) as Map<String, dynamic>;
        _profile = DriverProfileModel.fromJson(data);
        profileNotifier.value = _profile;
      }
    } catch (e) {
      debugPrint('Gagal muat profil driver lokal: $e');
    }
  }

  /// Menyimpan profil driver secara persisten (lokal & cloud jika login)
  Future<void> saveProfile(DriverProfileModel newProfile) async {
    _profile = newProfile;
    profileNotifier.value = newProfile;
    if (!kIsWeb) {
      try {
        final dir = await getApplicationDocumentsDirectory();
        final file = File('${dir.path}/.driver_profile.json');
        await file.writeAsString(jsonEncode(_profile.toJson()));
      } catch (e) {
        debugPrint('Gagal simpan profil driver lokal: $e');
      }
    }

    // Sinkronkan ke Supabase jika login
    final c = client;
    final user = currentUser;
    if (c != null && user != null) {
      try {
        await c.auth.updateUser(UserAttributes(data: {
          'nickname': newProfile.name,
          'phone': newProfile.phone,
          'plate_number': newProfile.plateNumber,
          'vehicle_type': newProfile.vehicleType,
          'photo_url': newProfile.photoUrl,
          'role': 'driver',
        }));

        // 1. Simpan ke tabel khusus public.drivers
        try {
          await c.from('drivers').update({
            'driver_name': newProfile.name,
            'phone': cleanPhone(newProfile.phone),
            'plate_number': newProfile.plateNumber,
            'vehicle_type': newProfile.vehicleType,
            'photo_url': newProfile.photoUrl,
            'is_online': newProfile.isOnline,
            'rating': newProfile.rating,
            'status': 'active',
          }).eq('id', user.id);
        } catch (e) {
          try {
            await c.from('drivers').upsert({
              'id': user.id,
              'driver_name': newProfile.name,
              'phone': cleanPhone(newProfile.phone),
              'plate_number': newProfile.plateNumber,
              'vehicle_type': newProfile.vehicleType,
              'photo_url': newProfile.photoUrl,
              'is_online': newProfile.isOnline,
              'rating': newProfile.rating,
              'status': 'active',
            });
          } catch (e2) {
            debugPrint('Catatan upsert public.drivers: $e2');
          }
        }

        // 2. Simpan juga ke tabel public.profiles untuk kompatibilitas
        try {
          await c.from('profiles').update({
            'phone': cleanPhone(newProfile.phone),
            'nickname': newProfile.name,
            'role': 'driver',
            'plate_number': newProfile.plateNumber,
            'vehicle_type': newProfile.vehicleType,
            'photo_url': newProfile.photoUrl,
          }).eq('id', user.id);
        } catch (_) {
          try {
            await c.from('profiles').upsert({
              'id': user.id,
              'phone': cleanPhone(newProfile.phone),
              'nickname': newProfile.name,
              'role': 'driver',
              'plate_number': newProfile.plateNumber,
              'vehicle_type': newProfile.vehicleType,
              'photo_url': newProfile.photoUrl,
            });
          } catch (_) {}
        }
      } catch (e) {
        debugPrint('Catatan update user cloud: $e');
      }
    }
  }

  /// Mengunggah file foto profil mitra driver ke Supabase Storage (bucket: driver-photos)
  /// dan mengembalikan URL publik agar dapat ditampilkan oleh pelanggan & admin
  Future<String?> uploadDriverPhoto(Uint8List bytes, {String fileExt = 'jpg'}) async {
    final c = client;
    final user = currentUser;
    if (c == null || user == null) return null;

    try {
      final fileName = 'driver_${user.id}_${DateTime.now().millisecondsSinceEpoch}.$fileExt';
      final filePath = '${user.id}/$fileName';

      await c.storage.from('driver-photos').uploadBinary(
        filePath,
        bytes,
        fileOptions: FileOptions(
          contentType: 'image/$fileExt',
          upsert: true,
        ),
      );

      final publicUrl = c.storage.from('driver-photos').getPublicUrl(filePath);
      debugPrint('[DriverStorage] Berhasil unggah foto driver: $publicUrl');
      return publicUrl;
    } catch (e) {
      debugPrint('[DriverStorage] Gagal mengunggah foto profil: $e');
      return null;
    }
  }

  /// Mengambil profil driver terbaru langsung dari Supabase via select (tabel public.drivers & public.profiles)
  Future<DriverProfileModel?> fetchDriverProfile() async {
    final c = client;
    if (c == null) return null;
    final user = currentUser;

    try {
      final meta = user?.userMetadata ?? {};
      String name = meta['nickname']?.toString() ?? meta['name']?.toString() ?? '';
      String phone = meta['phone']?.toString() ?? _profile.phone;
      String plate = meta['plate_number']?.toString() ?? _profile.plateNumber;
      String vehicle = meta['vehicle_type']?.toString() ?? _profile.vehicleType;
      String photo = meta['photo_url']?.toString() ?? _profile.photoUrl;
      double rating = _profile.rating > 0 ? _profile.rating : 5.0;
      int totalTrips = _profile.totalTrips;
      bool isOnline = _profile.isOnline;
      int depositBalance = _profile.depositBalance;

      // 1. Prioritaskan pembacaan via SELECT dari tabel khusus public.drivers
      try {
        Map<String, dynamic>? driverRow;
        if (user != null) {
          try {
            driverRow = await c
                .from('drivers')
                .select()
                .eq('id', user.id)
                .maybeSingle();
          } catch (_) {}
        }

        // Jika tidak ditemukan by id, coba cari by phone
        if (driverRow == null && phone.isNotEmpty) {
          final cleaned = cleanPhone(phone);
          final altPhone = cleaned.startsWith('0')
              ? '62${cleaned.substring(1)}'
              : (cleaned.startsWith('62') ? '0${cleaned.substring(2)}' : cleaned);
          try {
            driverRow = await c
                .from('drivers')
                .select()
                .or('phone.eq.$cleaned,phone.eq.$altPhone')
                .limit(1)
                .maybeSingle();
          } catch (_) {}
        }

        if (driverRow != null) {
          if (driverRow['driver_name'] != null && driverRow['driver_name'].toString().isNotEmpty) {
            name = driverRow['driver_name'].toString();
          }
          if (driverRow['phone'] != null && driverRow['phone'].toString().isNotEmpty) {
            phone = driverRow['phone'].toString();
          }
          if (driverRow['plate_number'] != null && driverRow['plate_number'].toString().isNotEmpty) {
            plate = driverRow['plate_number'].toString();
          }
          if (driverRow['vehicle_type'] != null && driverRow['vehicle_type'].toString().isNotEmpty) {
            vehicle = driverRow['vehicle_type'].toString();
          }
          if (driverRow['photo_url'] != null && driverRow['photo_url'].toString().isNotEmpty) {
            photo = driverRow['photo_url'].toString();
          }
          if (driverRow['rating'] != null) {
            final r = driverRow['rating'];
            rating = (r is num) ? r.toDouble() : (double.tryParse(r.toString()) ?? 5.0);
          }
          if (driverRow['total_trips'] != null) {
            final t = driverRow['total_trips'];
            totalTrips = (t is num) ? t.toInt() : (int.tryParse(t.toString()) ?? 0);
          }
          if (driverRow['is_online'] != null) {
            final o = driverRow['is_online'];
            if (o is bool) {
              isOnline = o;
            } else if (o is num) {
              isOnline = o != 0;
            } else {
              final s = o.toString().toLowerCase().trim();
              isOnline = s == 'true' || s == '1';
            }
          }
          if (driverRow['deposit_balance'] != null) {
            final d = driverRow['deposit_balance'];
            depositBalance = (d is num) ? d.toInt() : (int.tryParse(d.toString()) ?? 0);
          }
        }
      } catch (e) {
        debugPrint('Catatan baca public.drivers: $e');
      }

      // 2. Fallback ke tabel public.profiles via SELECT jika data nama/nomor belum ditemukan
      if (name.isEmpty || phone.isEmpty) {
        try {
          Map<String, dynamic>? profileRow;
          if (user != null) {
            try {
              profileRow = await c
                  .from('profiles')
                  .select()
                  .eq('id', user.id)
                  .maybeSingle();
            } catch (_) {}
          }

          if (profileRow == null && phone.isNotEmpty) {
            final cleaned = cleanPhone(phone);
            final altPhone = cleaned.startsWith('0')
                ? '62${cleaned.substring(1)}'
                : (cleaned.startsWith('62') ? '0${cleaned.substring(2)}' : cleaned);
            try {
              profileRow = await c
                  .from('profiles')
                  .select()
                  .or('phone.eq.$cleaned,phone.eq.$altPhone')
                  .limit(1)
                  .maybeSingle();
            } catch (_) {}
          }

          if (profileRow != null) {
            if (name.isEmpty) name = profileRow['nickname']?.toString() ?? '';
            if (phone.isEmpty) phone = profileRow['phone']?.toString() ?? '';
            if (plate.isEmpty) plate = profileRow['plate_number']?.toString() ?? '';
            if (vehicle.isEmpty) vehicle = profileRow['vehicle_type']?.toString() ?? '';
            if (photo.isEmpty) photo = profileRow['photo_url']?.toString() ?? '';
          }
        } catch (_) {}
      }

      // Bangun profil terbaru yang disinkronkan
      final updated = _profile.copyWith(
        id: user?.id ?? _profile.id,
        name: name.isNotEmpty ? name : (_profile.name.isNotEmpty ? _profile.name : 'Mitra RBT'),
        phone: phone.isNotEmpty ? phone : _profile.phone,
        plateNumber: plate.isNotEmpty ? plate : _profile.plateNumber,
        vehicleType: vehicle.isNotEmpty ? vehicle : _profile.vehicleType,
        photoUrl: photo.isNotEmpty ? photo : _profile.photoUrl,
        rating: rating,
        totalTrips: totalTrips,
        isOnline: isOnline,
        depositBalance: depositBalance,
      );

      _profile = updated;
      profileNotifier.value = updated;
      await saveProfile(updated);
      return updated;
    } catch (e) {
      debugPrint('Error fetch driver profile: $e');
      return _profile;
    }
  }

  /// Memeriksa apakah pengguna berstatus mitra driver yang sah (bukan customer biasa)
  Future<bool> verifyDriverRole() async {
    final c = client;
    final user = currentUser;
    if (c == null || user == null) return false;

    try {
      // 1. Cek keberadaan di tabel drivers
      final driverRow = await c
          .from('drivers')
          .select('id, status')
          .eq('id', user.id)
          .maybeSingle();
      if (driverRow != null) {
        return true;
      }

      // 2. Cek status role di tabel profiles
      final profileRow = await c
          .from('profiles')
          .select('role')
          .eq('id', user.id)
          .maybeSingle();
      if (profileRow != null && profileRow['role'] != null) {
        final r = profileRow['role'].toString().toLowerCase();
        if (r == 'driver') return true;
        if (r == 'customer') return false;
      }

      // 3. Cek user metadata
      final metaRole = user.userMetadata?['role']?.toString().toLowerCase();
      if (metaRole == 'driver') return true;
      if (metaRole == 'customer') return false;
    } catch (e) {
      debugPrint('Error verify driver role: $e');
      if (user.userMetadata?['role'] == 'driver') return true;
    }

    return false;
  }

  /// Masuk (Login) Akun Driver menggunakan No. Handphone / WhatsApp & Kata Sandi
  Future<AuthResponse> signInWithPhone({
    required String phone,
    required String password,
  }) async {
    final c = client;
    if (c == null) throw const AuthException('Koneksi Supabase belum diinisialisasi.');

    final cleaned = cleanPhone(phone);
    if (cleaned.length < 10) {
      throw const AuthException('Nomor handphone tidak valid (minimal 10 digit).');
    }

    final authEmail = phoneToAuthEmail(cleaned);
    final response = await c.auth.signInWithPassword(
      email: authEmail,
      password: password,
    );

    // Filter role akun saat login: pastikan akun berstatus driver
    final isDriver = await verifyDriverRole();
    if (!isDriver) {
      await signOut();
      throw const AuthException(
        'Akun ini terdaftar sebagai Pelanggan. Silakan gunakan aplikasi RBT Online untuk memesan layanan, atau daftar sebagai Mitra Pengemudi.',
      );
    }

    // Sinkronisasi data profil driver setelah login sukses
    await fetchDriverProfile();
    return response;
  }

  /// Mengecek apakah nomor handphone sudah terdaftar di database (tabel drivers atau profiles)
  Future<bool> isPhoneRegistered(String phone) async {
    final c = client;
    if (c == null) return false;

    final cleaned = cleanPhone(phone);
    if (cleaned.length < 10) return false;

    final altPhone = cleaned.startsWith('0')
        ? '62${cleaned.substring(1)}'
        : (cleaned.startsWith('62') ? '0${cleaned.substring(2)}' : cleaned);

    // 1. Coba panggil fungsi database RPC check_phone_exists jika sudah ada
    try {
      final res = await c.rpc('check_phone_exists', params: {'check_phone': cleaned});
      if (res is bool && res == true) return true;
    } catch (_) {}

    // 2. Cek di tabel public.drivers
    try {
      final driver = await c
          .from('drivers')
          .select('id')
          .or('phone.eq.$cleaned,phone.eq.$altPhone')
          .limit(1)
          .maybeSingle();
      if (driver != null) return true;
    } catch (_) {}

    // 3. Cek di tabel public.profiles
    try {
      final profile = await c
          .from('profiles')
          .select('id')
          .or('phone.eq.$cleaned,phone.eq.$altPhone')
          .limit(1)
          .maybeSingle();
      if (profile != null) return true;
    } catch (_) {}

    return false;
  }

  /// Pendaftaran Akun Mitra Driver Baru
  Future<AuthResponse> signUpWithPhone({
    required String name,
    required String phone,
    required String password,
    required String plateNumber,
    required String vehicleType,
    String photoUrl = '',
  }) async {
    final c = client;
    if (c == null) throw const AuthException('Koneksi Supabase belum diinisialisasi.');

    final cleaned = cleanPhone(phone);
    if (cleaned.length < 10) {
      throw const AuthException('Nomor handphone tidak valid (minimal 10 digit).');
    }
    if (password.length < 6) {
      throw const AuthException('Kata sandi minimal 6 karakter.');
    }
    if (plateNumber.trim().isEmpty) {
      throw const AuthException('Nomor plat kendaraan wajib diisi.');
    }
    if (vehicleType.trim().isEmpty) {
      throw const AuthException('Tipe motor / kendaraan wajib diisi.');
    }

    // 1. Cek secara proaktif apakah nomor handphone sudah terdaftar
    final alreadyRegistered = await isPhoneRegistered(cleaned);
    if (alreadyRegistered) {
      throw const AuthException(
        'Nomor WhatsApp ini sudah terdaftar sebagai akun mitra. Silakan gunakan nomor lain atau pilih tab Masuk Driver.',
      );
    }

    final authEmail = phoneToAuthEmail(cleaned);

    // 2. Registrasi Akun di Supabase Auth dengan metadata lengkap
    final response = await c.auth.signUp(
      email: authEmail,
      password: password,
      data: {
        'phone': cleaned,
        'nickname': name.trim(),
        'plate_number': plateNumber.trim().toUpperCase(),
        'vehicle_type': vehicleType.trim(),
        'photo_url': photoUrl.trim(),
        'role': 'driver',
      },
    );

    final user = response.user;
    if (user != null && (user.identities == null || user.identities!.isEmpty)) {
      throw const AuthException(
        'Nomor WhatsApp ini sudah terdaftar. Silakan pilih tab Masuk Driver.',
      );
    }

    // 2. Simpan data ke tabel khusus public.drivers dan public.profiles
    if (user != null) {
      try {
        await c.from('drivers').upsert({
          'id': user.id,
          'driver_name': name.trim(),
          'phone': cleaned,
          'plate_number': plateNumber.trim().toUpperCase(),
          'vehicle_type': vehicleType.trim(),
          'photo_url': photoUrl.trim(),
          'is_online': true,
          'rating': 5.0,
          'status': 'active',
        });
      } catch (e) {
        debugPrint('Catatan insert public.drivers: $e');
      }

      try {
        await c.from('profiles').upsert({
          'id': user.id,
          'phone': cleaned,
          'nickname': name.trim(),
          'role': 'driver',
          'plate_number': plateNumber.trim().toUpperCase(),
          'vehicle_type': vehicleType.trim(),
          'photo_url': photoUrl.trim(),
        });
      } catch (e) {
        debugPrint('Catatan insert public.profiles: $e');
      }

      // 3. Simpan ke model profil lokal
      final newProfile = DriverProfileModel(
        id: user.id,
        name: name.trim(),
        phone: cleaned,
        plateNumber: plateNumber.trim().toUpperCase(),
        vehicleType: vehicleType.trim(),
        photoUrl: photoUrl.trim(),
        rating: 5.0,
        isOnline: true,
      );
      await saveProfile(newProfile);
    }

    return response;
  }

  /// Keluar (Logout) dari Akun Driver
  Future<void> signOut() async {
    // 1. Matikan foreground background service jika sedang berjalan
    DriverForegroundService.instance.stopService();

    final c = client;
    final user = currentUser;
    if (c != null && user != null) {
      // 2. Set status offline di database sebelum sesi ditutup
      try {
        await c.from('drivers').update({
          'is_online': false,
          'updated_at': DateTime.now().toIso8601String(),
        }).eq('id', user.id);
      } catch (e) {
        debugPrint('Catatan update is_online saat logout driver: $e');
      }

      // 3. Keluar dari sesi Supabase Auth
      try {
        await c.auth.signOut();
      } catch (e) {
        debugPrint('Catatan signOut Supabase: $e');
      }
    }

    // 4. Reset profil lokal ke kosong dan beritahukan seluruh listener UI
    _profile = DriverProfileModel.empty();
    profileNotifier.value = _profile;

    // 5. Hapus berkas profil lokal di perangkat
    if (!kIsWeb) {
      try {
        final dir = await getApplicationDocumentsDirectory();
        final file = File('${dir.path}/.driver_profile.json');
        if (await file.exists()) {
          await file.delete();
        }
      } catch (_) {}
    }
  }

  /// Mengubah status dinas (Online vs Offline)
  Future<void> setDutyStatus(bool isOnline) async {
    final updated = _profile.copyWith(isOnline: isOnline);
    await saveProfile(updated);

    // Sinkronisasi foreground service di background Android
    if (isOnline) {
      DriverForegroundService.instance.startService();
    } else {
      DriverForegroundService.instance.stopService();
    }

    final c = client;
    final user = currentUser;
    if (c != null && user != null) {
      try {
        await c.from('drivers').update({'is_online': isOnline}).eq('id', user.id);
      } catch (_) {}
    }
  }

  /// Memperbarui koordinat GPS lokasi driver secara real-time
  Future<void> updateDriverLocation(double lat, double lng, {String? activeOrderCode}) async {
    final c = client;
    final user = currentUser;
    if (c == null) return;

    if (user != null) {
      try {
        await c.from('drivers').update({
          'current_lat': lat,
          'current_lng': lng,
        }).eq('id', user.id);
      } catch (_) {}
    }

    if (activeOrderCode != null && activeOrderCode.isNotEmpty) {
      try {
        await c.from('orders').update({
          'driver_lat': lat,
          'driver_lng': lng,
        }).eq('order_code', activeOrderCode);
      } catch (_) {}
    }
  }

  /// DIRECT REST FETCH: Mengambil daftar pesanan yang berstatus 'searching' langsung via REST API
  /// Berfungsi sebagai jaminan pasti agar pesanan tampil meskipun stream realtime ada kendala
  Future<List<DriverOrderModel>> fetchIncomingOrders() async {
    final c = client;
    if (c == null) return [];

    try {
      final response = await c
          .from('orders')
          .select()
          .eq('status', 'searching')
          .order('created_at', ascending: false)
          .limit(50);

      final list = List<Map<String, dynamic>>.from(response);
      return list.map((m) => DriverOrderModel.fromMap(m)).toList();
    } catch (e) {
      debugPrint('Error fetchIncomingOrders REST: $e');
      return [];
    }
  }

  /// REALTIME STREAM RADAR: Mendengarkan pesanan yang sedang mencari driver (status: searching)
  /// Menggunakan filter database eq('status', 'searching') agar pesanan completed/cancelled tidak pernah ditarik ke HP
  Stream<List<DriverOrderModel>> streamIncomingOrders() {
    final c = client;
    if (c == null) return const Stream.empty();

    return c
        .from('orders')
        .stream(primaryKey: ['id'])
        .eq('status', 'searching')
        .order('created_at', ascending: false)
        .map((list) {
      return list
          .map((row) {
            try {
              return DriverOrderModel.fromMap(row);
            } catch (e) {
              debugPrint('Error parse row order: $e');
              return null;
            }
          })
          .whereType<DriverOrderModel>()
          .toList();
    });
  }

  /// STREAM PESANAN AKTIF: Mendapatkan pesanan yang sedang dikerjakan oleh driver ini
  /// Menggunakan filter spesifik driver agar tidak men-stream seluruh database
  Stream<DriverOrderModel?> streamActiveJob() {
    final c = client;
    if (c == null) return const Stream.empty();

    final myPhone = cleanPhone(_profile.phone);
    final user = currentUser;

    Stream<List<Map<String, dynamic>>> orderStream;

    if (user != null) {
      orderStream = c
          .from('orders')
          .stream(primaryKey: ['id'])
          .eq('driver_id', user.id)
          .order('created_at', ascending: false);
    } else if (myPhone.isNotEmpty) {
      orderStream = c
          .from('orders')
          .stream(primaryKey: ['id'])
          .eq('driver_phone', myPhone)
          .order('created_at', ascending: false);
    } else {
      orderStream = c
          .from('orders')
          .stream(primaryKey: ['id'])
          .order('created_at', ascending: false)
          .limit(10);
    }

    return orderStream.map((list) {
      final activeList = list.where((row) {
        final status = row['status']?.toString();
        final isActive = status == 'driverAssigned' ||
            status == 'headingToLocation' ||
            status == 'delivering';
        if (!isActive) return false;

        final driverPhone = cleanPhone(row['driver_phone']?.toString() ?? '');
        return driverPhone.isNotEmpty && (driverPhone == myPhone || driverPhone == _profile.phone);
      }).toList();

      if (activeList.isNotEmpty) {
        try {
          return DriverOrderModel.fromMap(activeList.first);
        } catch (_) {}
      }
      return null;
    });
  }

  /// MENGAMBIL PESANAN AKTIF SEKALI JALAN (REST)
  /// Digunakan untuk validasi bahwa driver tidak boleh mengambil order baru sebelum order pertama selesai
  Future<DriverOrderModel?> getActiveJobOnce() async {
    final c = client;
    if (c == null) return null;

    final myPhone = cleanPhone(_profile.phone);
    final user = currentUser;

    try {
      final response = await c
          .from('orders')
          .select()
          .inFilter('status', ['driverAssigned', 'headingToLocation', 'delivering'])
          .order('created_at', ascending: false)
          .limit(10);

      final list = List<Map<String, dynamic>>.from(response);
      for (final row in list) {
        final driverPhone = cleanPhone(row['driver_phone']?.toString() ?? '');
        final driverId = row['driver_id']?.toString();

        final matchPhone = driverPhone.isNotEmpty && (driverPhone == myPhone || driverPhone == _profile.phone);
        final matchUser = user != null && driverId != null && driverId == user.id;

        if (matchPhone || matchUser) {
          return DriverOrderModel.fromMap(row);
        }
      }
    } catch (e) {
      debugPrint('Error check getActiveJobOnce: $e');
    }
    return null;
  }

  /// KLAIM PESANAN (Terima Order dari Radar)
  /// Menggunakan update atomik untuk memastikan pesanan belum diambil driver lain
  /// Mengembalikan null jika sukses, atau pesan error jika gagal
  Future<String?> claimOrder(String orderCode) async {
    if (!DriverNetworkService.instance.isConnected) {
      return 'Koneksi internet mitra terputus. Harap periksa paket data seluler Anda.';
    }

    final c = client;
    if (c == null) return 'Koneksi Supabase belum terhubung.';

    // ATURAN MITRA: Jika driver belum menyelesaikan pesanan pertama, tidak boleh mengambil pesanan lain
    try {
      final activeJob = await getActiveJobOnce();
      if (activeJob != null && activeJob.orderCode != orderCode) {
        return 'Anda masih memiliki pesanan aktif #${activeJob.orderCode} yang belum selesai. Selesaikan pesanan tersebut terlebih dahulu sebelum mengambil orderan lain.';
      }
    } catch (e) {
      debugPrint('Validasi pesanan aktif di claimOrder dilewati jika ada kendala koneksi: $e');
    }

    // Pastikan data driver valid
    final name = _profile.name.isNotEmpty ? _profile.name : 'Mitra RBT Driver';
    final phone = _profile.phone;
    final plate = _profile.plateNumber.isNotEmpty ? _profile.plateNumber : '-';
    final vehicle = _profile.vehicleType.isNotEmpty ? _profile.vehicleType : 'Sepeda Motor';

    final user = currentUser;
    final driverId = user?.id ?? _profile.id;

    // 1. Prioritaskan pengambilan pesanan secara ATOMIC melalui RPC Supabase
    // Ini mengunci baris (FOR UPDATE), memotong biaya admin 5%, dan memvalidasi kecukupan deposit
    try {
      final rpcResult = await c.rpc('claim_order_with_deposit', params: {
        'p_order_code': orderCode,
        'p_driver_id': driverId,
        'p_driver_name': name,
        'p_driver_phone': phone,
        'p_driver_plate': plate,
        'p_driver_vehicle': vehicle,
      });

      if (rpcResult is Map) {
        final isSuccess = rpcResult['success'] == true;
        if (isSuccess) {
          if (rpcResult['balance_after'] != null) {
            final newBal = (rpcResult['balance_after'] as num).toInt();
            _profile = _profile.copyWith(depositBalance: newBal);
            profileNotifier.value = _profile;
            await saveProfile(_profile);
          }
          return null; // Sukses tanpa error!
        } else {
          // Gagal dengan alasan terstruktur dari database (misal: saldo deposit kurang atau order sudah diambil)
          final msg = rpcResult['message']?.toString() ?? 'Gagal mengambil pesanan.';
          return msg;
        }
      }
    } catch (eRpc) {
      debugPrint('[DriverService] RPC claim_order_with_deposit catatan: $eRpc');
      // Jika RPC belum ada (sebelum SQL dieksekusi), lanjutkan fallback ke update standar
    }

    final updatePayload = <String, dynamic>{
      'status': 'driverAssigned',
      'driver_name': name,
      'driver_phone': phone,
      'driver_plate': plate,
      'driver_vehicle': vehicle,
    };
    if (user != null) {
      updatePayload['driver_id'] = user.id;
    }

    try {
      List<Map<String, dynamic>> list = [];
      try {
        final response = await c
            .from('orders')
            .update(updatePayload)
            .eq('order_code', orderCode)
            .eq('status', 'searching')
            .select();
        list = List<Map<String, dynamic>>.from(response);
      } catch (e) {
        bool shouldRetry = false;
        if (e.toString().contains('driver_id') && updatePayload.containsKey('driver_id')) {
          debugPrint('Kolom driver_id belum ada, mencoba klaim tanpa driver_id...');
          updatePayload.remove('driver_id');
          shouldRetry = true;
        }
        if (e.toString().contains('driver_vehicle') && updatePayload.containsKey('driver_vehicle')) {
          debugPrint('Kolom driver_vehicle belum ada, mencoba klaim tanpa driver_vehicle...');
          updatePayload.remove('driver_vehicle');
          shouldRetry = true;
        }

        if (shouldRetry) {
          try {
            final response = await c
                .from('orders')
                .update(updatePayload)
                .eq('order_code', orderCode)
                .eq('status', 'searching')
                .select();
            list = List<Map<String, dynamic>>.from(response);
          } catch (e2) {
            if (e2.toString().contains('driver_vehicle') && updatePayload.containsKey('driver_vehicle')) {
              updatePayload.remove('driver_vehicle');
              final response = await c
                  .from('orders')
                  .update(updatePayload)
                  .eq('order_code', orderCode)
                  .eq('status', 'searching')
                  .select();
              list = List<Map<String, dynamic>>.from(response);
            } else {
              rethrow;
            }
          }
        } else {
          rethrow;
        }
      }

      if (list.isNotEmpty) {
        return null; // Sukses! (tidak ada error)
      }

      // Jika update 0 baris, periksa penyebab aslinya di database:
      final check = await c
          .from('orders')
          .select('status, driver_name')
          .eq('order_code', orderCode)
          .maybeSingle();

      if (check == null) {
        return 'Pesanan #$orderCode tidak ditemukan atau telah dibatalkan.';
      }

      final currentStatus = check['status']?.toString();
      if (currentStatus != 'searching') {
        final assignedTo = check['driver_name']?.toString();
        if (assignedTo != null && assignedTo.isNotEmpty) {
          return 'Pesanan ini sudah diambil oleh $assignedTo.';
        }
        return 'Pesanan ini sudah tidak berstatus pencarian (status: $currentStatus).';
      }

      return 'Gagal mengambil pesanan. Silakan coba kembali.';
    } catch (e) {
      debugPrint('Error klaim pesanan: ${DriverSafeErrorHandler.sanitize(e.toString())}');
      if (DriverSafeErrorHandler.isNetworkError(e)) {
        return 'Koneksi internet mitra terputus saat mengambil pesanan. Harap periksa jaringan Anda.';
      }
      return 'Gagal mengambil pesanan. Silakan coba kembali.';
    }
  }

  /// UPDATE STATUS PERJALANAN (headingToLocation, delivering, completed)
  Future<bool> updateOrderStatus(String orderCode, String newStatus) async {
    final c = client;
    if (c == null) return false;

    try {
      await c
          .from('orders')
          .update({'status': newStatus})
          .eq('order_code', orderCode);
      return true;
    } catch (e) {
      debugPrint('Error perbarui status pesanan: $e');
      return false;
    }
  }

  /// BATALKAN / LEPAS PESANAN DARURAT
  Future<bool> releaseOrCancelOrder(String orderCode, {bool returnToRadar = true}) async {
    final c = client;
    if (c == null) return false;

    try {
      if (returnToRadar) {
        // Kembalikan ke status searching agar bisa diambil driver lain secara bersih
        await c.from('orders').update({
          'status': 'searching',
          'driver_id': null,
          'driver_name': null,
          'driver_phone': null,
          'driver_plate': null,
          'driver_vehicle': null,
          'driver_lat': null,
          'driver_lng': null,
        }).eq('order_code', orderCode);
      } else {
        await c.from('orders').update({
          'status': 'cancelled',
        }).eq('order_code', orderCode);
      }
      return true;
    } catch (e) {
      debugPrint('Error batalkan pesanan: $e');
      return false;
    }
  }

  /// MENGAMBIL RIWAYAT ORDER SELESAI DRIVER
  Future<List<DriverOrderModel>> fetchDriverHistory() async {
    final c = client;
    if (c == null) return [];

    final myPhone = cleanPhone(_profile.phone);
    if (myPhone.isEmpty) return [];

    final altPhone = myPhone.startsWith('0') ? '62${myPhone.substring(1)}' : myPhone;
    final userId = currentUser?.id;
    final conditions = <String>[
      'driver_phone.eq.$myPhone',
      'driver_phone.eq.$altPhone',
      'driver_phone.eq.${_profile.phone}',
    ];
    if (userId != null && userId.isNotEmpty) {
      conditions.add('driver_id.eq.$userId');
    }

    try {
      final response = await c
          .from('orders')
          .select()
          .or(conditions.join(','))
          .inFilter('status', ['completed', 'cancelled'])
          .order('created_at', ascending: false)
          .limit(300);

      final list = List<Map<String, dynamic>>.from(response);
      return list.map((m) => DriverOrderModel.fromMap(m)).toList();
    } catch (e) {
      debugPrint('Error ambil riwayat driver: $e');
      return [];
    }
  }

  /// MENGHITUNG PENDAPATAN HARI INI
  Future<Map<String, dynamic>> fetchTodaySummary() async {
    final history = await fetchDriverHistory();
    final now = DateTime.now();
    final todayOrders = history.where((o) {
      return o.isCompleted &&
          o.createdAt.year == now.year &&
          o.createdAt.month == now.month &&
          o.createdAt.day == now.day;
    }).toList();

    int totalEarnings = 0;
    double totalKm = 0.0;
    for (final order in todayOrders) {
      totalEarnings += order.netEarnings;
      totalKm += order.distanceKm;
    }

    return {
      'count': todayOrders.length,
      'earnings': totalEarnings,
      'distanceKm': totalKm,
    };
  }

  /// Melakukan Top Up Saldo Deposit Mitra Driver
  Future<bool> topUpDeposit({
    required int amount,
    required String referenceId,
    String paymentMethod = 'qris_midtrans',
  }) async {
    final c = client;
    final user = currentUser;
    final driverId = user?.id ?? _profile.id;
    if (c == null || driverId.isEmpty) {
      debugPrint('[DriverService] Gagal top up: client null atau driverId kosong');
      return false;
    }

    try {
      // 1. Coba eksekusi fungsi RPC atomic
      final res = await c.rpc('topup_driver_deposit', params: {
        'p_driver_id': driverId,
        'p_amount': amount,
        'p_reference_id': referenceId,
        'p_payment_method': paymentMethod,
      });

      if (res is Map && res['success'] == true) {
        final newBal = (res['new_balance'] as num?)?.toInt();
        if (newBal != null) {
          _profile = _profile.copyWith(depositBalance: newBal);
          profileNotifier.value = _profile;
          await saveProfile(_profile);
        }
        return true;
      }
    } catch (e) {
      debugPrint('[DriverService] Catatan RPC topup_driver_deposit: $e');
      // 2. Fallback jika tabel/RPC belum terdaftar
      try {
        final currentBal = _profile.depositBalance;
        final newBal = currentBal + amount;
        await c.from('drivers').update({
          'deposit_balance': newBal,
          'updated_at': DateTime.now().toIso8601String(),
        }).eq('id', driverId);

        _profile = _profile.copyWith(depositBalance: newBal);
        profileNotifier.value = _profile;
        await saveProfile(_profile);
        return true;
      } catch (e2) {
        debugPrint('[DriverService] Fallback top up juga error: $e2');
      }
    }
    return false;
  }

  /// Mengambil daftar riwayat mutasi saldo deposit driver
  Future<List<Map<String, dynamic>>> fetchDepositTransactions() async {
    final c = client;
    final user = currentUser;
    final driverId = user?.id ?? _profile.id;
    if (c == null || driverId.isEmpty) return [];

    try {
      final res = await c
          .from('driver_deposit_transactions')
          .select()
          .eq('driver_id', driverId)
          .order('created_at', ascending: false)
          .limit(50);
      return List<Map<String, dynamic>>.from(res);
    } catch (e) {
      debugPrint('[DriverService] Gagal ambil mutasi deposit: $e');
      return [];
    }
  }
}
