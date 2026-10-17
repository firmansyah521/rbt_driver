import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';
import '../constants/driver_theme.dart';
import '../services/driver_permission_service.dart';
import '../services/driver_safe_error_handler.dart';
import '../services/driver_service.dart';
import '../widgets/driver_offline_banner.dart';
import '../widgets/driver_qris_dialog.dart';
import 'driver_auth_gate.dart';
import 'driver_auth_screen.dart';
import 'package:intl/intl.dart';

/// Layar Profil Driver & Identitas Kendaraan
/// Menampilkan data identitas resmi mitra driver (Nama, HP, Plat, Motor) dalam mode Terverifikasi (Terkunci)
/// serta mendukung pembaruan foto profil dan pengajuan perubahan data ke Admin RBT.
class DriverProfileScreen extends StatefulWidget {
  const DriverProfileScreen({super.key});

  @override
  State<DriverProfileScreen> createState() => _DriverProfileScreenState();
}

class _DriverProfileScreenState extends State<DriverProfileScreen> {
  bool _isSavingPhoto = false;
  Uint8List? _pickedPhotoBytes;
  String _currentPhotoUrl = '';

  @override
  void initState() {
    super.initState();
    _loadProfileData();
    _refreshProfile();
    DriverService.instance.profileNotifier.addListener(_onProfileChanged);
  }

  @override
  void dispose() {
    DriverService.instance.profileNotifier.removeListener(_onProfileChanged);
    super.dispose();
  }

  void _onProfileChanged() {
    if (mounted) {
      setState(() {
        _loadProfileData();
      });
    }
  }

  void _loadProfileData() {
    final profile = DriverService.instance.profile;
    _currentPhotoUrl = profile.photoUrl;
  }

  Future<void> _refreshProfile() async {
    final updated = await DriverService.instance.fetchDriverProfile();
    if (mounted && updated != null) {
      setState(() {
        _loadProfileData();
      });
    }
  }

  Future<void> _pickImage(ImageSource source) async {
    try {
      final granted = await DriverPermissionService.instance.requestMediaPermissions();
      if (!granted) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            backgroundColor: DriverTheme.alertAmber,
            content: Text('Izin akses kamera atau galeri foto diperlukan.'),
          ),
        );
        return;
      }

      final picker = ImagePicker();
      final picked = await picker.pickImage(
        source: source,
        maxWidth: 600,
        maxHeight: 600,
        imageQuality: 85,
      );
      if (picked != null) {
        final bytes = await picked.readAsBytes();
        final ext = picked.name.split('.').last.toLowerCase();
        setState(() {
          _pickedPhotoBytes = bytes;
        });
        await _savePhoto(bytes, fileExt: ext.isNotEmpty ? ext : 'jpg');
      }
    } catch (e) {
      debugPrint('Error pick image: ${DriverSafeErrorHandler.sanitize(e.toString())}');
    }
  }

  Future<void> _savePhoto(Uint8List bytes, {String fileExt = 'jpg'}) async {
    setState(() => _isSavingPhoto = true);
    try {
      final uploaded = await DriverService.instance.uploadDriverPhoto(bytes, fileExt: fileExt);
      if (uploaded != null && uploaded.isNotEmpty) {
        final current = DriverService.instance.profile;
        final updated = current.copyWith(photoUrl: uploaded);
        await DriverService.instance.saveProfile(updated);

        if (!mounted) return;
        setState(() {
          _currentPhotoUrl = uploaded;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            backgroundColor: DriverTheme.onlineGreen,
            content: Text(
              'Foto profil mitra berhasil diperbarui dan tersimpan di server cloud!',
              style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
            ),
          ),
        );
      }
    } catch (e) {
      debugPrint('Gagal update foto driver: $e');
    } finally {
      if (mounted) {
        setState(() => _isSavingPhoto = false);
      }
    }
  }

  void _showPhotoOptionsDialog() {
    showModalBottomSheet(
      context: context,
      backgroundColor: DriverTheme.cardDark,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Ubah Foto Profil Driver',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: DriverTheme.textPrimary,
                ),
              ),
              const SizedBox(height: 16),
              ListTile(
                leading: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: DriverTheme.electricBlue.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.camera_alt, color: DriverTheme.brightCyan),
                ),
                title: const Text('Buka Kamera', style: TextStyle(color: Colors.white)),
                onTap: () {
                  Navigator.pop(ctx);
                  _pickImage(ImageSource.camera);
                },
              ),
              ListTile(
                leading: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: DriverTheme.electricBlue.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.photo_library, color: DriverTheme.brightCyan),
                ),
                title: const Text('Pilih dari Galeri', style: TextStyle(color: Colors.white)),
                onTap: () {
                  Navigator.pop(ctx);
                  _pickImage(ImageSource.gallery);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _contactAdminWhatsApp() async {
    final profile = DriverService.instance.profile;
    final message = Uri.encodeComponent(
      'Halo Admin RBT Pidie, saya Mitra Driver (${profile.name.isNotEmpty ? profile.name : "Driver"} - ${profile.phone}, Plat: ${profile.plateNumber}) ingin mengajukan permohonan pembaruan data akun / kendaraan.',
    );
    final url = Uri.parse('https://wa.me/6285260000000?text=$message');
    try {
      if (await canLaunchUrl(url)) {
        await launchUrl(url, mode: LaunchMode.externalApplication);
      } else {
        await launchUrl(url);
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          backgroundColor: DriverTheme.alertAmber,
          content: Text('Tidak dapat membuka WhatsApp. Silakan hubungi Kantor RBT Pidie.'),
        ),
      );
    }
  }

  Future<void> _logout() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: DriverTheme.cardDark,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Keluar dari Akun Mitra?', style: TextStyle(color: Colors.white)),
        content: const Text(
          'Anda akan keluar dari sesi driver. Anda dapat masuk kembali kapan saja menggunakan nomor WhatsApp Anda.',
          style: TextStyle(color: DriverTheme.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Batal', style: TextStyle(color: DriverTheme.textMuted)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: DriverTheme.offlineRed),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Keluar', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await DriverService.instance.signOut();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          backgroundColor: DriverTheme.surfaceDark,
          content: Text('Anda telah keluar dari akun driver.'),
        ),
      );
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(builder: (_) => const DriverAuthGate()),
        (route) => false,
      );
    }
  }

  Widget _buildAvatarWidget() {
    ImageProvider? imageProvider;
    if (_pickedPhotoBytes != null) {
      imageProvider = MemoryImage(_pickedPhotoBytes!);
    }

    final profile = DriverService.instance.profile;

    return Center(
      child: Column(
        children: [
          Stack(
            alignment: Alignment.bottomRight,
            children: [
              Container(
                width: 96,
                height: 96,
                decoration: BoxDecoration(
                  color: DriverTheme.surfaceDark,
                  shape: BoxShape.circle,
                  border: Border.all(color: DriverTheme.electricBlue, width: 2.5),
                  boxShadow: [
                    BoxShadow(
                      color: DriverTheme.electricBlue.withValues(alpha: 0.3),
                      blurRadius: 8,
                      spreadRadius: 2,
                    ),
                  ],
                  image: imageProvider != null
                      ? DecorationImage(image: imageProvider, fit: BoxFit.cover)
                      : null,
                ),
                child: _isSavingPhoto
                    ? const Center(
                        child: CircularProgressIndicator(
                          color: DriverTheme.brightCyan,
                          strokeWidth: 3,
                        ),
                      )
                    : (imageProvider == null
                        ? const Icon(Icons.two_wheeler_rounded, size: 50, color: DriverTheme.brightCyan)
                        : null),
              ),
              InkWell(
                onTap: _isSavingPhoto ? null : _showPhotoOptionsDialog,
                borderRadius: BorderRadius.circular(16),
                child: Container(
                  padding: const EdgeInsets.all(7),
                  decoration: const BoxDecoration(
                    color: DriverTheme.electricBlue,
                    shape: BoxShape.circle,
                    boxShadow: [BoxShadow(color: Colors.black45, blurRadius: 4)],
                  ),
                  child: const Icon(Icons.camera_alt, size: 16, color: Colors.white),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            profile.name.isNotEmpty ? profile.name : 'Mitra RBT Pidie',
            style: const TextStyle(fontSize: 19, fontWeight: FontWeight.bold, color: DriverTheme.textPrimary),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            alignment: WrapAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: DriverTheme.cardDark,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: DriverTheme.cardBorder),
                ),
                child: Text(
                  profile.plateNumber.isNotEmpty
                      ? 'Plat: ${profile.plateNumber}'
                      : 'Plat: Belum Diisi',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.8,
                    color: DriverTheme.brightCyan,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: DriverTheme.onlineGreen.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: DriverTheme.onlineGreen.withValues(alpha: 0.4)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.star_rounded, size: 14, color: DriverTheme.onlineGreen),
                    const SizedBox(width: 3),
                    Text(
                      profile.rating.toStringAsFixed(1),
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: DriverTheme.onlineGreen,
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: DriverTheme.electricBlue.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: DriverTheme.electricBlue.withValues(alpha: 0.4)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.navigation_rounded, size: 14, color: DriverTheme.electricBlue),
                    const SizedBox(width: 3),
                    Text(
                      '${profile.totalTrips} Trip',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: DriverTheme.electricBlue,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildVerifiedDataCard({
    required String label,
    required String value,
    required IconData icon,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
      decoration: BoxDecoration(
        color: DriverTheme.surfaceDark,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: DriverTheme.cardBorder),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: DriverTheme.electricBlue.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, color: DriverTheme.brightCyan, size: 18),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(fontSize: 11, color: DriverTheme.textMuted),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  value.isNotEmpty ? value : '-',
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: DriverTheme.textPrimary,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: DriverTheme.onlineGreen.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: DriverTheme.onlineGreen.withValues(alpha: 0.4)),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.lock_outline, size: 11, color: DriverTheme.onlineGreen),
                SizedBox(width: 4),
                Text(
                  'Terkunci',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: DriverTheme.onlineGreen,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDepositCard(dynamic profile) {
    final deposit = (profile.depositBalance as int?) ?? 0;
    final currency = NumberFormat.currency(locale: 'id_ID', symbol: 'Rp ', decimalDigits: 0);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            DriverTheme.electricBlue.withValues(alpha: 0.22),
            DriverTheme.surfaceDark,
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: DriverTheme.electricBlue.withValues(alpha: 0.5), width: 1.2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: DriverTheme.brightCyan.withValues(alpha: 0.15),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.account_balance_wallet_rounded, color: DriverTheme.brightCyan, size: 22),
                  ),
                  const SizedBox(width: 10),
                  const Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'SALDO DEPOSIT MITRA',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: Colors.white70,
                          letterSpacing: 0.5,
                        ),
                      ),
                      Text(
                        'Biaya Admin Aplikasi 5%',
                        style: TextStyle(fontSize: 10, color: DriverTheme.textMuted),
                      ),
                    ],
                  ),
                ],
              ),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: DriverTheme.brightCyan,
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  elevation: 2,
                ),
                icon: const Icon(Icons.add, size: 16),
                label: const Text('Top Up QRIS', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                onPressed: () {
                  DriverQrisDialog.show(
                    context,
                    onSuccessRedirect: () {
                      _refreshProfile();
                    },
                  );
                },
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Sisa Saldo Kas:', style: TextStyle(fontSize: 11, color: DriverTheme.textMuted)),
                  const SizedBox(height: 2),
                  Text(
                    currency.format(deposit),
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                      color: deposit > 5000 ? DriverTheme.onlineGreen : DriverTheme.alertAmber,
                    ),
                  ),
                ],
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: (deposit > 5000 ? DriverTheme.onlineGreen : DriverTheme.alertAmber).withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: deposit > 5000 ? DriverTheme.onlineGreen : DriverTheme.alertAmber),
                ),
                child: Text(
                  deposit > 5000 ? 'Saldo Aman' : 'Perlu Top Up',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: deposit > 5000 ? DriverTheme.onlineGreen : DriverTheme.alertAmber,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          const Divider(color: DriverTheme.cardBorder, height: 1),
          const SizedBox(height: 8),
          const Text(
            '💡 Setiap kali Anda berhasil mengambil orderan, saldo deposit akan otomatis terpotong 5% dari ongkir. Jika saldo tidak cukup, Anda tidak dapat mengambil orderan.',
            style: TextStyle(fontSize: 11, color: Colors.white60, height: 1.3),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isLoggedIn = DriverService.instance.isLoggedIn;
    final profile = DriverService.instance.profile;

    return Scaffold(
      appBar: AppBar(
        title: const Text('PROFIL MITRA DRIVER'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Segarkan Profil',
            onPressed: _refreshProfile,
          ),
          if (isLoggedIn)
            IconButton(
              icon: const Icon(Icons.logout, color: DriverTheme.offlineRed),
              tooltip: 'Keluar Akun',
              onPressed: _logout,
            ),
        ],
      ),
      body: Column(
        children: [
          const DriverOfflineBanner(),
          Expanded(
            child: RefreshIndicator(
              color: DriverTheme.brightCyan,
              onRefresh: _refreshProfile,
              child: SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Banner jika belum login
                    if (!isLoggedIn) ...[
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: DriverTheme.surfaceDark,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: DriverTheme.electricBlue),
                        ),
                        child: Column(
                          children: [
                            const Icon(Icons.account_circle_outlined, size: 48, color: DriverTheme.brightCyan),
                            const SizedBox(height: 10),
                            const Text(
                              'Belum Masuk Akun Driver',
                              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Colors.white),
                            ),
                            const SizedBox(height: 4),
                            const Text(
                              'Silakan masuk atau daftar akun mitra baru untuk mengelola profil dan menerima pesanan.',
                              textAlign: TextAlign.center,
                              style: TextStyle(fontSize: 12, color: DriverTheme.textSecondary),
                            ),
                            const SizedBox(height: 14),
                            ElevatedButton(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: DriverTheme.electricBlue,
                                foregroundColor: Colors.white,
                                minimumSize: const Size(double.infinity, 44),
                              ),
                              onPressed: () {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(builder: (_) => const DriverAuthScreen()),
                                ).then((_) {
                                  _loadProfileData();
                                  setState(() {});
                                });
                              },
                              child: const Text('Masuk / Daftar Akun Mitra', style: TextStyle(fontWeight: FontWeight.bold)),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 20),
                    ],

                    // Avatar & Badge Driver
                    _buildAvatarWidget(),

                    const SizedBox(height: 18),

                    // KARTU SALDO DEPOSIT MITRA DRIVER
                    _buildDepositCard(profile),

                    const SizedBox(height: 20),

                    // Header Bagian Identitas Mitra
                    const Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'DATA RESMI MITRA',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: DriverTheme.textSecondary,
                            letterSpacing: 0.8,
                          ),
                        ),
                        Row(
                          children: [
                            Icon(Icons.verified, size: 14, color: DriverTheme.onlineGreen),
                            SizedBox(width: 4),
                            Text(
                              'Terverifikasi',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                color: DriverTheme.onlineGreen,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),

                    const SizedBox(height: 10),

                    // Kartu Data Terverifikasi (Read-Only)
                    _buildVerifiedDataCard(
                      label: 'Nama Lengkap Mitra',
                      value: profile.name,
                      icon: Icons.person_outline,
                    ),
                    const SizedBox(height: 10),

                    _buildVerifiedDataCard(
                      label: 'Nomor WhatsApp Driver',
                      value: profile.phone,
                      icon: Icons.phone_android_outlined,
                    ),
                    const SizedBox(height: 10),

                    _buildVerifiedDataCard(
                      label: 'Nomor Plat Kendaraan (BL)',
                      value: profile.plateNumber,
                      icon: Icons.badge_outlined,
                    ),
                    const SizedBox(height: 10),

                    _buildVerifiedDataCard(
                      label: 'Model / Tipe Motor',
                      value: profile.vehicleType,
                      icon: Icons.two_wheeler_outlined,
                    ),

                    const SizedBox(height: 20),

                    // Kartu Bantuan Perubahan Data Mitra Resmi
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: DriverTheme.cardDark,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: DriverTheme.cardBorder),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Row(
                            children: [
                              Icon(Icons.info_outline, color: DriverTheme.brightCyan, size: 18),
                              SizedBox(width: 8),
                              Text(
                                'Ketentuan Data Pribadi',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 13,
                                  color: Colors.white,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          const Text(
                            'Data pribadi mitra (Nama, Nomor WhatsApp, Plat Kendaraan, dan Tipe Motor) dikunci demi kepatuhan operasional dan keamanan pesanan. Jika ada perubahan unit kendaraan atau nomor kontak, silakan ajukan ke Admin Kantor RBT Pidie.',
                            style: TextStyle(fontSize: 12, color: DriverTheme.textSecondary, height: 1.4),
                          ),
                          const SizedBox(height: 14),
                          SizedBox(
                            width: double.infinity,
                            height: 44,
                            child: ElevatedButton.icon(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: DriverTheme.electricBlue,
                                foregroundColor: Colors.white,
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                              ),
                              icon: const Icon(Icons.support_agent, size: 20),
                              label: const Text(
                                'Hubungi Admin RBT (WhatsApp)',
                                style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                              ),
                              onPressed: _contactAdminWhatsApp,
                            ),
                          ),
                        ],
                      ),
                    ),

                    if (isLoggedIn) ...[
                      const SizedBox(height: 16),
                      // Kelola Izin Operasional Driver
                      Container(
                        decoration: BoxDecoration(
                          color: DriverTheme.surfaceDark,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: DriverTheme.cardBorder),
                        ),
                        child: ListTile(
                          leading: Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: DriverTheme.onlineGreen.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: const Icon(Icons.security_rounded, color: DriverTheme.onlineGreen, size: 20),
                          ),
                          title: const Text(
                            'Izin Operasional Mitra',
                            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.white),
                          ),
                          subtitle: const Text(
                            'Status GPS, Notifikasi Radar & Penyimpanan',
                            style: TextStyle(fontSize: 11, color: DriverTheme.textSecondary),
                          ),
                          trailing: const Icon(Icons.chevron_right, color: Colors.grey),
                          onTap: () => DriverPermissionService.instance.showDriverPermissionDialog(context),
                        ),
                      ),

                      const SizedBox(height: 16),

                      // Tombol Keluar Akun
                      SizedBox(
                        width: double.infinity,
                        height: 46,
                        child: OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            foregroundColor: DriverTheme.offlineRed,
                            side: const BorderSide(color: DriverTheme.offlineRed),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                          icon: const Icon(Icons.logout, size: 18),
                          label: const Text('KELUAR DARI AKUN MITRA', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                          onPressed: _logout,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
