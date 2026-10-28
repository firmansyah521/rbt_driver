import 'package:flutter/material.dart';
import '../constants/driver_theme.dart';
import '../models/driver_order_model.dart';
import '../services/driver_service.dart';
import 'driver_active_job_screen.dart';
import 'driver_auth_gate.dart';
import 'driver_history_screen.dart';
import 'driver_profile_screen.dart';
import 'driver_radar_screen.dart';

/// Kerangka Navigasi Utama Aplikasi RBT Driver
/// Menghubungkan Tab Radar, Riwayat Pendapatan, dan Profil Driver
/// Dilengkapi deteksi otomatis pesanan aktif yang sedang berjalan
class DriverMainScreen extends StatefulWidget {
  const DriverMainScreen({super.key});

  @override
  State<DriverMainScreen> createState() => _DriverMainScreenState();
}

class _DriverMainScreenState extends State<DriverMainScreen> {
  int _currentIndex = 0;

  @override
  Widget build(BuildContext context) {
    if (!DriverService.instance.isLoggedIn) {
      return const DriverAuthGate();
    }

    final screens = [
      DriverRadarScreen(
        onOpenHistory: () => setState(() => _currentIndex = 1),
        onOpenProfile: () {
          DriverService.instance.fetchDriverProfile();
          setState(() => _currentIndex = 2);
        },
      ),
      const DriverHistoryScreen(),
      const DriverProfileScreen(),
    ];

    return Scaffold(
      body: Stack(
        children: [
          IndexedStack(
            index: _currentIndex,
            children: screens,
          ),

          // Banner Mengambang Jika Ada Order Berjalan
          StreamBuilder<DriverOrderModel?>(
            stream: DriverService.instance.streamActiveJob(),
            builder: (context, snapshot) {
              final activeOrder = snapshot.data;
              if (activeOrder == null) return const SizedBox.shrink();

              return Positioned(
                top: MediaQuery.of(context).padding.top + 8,
                left: 14,
                right: 14,
                child: Material(
                  elevation: 4,
                  borderRadius: BorderRadius.circular(12),
                  color: DriverTheme.cardDark,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => DriverActiveJobScreen(order: activeOrder),
                        ),
                      );
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: DriverTheme.cardBorder, width: 1.0),
                      ),
                      child: Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(7),
                            decoration: const BoxDecoration(
                              color: DriverTheme.uberPillBg,
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(Icons.two_wheeler_rounded, color: DriverTheme.onlineGreen, size: 18),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Row(
                                  children: [
                                    Container(
                                      width: 6,
                                      height: 6,
                                      decoration: const BoxDecoration(
                                        color: DriverTheme.onlineGreen,
                                        shape: BoxShape.circle,
                                      ),
                                    ),
                                    const SizedBox(width: 5),
                                    const Text(
                                      'TARIKAN SEDANG AKTIF',
                                      style: TextStyle(
                                        fontSize: 10,
                                        fontWeight: FontWeight.bold,
                                        color: DriverTheme.onlineGreen,
                                        letterSpacing: 0.5,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  '#${activeOrder.orderCode} • ${activeOrder.customerName}',
                                  style: const TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.bold,
                                    color: DriverTheme.textPrimary,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                            decoration: BoxDecoration(
                              color: DriverTheme.uberWhite,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: const Row(
                              children: [
                                Text(
                                  'Lanjut',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                    color: DriverTheme.primaryBenhur,
                                  ),
                                ),
                                SizedBox(width: 4),
                                Icon(Icons.arrow_forward_ios_rounded, size: 10, color: DriverTheme.primaryBenhur),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ],
      ),
      bottomNavigationBar: Container(
        decoration: const BoxDecoration(
          color: DriverTheme.darkBg,
          border: Border(top: BorderSide(color: DriverTheme.cardBorder, width: 1.0)),
        ),
        child: BottomNavigationBar(
          currentIndex: _currentIndex,
          elevation: 0,
          backgroundColor: DriverTheme.darkBg,
          selectedItemColor: DriverTheme.primaryBenhurLight,
          unselectedItemColor: DriverTheme.textMuted,
          selectedLabelStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11),
          unselectedLabelStyle: const TextStyle(fontSize: 11),
          type: BottomNavigationBarType.fixed,
          onTap: (index) {
            if (index == 2) {
              DriverService.instance.fetchDriverProfile();
            }
            setState(() => _currentIndex = index);
          },
          items: const [
            BottomNavigationBarItem(
              icon: Icon(Icons.radar_outlined),
              activeIcon: Icon(Icons.radar),
              label: 'Radar',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.receipt_long_outlined),
              activeIcon: Icon(Icons.receipt_long),
              label: 'Riwayat',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.person_outline),
              activeIcon: Icon(Icons.person),
              label: 'Akun',
            ),
          ],
        ),
      ),
    );
  }
}
