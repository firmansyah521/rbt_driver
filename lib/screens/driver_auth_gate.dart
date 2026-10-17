import 'dart:async';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../services/driver_service.dart';
import 'driver_auth_screen.dart';
import 'driver_main_screen.dart';

/// Gerbang Autentikasi Pengemudi (Driver Auth Gate)
/// Memastikan pengemudi HARUS masuk / mendaftar terlebih dahulu.
/// Halaman operasional driver tidak akan pernah ditampilkan jika belum login.
class DriverAuthGate extends StatefulWidget {
  const DriverAuthGate({super.key});

  @override
  State<DriverAuthGate> createState() => _DriverAuthGateState();
}

class _DriverAuthGateState extends State<DriverAuthGate> {
  StreamSubscription<AuthState>? _authSub;
  bool _isLoggedIn = false;

  @override
  void initState() {
    super.initState();
    _isLoggedIn = DriverService.instance.isLoggedIn;
    _listenAuth();
  }

  void _listenAuth() {
    final client = DriverService.instance.client;
    if (client != null) {
      _authSub = client.auth.onAuthStateChange.listen((data) {
        if (!mounted) return;
        final loggedIn = data.session != null;
        if (_isLoggedIn != loggedIn) {
          setState(() {
            _isLoggedIn = loggedIn;
          });
        }
      });
    }
  }

  @override
  void dispose() {
    _authSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoggedIn) {
      return const DriverMainScreen();
    }
    return const DriverAuthScreen();
  }
}
