import 'dart:async';
import 'dart:io';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

/// Layanan Pemantau Konektivitas Internet untuk Aplikasi Driver RBT
class DriverNetworkService {
  static final DriverNetworkService instance = DriverNetworkService._internal();
  factory DriverNetworkService() => instance;
  DriverNetworkService._internal();

  final Connectivity _connectivity = Connectivity();
  final ValueNotifier<bool> isConnectedNotifier = ValueNotifier<bool>(true);
  StreamSubscription<List<ConnectivityResult>>? _subscription;

  bool get isConnected => isConnectedNotifier.value;

  void initialize() {
    _checkInitialConnection();
    _subscription = _connectivity.onConnectivityChanged.listen((results) {
      _evaluateConnectivity(results);
    });
  }

  void dispose() {
    _subscription?.cancel();
  }

  Future<void> _checkInitialConnection() async {
    try {
      final results = await _connectivity.checkConnectivity();
      await _evaluateConnectivity(results);
    } catch (_) {
      final hasInternet = await hasInternetAccess();
      isConnectedNotifier.value = hasInternet;
    }
  }

  Future<void> _evaluateConnectivity(List<ConnectivityResult> results) async {
    final isNone = results.isEmpty || results.every((r) => r == ConnectivityResult.none);
    if (isNone) {
      if (isConnectedNotifier.value) {
        isConnectedNotifier.value = false;
      }
      return;
    }

    final hasInternet = await hasInternetAccess();
    if (isConnectedNotifier.value != hasInternet) {
      isConnectedNotifier.value = hasInternet;
    }
  }

  Future<bool> hasInternetAccess() async {
    if (kIsWeb) {
      return true;
    }
    try {
      final lookup = await InternetAddress.lookup('1.1.1.1')
          .timeout(const Duration(seconds: 3));
      if (lookup.isNotEmpty && lookup[0].rawAddress.isNotEmpty) {
        return true;
      }
    } catch (_) {}

    try {
      final lookupSupabase = await InternetAddress.lookup('fmmvtzwigwgfsbmqbqml.supabase.co')
          .timeout(const Duration(seconds: 3));
      return lookupSupabase.isNotEmpty && lookupSupabase[0].rawAddress.isNotEmpty;
    } catch (_) {
      return false;
    }
  }
}
