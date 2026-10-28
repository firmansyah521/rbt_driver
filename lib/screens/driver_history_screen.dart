import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../constants/driver_theme.dart';
import '../models/driver_order_model.dart';
import '../services/driver_service.dart';

/// Layar Riwayat Tarikan & Pembukuan Kas Harian Driver
class DriverHistoryScreen extends StatefulWidget {
  const DriverHistoryScreen({super.key});

  @override
  State<DriverHistoryScreen> createState() => _DriverHistoryScreenState();
}

class _DriverHistoryScreenState extends State<DriverHistoryScreen> {
  List<DriverOrderModel> _history = [];
  bool _isLoading = true;
  String _filter = 'today'; // 'today', 'week', 'month', 'year', 'all'

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  Future<void> _loadHistory() async {
    setState(() => _isLoading = true);
    final list = await DriverService.instance.fetchDriverHistory();
    if (mounted) {
      setState(() {
        _history = list;
        _isLoading = false;
      });
    }
  }

  List<DriverOrderModel> get _filteredHistory {
    if (_filter == 'all') return _history;
    final now = DateTime.now();

    switch (_filter) {
      case 'today':
        return _history.where((o) =>
          o.createdAt.year == now.year &&
          o.createdAt.month == now.month &&
          o.createdAt.day == now.day
        ).toList();

      case 'week':
        final startOfWeek = DateTime(now.year, now.month, now.day)
            .subtract(Duration(days: now.weekday - 1));
        final endOfWeek = startOfWeek.add(const Duration(days: 7));
        return _history.where((o) =>
          !o.createdAt.isBefore(startOfWeek) &&
          o.createdAt.isBefore(endOfWeek)
        ).toList();

      case 'month':
        return _history.where((o) =>
          o.createdAt.year == now.year &&
          o.createdAt.month == now.month
        ).toList();

      case 'year':
        return _history.where((o) =>
          o.createdAt.year == now.year
        ).toList();

      default:
        return _history;
    }
  }

  String get _summaryTitle {
    switch (_filter) {
      case 'today':
        return 'PENDAPATAN BERSIH HARI INI';
      case 'week':
        return 'PENDAPATAN MINGGU INI';
      case 'month':
        return 'PENDAPATAN BULAN INI';
      case 'year':
        return 'PENDAPATAN TAHUN INI';
      case 'all':
      default:
        return 'TOTAL PENDAPATAN TERDAFTAR';
    }
  }

  String get _emptyDescription {
    switch (_filter) {
      case 'today':
        return 'Anda belum menyelesaikan tarikan hari ini. Terima order dari radar untuk mulai menghasilkan.';
      case 'week':
        return 'Belum ada tarikan yang diselesaikan pada minggu ini.';
      case 'month':
        return 'Belum ada tarikan yang diselesaikan pada bulan ini.';
      case 'year':
        return 'Belum ada tarikan yang diselesaikan pada tahun ini.';
      default:
        return 'Riwayat pesanan yang Anda selesaikan akan dicatat rapi di sini.';
    }
  }

  /// Total omzet kotor (tarif pengantaran total)
  int get _totalGrossEarnings {
    int sum = 0;
    for (final o in _filteredHistory) {
      if (o.isCompleted) sum += o.deliveryFee;
    }
    return sum;
  }

  /// Total potongan bagi hasil aplikasi RBT (5%)
  int get _totalPlatformFee {
    int sum = 0;
    for (final o in _filteredHistory) {
      if (o.isCompleted) sum += o.platformFee;
    }
    return sum;
  }

  /// Total pendapatan / omzet BERSIH yang diterima mitra driver (95%)
  int get _totalNetEarnings {
    int sum = 0;
    for (final o in _filteredHistory) {
      if (o.isCompleted) sum += o.netEarnings;
    }
    return sum;
  }

  double get _totalDistance {
    double sum = 0.0;
    for (final o in _filteredHistory) {
      if (o.isCompleted) sum += o.distanceKm;
    }
    return sum;
  }

  String _formatDate(DateTime dt) {
    try {
      return '${DateFormat('dd MMM yyyy, HH:mm', 'id_ID').format(dt)} WIB';
    } catch (_) {
      const months = [
        'Jan', 'Feb', 'Mar', 'Apr', 'Mei', 'Jun',
        'Jul', 'Ags', 'Sep', 'Okt', 'Nov', 'Des'
      ];
      final day = dt.day.toString().padLeft(2, '0');
      final month = (dt.month >= 1 && dt.month <= 12) ? months[dt.month - 1] : dt.month.toString();
      final year = dt.year;
      final hour = dt.hour.toString().padLeft(2, '0');
      final min = dt.minute.toString().padLeft(2, '0');
      return '$day $month $year, $hour:$min WIB';
    }
  }

  String _formatRupiah(int amount) {
    try {
      final f = NumberFormat.currency(locale: 'id_ID', symbol: 'Rp ', decimalDigits: 0);
      return f.format(amount);
    } catch (_) {
      final str = amount.toString().replaceAllMapped(
        RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'),
        (m) => '${m[1]}.',
      );
      return 'Rp $str';
    }
  }

  Widget _buildFilterChip(String filterKey, String label) {
    final isSelected = _filter == filterKey;
    return ChoiceChip(
      label: Text(label),
      selected: isSelected,
      selectedColor: DriverTheme.primaryBenhur,
      backgroundColor: DriverTheme.cardDark,
      side: BorderSide(
        color: isSelected ? DriverTheme.primaryBenhurLight : DriverTheme.cardBorder,
      ),
      labelStyle: TextStyle(
        fontWeight: FontWeight.bold,
        fontSize: 12,
        color: isSelected ? Colors.white : DriverTheme.textSecondary,
      ),
      onSelected: (val) {
        if (val) setState(() => _filter = filterKey);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final list = _filteredHistory;

    return Scaffold(
      appBar: AppBar(
        title: const Text('RIWAYAT & PENDAPATAN'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: 'Segarkan',
            onPressed: _loadHistory,
          ),
        ],
      ),
      body: RefreshIndicator(
        color: Colors.white,
        backgroundColor: DriverTheme.cardDark,
        onRefresh: _loadHistory,
        child: Column(
          children: [
            // 1. Ringkasan Kas & Statistik
            _buildSummaryCard(),

            // 2. Filter Tab Periode
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  _buildFilterChip('today', 'Hari Ini'),
                  const SizedBox(width: 8),
                  _buildFilterChip('week', 'Minggu Ini'),
                  const SizedBox(width: 8),
                  _buildFilterChip('month', 'Bulan Ini'),
                  const SizedBox(width: 8),
                  _buildFilterChip('year', 'Tahun Ini'),
                  const SizedBox(width: 8),
                  _buildFilterChip('all', 'Semua Riwayat'),
                ],
              ),
            ),

            // 3. Daftar Order
            Expanded(
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator(color: Colors.white))
                  : list.isEmpty
                      ? _buildEmptyState()
                      : ListView.builder(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                          itemCount: list.length,
                          itemBuilder: (context, index) {
                            return _buildHistoryCard(list[index]);
                          },
                        ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSummaryCard() {
    return Container(
      margin: const EdgeInsets.all(16),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: DriverTheme.cardDark,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: DriverTheme.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _summaryTitle,
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: DriverTheme.textMuted, letterSpacing: 0.8),
          ),
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                _formatRupiah(_totalNetEarnings),
                style: const TextStyle(fontSize: 26, fontWeight: FontWeight.bold, color: Colors.white),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: DriverTheme.uberPillBg,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: const Text(
                  'BERSIH',
                  style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: Colors.white),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Total Nilai Order: ${_formatRupiah(_totalGrossEarnings)} • Bagi Hasil: ${_formatRupiah(_totalPlatformFee)}',
            style: const TextStyle(fontSize: 11, color: DriverTheme.textSecondary),
          ),
          const Divider(color: DriverTheme.cardBorder, height: 24),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              Expanded(
                child: _buildStatItem('Order Selesai', '${_filteredHistory.where((o) => o.isCompleted).length} Order'),
              ),
              Container(width: 1, height: 28, color: DriverTheme.cardBorder),
              Expanded(
                child: _buildStatItem('Total Jarak', '${_totalDistance.toStringAsFixed(1)} KM'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildStatItem(String label, String value) {
    return Column(
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 11, color: DriverTheme.textMuted),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 3),
        Text(
          value,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: DriverTheme.textPrimary),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: SingleChildScrollView(
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: DriverTheme.cardDark,
                shape: BoxShape.circle,
                border: Border.all(color: DriverTheme.cardBorder),
              ),
              child: const Icon(Icons.receipt_long_outlined, size: 48, color: DriverTheme.textMuted),
            ),
            const SizedBox(height: 16),
            const Text(
              'Belum Ada Riwayat Tarikan',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: DriverTheme.textPrimary),
            ),
            const SizedBox(height: 6),
            Text(
              _emptyDescription,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12, color: DriverTheme.textSecondary),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHistoryCard(DriverOrderModel order) {
    final isCompleted = order.isCompleted;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: DriverTheme.cardDark,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: DriverTheme.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Icon(
                    order.isFood ? Icons.restaurant : Icons.two_wheeler_rounded,
                    size: 15,
                    color: Colors.white,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    order.typeLabel,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: isCompleted
                      ? DriverTheme.onlineGreen.withValues(alpha: 0.15)
                      : DriverTheme.offlineRed.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  isCompleted ? 'Selesai' : 'Dibatalkan',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: isCompleted ? DriverTheme.onlineGreen : DriverTheme.offlineRed,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '#${order.orderCode}',
                style: const TextStyle(fontSize: 12, fontFamily: 'monospace', color: DriverTheme.textSecondary),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    _formatRupiah(order.netEarnings),
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                      color: isCompleted ? Colors.white : DriverTheme.textMuted,
                    ),
                  ),
                  Text(
                    'Ongkir: ${_formatRupiah(order.deliveryFee)}',
                    style: const TextStyle(
                      fontSize: 10,
                      color: DriverTheme.textMuted,
                    ),
                  ),
                ],
              ),
            ],
          ),
          const Divider(color: DriverTheme.cardBorder, height: 16),
          Text(
            '${order.pickupAddress} -> ${order.destinationAddress}',
            style: const TextStyle(fontSize: 12, color: DriverTheme.textPrimary),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 4),
          Text(
            '${order.distanceKm.toStringAsFixed(1)} KM • ${_formatDate(order.createdAt)}',
            style: const TextStyle(fontSize: 10, color: DriverTheme.textMuted),
          ),
        ],
      ),
    );
  }
}
