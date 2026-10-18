import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';

/// Lapisan Tile Peta Khusus Driver RBT Pidie
/// Mengaktifkan disk-caching lokal dan debouncing permintaan tile
class DriverTileLayer extends StatelessWidget {
  final double maxZoom;

  const DriverTileLayer({
    super.key,
    this.maxZoom = 19.0,
  });

  @override
  Widget build(BuildContext context) {
    return TileLayer(
      urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
      userAgentPackageName: 'com.rbtpidie.driver',
      maxZoom: maxZoom,
      tileUpdateTransformer: TileUpdateTransformers.debounce(
        const Duration(milliseconds: 100),
      ),
      tileProvider: NetworkTileProvider(
        cachingProvider: BuiltInMapCachingProvider.getOrCreateInstance(),
      ),
    );
  }
}
