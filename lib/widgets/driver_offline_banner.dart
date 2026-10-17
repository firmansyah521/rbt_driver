import 'package:flutter/material.dart';
import '../constants/driver_theme.dart';
import '../services/driver_network_service.dart';

/// Banner Peringatan Status Offline untuk Aplikasi Driver
class DriverOfflineBanner extends StatelessWidget {
  const DriverOfflineBanner({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: DriverNetworkService.instance.isConnectedNotifier,
      builder: (context, isConnected, child) {
        if (isConnected) return const SizedBox.shrink();

        return Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: DriverTheme.offlineRed,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.3),
                blurRadius: 6,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: SafeArea(
            bottom: false,
            child: Row(
              children: [
                const Icon(Icons.wifi_off_rounded, color: Colors.white, size: 18),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text(
                    'Koneksi terputus: Radar order tidak dapat menerima pesanan baru secara realtime.',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                InkWell(
                  onTap: () async {
                    final res = await DriverNetworkService.instance.hasInternetAccess();
                    DriverNetworkService.instance.isConnectedNotifier.value = res;
                  },
                  borderRadius: BorderRadius.circular(4),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.25),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.refresh, color: Colors.white, size: 13),
                        SizedBox(width: 4),
                        Text(
                          'Cek',
                          style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
