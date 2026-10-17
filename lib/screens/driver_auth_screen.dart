import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../constants/driver_theme.dart';
import '../services/driver_network_service.dart';
import '../services/driver_permission_service.dart';
import '../services/driver_safe_error_handler.dart';
import '../services/driver_service.dart';
import '../widgets/driver_offline_banner.dart';
import 'driver_main_screen.dart';

/// Halaman Masuk & Pendaftaran Akun Mitra Driver RBT Online Pidie
/// Dilengkapi pemilihan foto profil, nomor WhatsApp, plat nomor, dan tipe motor
class DriverAuthScreen extends StatefulWidget {
  final bool initialIsRegister;
  const DriverAuthScreen({super.key, this.initialIsRegister = false});

  @override
  State<DriverAuthScreen> createState() => _DriverAuthScreenState();
}

class _DriverAuthScreenState extends State<DriverAuthScreen> {
  late bool _isRegister;
  bool _isLoading = false;
  bool _obscurePassword = true;
  bool _obscureConfirmPassword = true;

  // Controllers
  final TextEditingController _phoneController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _confirmPasswordController = TextEditingController();
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _plateController = TextEditingController();
  final TextEditingController _vehicleController = TextEditingController();

  final _formKey = GlobalKey<FormState>();

  // Profile photo state
  Uint8List? _pickedPhotoBytes;
  String? _pickedPhotoExt;
  String _selectedPresetAvatar = 'helmet';

  final List<Map<String, dynamic>> _presetAvatars = [
    {'id': 'helmet', 'label': 'Helm RBT', 'icon': Icons.two_wheeler},
    {'id': 'driver_m', 'label': 'Mitra Pria', 'icon': Icons.sports_motorsports},
    {'id': 'driver_f', 'label': 'Mitra Wanita', 'icon': Icons.person_pin},
    {'id': 'speed', 'label': 'Express', 'icon': Icons.electric_bolt},
  ];

  @override
  void initState() {
    super.initState();
    _isRegister = widget.initialIsRegister;
  }

  @override
  void dispose() {
    _phoneController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    _nameController.dispose();
    _plateController.dispose();
    _vehicleController.dispose();
    super.dispose();
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
          _pickedPhotoExt = ext.isNotEmpty ? ext : 'jpg';
        });
      }
    } catch (e) {
      debugPrint('Error pick image: ${DriverSafeErrorHandler.sanitize(e.toString())}');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: DriverTheme.offlineRed,
          content: Text(DriverSafeErrorHandler.getUserFriendlyMessage(e, fallback: 'Gagal mengambil foto.')),
        ),
      );
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
                'Pilih Foto Profil Driver',
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
              const Divider(color: DriverTheme.cardBorder),
              const Text(
                'Atau gunakan Ikon Avatar Mitra:',
                style: TextStyle(fontSize: 12, color: DriverTheme.textSecondary),
              ),
              const SizedBox(height: 10),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: _presetAvatars.map((preset) {
                  final isSelected = _pickedPhotoBytes == null && _selectedPresetAvatar == preset['id'];
                  return InkWell(
                    onTap: () {
                      setState(() {
                        _pickedPhotoBytes = null;
                        _pickedPhotoExt = null;
                        _selectedPresetAvatar = preset['id'] as String;
                      });
                      Navigator.pop(ctx);
                    },
                    borderRadius: BorderRadius.circular(12),
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: isSelected ? DriverTheme.electricBlue : DriverTheme.surfaceDark,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: isSelected ? DriverTheme.brightCyan : DriverTheme.cardBorder,
                          width: 2,
                        ),
                      ),
                      child: Icon(
                        preset['icon'] as IconData,
                        color: isSelected ? Colors.white : DriverTheme.brightCyan,
                        size: 28,
                      ),
                    ),
                  );
                }).toList(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;

    if (!DriverNetworkService.instance.isConnected) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          backgroundColor: DriverTheme.offlineRed,
          content: Text('Koneksi internet tidak tersedia. Harap periksa paket data seluler Anda.'),
        ),
      );
      return;
    }

    setState(() => _isLoading = true);
    FocusScope.of(context).unfocus();

    final phone = _phoneController.text.trim();
    final password = _passwordController.text.trim();

    try {
      if (_isRegister) {
        if (password != _confirmPasswordController.text.trim()) {
          throw const AuthException('Konfirmasi kata sandi tidak cocok.');
        }

        final name = _nameController.text.trim();
        final plate = _plateController.text.trim().toUpperCase();
        final vehicle = _vehicleController.text.trim();
        String photoUrl = 'preset:$_selectedPresetAvatar';
        if (_pickedPhotoBytes != null) {
          final uploaded = await DriverService.instance.uploadDriverPhoto(
            _pickedPhotoBytes!,
            fileExt: _pickedPhotoExt ?? 'jpg',
          );
          if (uploaded != null && uploaded.isNotEmpty) {
            photoUrl = uploaded;
          }
        }

        await DriverService.instance.signUpWithPhone(
          name: name,
          phone: phone,
          password: password,
          plateNumber: plate,
          vehicleType: vehicle,
          photoUrl: photoUrl,
        );

        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: DriverTheme.onlineGreen,
            content: Text('Pendaftaran Mitra Berhasil! Selamat bertugas Bang/Kak $name.'),
          ),
        );
        if (Navigator.canPop(context)) {
          Navigator.pop(context, true);
        } else {
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(builder: (_) => const DriverMainScreen()),
          );
        }
      } else {
        await DriverService.instance.signInWithPhone(
          phone: phone,
          password: password,
        );

        if (!mounted) return;
        final driverName = DriverService.instance.profile.name;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: DriverTheme.onlineGreen,
            content: Text('Berhasil Masuk! Selamat datang kembali, $driverName.'),
          ),
        );
        if (Navigator.canPop(context)) {
          Navigator.pop(context, true);
        } else {
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(builder: (_) => const DriverMainScreen()),
          );
        }
      }
    } on AuthException catch (e) {
      if (!mounted) return;
      final errorMsg = DriverSafeErrorHandler.getUserFriendlyMessage(e);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: DriverTheme.offlineRed,
          content: Text(errorMsg),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: DriverTheme.offlineRed,
          content: Text(DriverSafeErrorHandler.getUserFriendlyMessage(e)),
        ),
      );
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Widget _buildPhotoAvatar() {
    ImageProvider? imageProvider;
    if (_pickedPhotoBytes != null) {
      imageProvider = MemoryImage(_pickedPhotoBytes!);
    }

    return Center(
      child: Stack(
        alignment: Alignment.bottomRight,
        children: [
          Container(
            width: 96,
            height: 96,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: DriverTheme.surfaceDark,
              border: Border.all(color: DriverTheme.brightCyan, width: 2.5),
              boxShadow: [
                BoxShadow(
                  color: DriverTheme.brightCyan.withValues(alpha: 0.3),
                  blurRadius: 10,
                  spreadRadius: 2,
                ),
              ],
              image: imageProvider != null
                  ? DecorationImage(image: imageProvider, fit: BoxFit.cover)
                  : null,
            ),
            child: imageProvider == null
                ? const Icon(
                    Icons.sports_motorsports_rounded,
                    size: 50,
                    color: DriverTheme.brightCyan,
                  )
                : null,
          ),
          InkWell(
            onTap: _showPhotoOptionsDialog,
            borderRadius: BorderRadius.circular(20),
            child: Container(
              padding: const EdgeInsets.all(8),
              decoration: const BoxDecoration(
                color: DriverTheme.electricBlue,
                shape: BoxShape.circle,
                boxShadow: [BoxShadow(color: Colors.black45, blurRadius: 4)],
              ),
              child: const Icon(Icons.camera_alt, size: 18, color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: DriverTheme.darkBg,
      appBar: AppBar(
        title: Text(_isRegister ? 'PENDAFTARAN MITRA DRIVER' : 'MASUK AKUN DRIVER'),
        elevation: 0,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const DriverOfflineBanner(),
              // Header Card
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [DriverTheme.surfaceDark, DriverTheme.cardDark],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: DriverTheme.electricBlue.withValues(alpha: 0.4)),
                  boxShadow: [
                    BoxShadow(
                      color: DriverTheme.electricBlue.withValues(alpha: 0.15),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Row(
                  children: [
                    Container(
                      width: 52,
                      height: 52,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(color: DriverTheme.brightCyan, width: 2),
                        boxShadow: [
                          BoxShadow(
                            color: DriverTheme.brightCyan.withValues(alpha: 0.3),
                            blurRadius: 8,
                            spreadRadius: 1,
                          ),
                        ],
                      ),
                      child: ClipOval(
                        child: Image.asset(
                          'assets/images/app_logo.png',
                          fit: BoxFit.cover,
                        ),
                      ),
                    ),
                    const SizedBox(width: 14),
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'MITRA RBT PIDIE',
                            style: TextStyle(
                              color: DriverTheme.textPrimary,
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                              letterSpacing: 0.5,
                            ),
                          ),
                          SizedBox(height: 4),
                          Text(
                            'Aplikasi Resmi Pengemudi & Pengantar Makanan Kab. Pidie',
                            style: TextStyle(
                              color: DriverTheme.textSecondary,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 20),

              // Tab Selector: Masuk / Daftar
              Container(
                decoration: BoxDecoration(
                  color: DriverTheme.surfaceDark,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: DriverTheme.cardBorder),
                ),
                padding: const EdgeInsets.all(4),
                child: Row(
                  children: [
                    Expanded(
                      child: InkWell(
                        onTap: () => setState(() => _isRegister = false),
                        borderRadius: BorderRadius.circular(10),
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          decoration: BoxDecoration(
                            color: !_isRegister ? DriverTheme.electricBlue : Colors.transparent,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            'Masuk Driver',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: !_isRegister ? Colors.white : DriverTheme.textMuted,
                            ),
                          ),
                        ),
                      ),
                    ),
                    Expanded(
                      child: InkWell(
                        onTap: () => setState(() => _isRegister = true),
                        borderRadius: BorderRadius.circular(10),
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          decoration: BoxDecoration(
                            color: _isRegister ? DriverTheme.electricBlue : Colors.transparent,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            'Daftar Mitra Baru',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: _isRegister ? Colors.white : DriverTheme.textMuted,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 20),

              // Form fields
              if (_isRegister) ...[
                // Foto Profil
                _buildPhotoAvatar(),
                const SizedBox(height: 8),
                Center(
                  child: TextButton.icon(
                    onPressed: _showPhotoOptionsDialog,
                    icon: const Icon(Icons.add_a_photo, size: 16, color: DriverTheme.brightCyan),
                    label: const Text(
                      'Pilih Foto Profil Driver',
                      style: TextStyle(color: DriverTheme.brightCyan, fontSize: 12),
                    ),
                  ),
                ),
                const SizedBox(height: 12),

                // Nama Driver
                TextFormField(
                  controller: _nameController,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    labelText: 'Nama Lengkap / Panggilan',
                    hintText: 'Contoh: Rizki Munandar',
                    prefixIcon: const Icon(Icons.person, color: DriverTheme.brightCyan),
                  ),
                  validator: (val) {
                    if (val == null || val.trim().isEmpty) {
                      return 'Nama driver wajib diisi.';
                    }
                    final trimmed = val.trim();
                    if (trimmed.length < 2) {
                      return 'Nama driver minimal 2 karakter.';
                    }
                    if (trimmed.length > 50) {
                      return 'Nama driver maksimal 50 karakter.';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 14),
              ],

              // Nomor Handphone / WhatsApp
              TextFormField(
                controller: _phoneController,
                keyboardType: TextInputType.phone,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  labelText: 'Nomor WhatsApp Driver',
                  hintText: 'Contoh: 081234567890',
                  prefixIcon: const Icon(Icons.phone_android, color: DriverTheme.brightCyan),
                ),
                validator: (val) {
                  if (val == null || val.trim().isEmpty) {
                    return 'Nomor WhatsApp wajib diisi.';
                  }
                  if (!DriverService.isValidIndonesianPhone(val)) {
                    return 'Format WhatsApp tidak valid (contoh: 081234567890).';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 14),

              if (_isRegister) ...[
                // Nomor Plat Kendaraan
                TextFormField(
                  controller: _plateController,
                  textCapitalization: TextCapitalization.characters,
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, letterSpacing: 1),
                  decoration: InputDecoration(
                    labelText: 'Nomor Plat Kendaraan',
                    hintText: 'Contoh: BL 4528 ZB',
                    prefixIcon: const Icon(Icons.confirmation_number, color: DriverTheme.brightCyan),
                  ),
                  validator: (val) {
                    if (val == null || val.trim().isEmpty) {
                      return 'Nomor plat kendaraan wajib diisi.';
                    }
                    final upper = val.trim().toUpperCase();
                    final plateRegex = RegExp(r'^[A-Z]{1,2}\s*[0-9]{1,4}\s*[A-Z]{1,3}$');
                    if (!plateRegex.hasMatch(upper)) {
                      return 'Format plat tidak valid (contoh: BL 4528 ZB).';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 14),

                // Tipe Motor
                TextFormField(
                  controller: _vehicleController,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    labelText: 'Tipe Motor / Kendaraan',
                    hintText: 'Contoh: Honda Vario 160 / Yamaha NMAX',
                    prefixIcon: const Icon(Icons.two_wheeler, color: DriverTheme.brightCyan),
                  ),
                  validator: (val) {
                    if (val == null || val.trim().isEmpty) {
                      return 'Tipe motor wajib diisi.';
                    }
                    final trimmed = val.trim();
                    if (trimmed.length < 2 || trimmed.length > 50) {
                      return 'Tipe motor antara 2-50 karakter.';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 8),

                // Quick suggestions for vehicle
                Wrap(
                  spacing: 6,
                  children: ['Honda Vario', 'Honda Scoopy', 'Honda Beat', 'Yamaha NMAX', 'Honda PCX']
                      .map((veh) => ActionChip(
                            label: Text(veh, style: const TextStyle(fontSize: 11, color: Colors.white)),
                            backgroundColor: DriverTheme.surfaceDark,
                            side: const BorderSide(color: DriverTheme.cardBorder),
                            onPressed: () {
                              _vehicleController.text = veh;
                            },
                          ))
                      .toList(),
                ),
                const SizedBox(height: 14),
              ],

              // Kata Sandi
              TextFormField(
                controller: _passwordController,
                obscureText: _obscurePassword,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  labelText: 'Kata Sandi (Password)',
                  hintText: 'Minimal 6 karakter',
                  prefixIcon: const Icon(Icons.lock_outline, color: DriverTheme.brightCyan),
                  suffixIcon: IconButton(
                    icon: Icon(
                      _obscurePassword ? Icons.visibility_off : Icons.visibility,
                      color: DriverTheme.textMuted,
                    ),
                    onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                  ),
                ),
                validator: (val) {
                  if (val == null || val.trim().isEmpty) {
                    return 'Kata sandi wajib diisi.';
                  }
                  if (val.length < 6) {
                    return 'Kata sandi minimal 6 karakter.';
                  }
                  if (val.length > 72) {
                    return 'Kata sandi maksimal 72 karakter.';
                  }
                  return null;
                },
              ),

              if (_isRegister) ...[
                const SizedBox(height: 14),
                // Konfirmasi Kata Sandi
                TextFormField(
                  controller: _confirmPasswordController,
                  obscureText: _obscureConfirmPassword,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    labelText: 'Ulangi Kata Sandi',
                    hintText: 'Ketik ulang kata sandi di atas',
                    prefixIcon: const Icon(Icons.lock_reset, color: DriverTheme.brightCyan),
                    suffixIcon: IconButton(
                      icon: Icon(
                        _obscureConfirmPassword ? Icons.visibility_off : Icons.visibility,
                        color: DriverTheme.textMuted,
                      ),
                      onPressed: () => setState(() => _obscureConfirmPassword = !_obscureConfirmPassword),
                    ),
                  ),
                  validator: (val) {
                    if (val == null || val.trim().isEmpty) {
                      return 'Konfirmasi kata sandi wajib diisi.';
                    }
                    if (val != _passwordController.text) {
                      return 'Kata sandi tidak sama.';
                    }
                    return null;
                  },
                ),
              ],

              const SizedBox(height: 24),

              // Tombol Submit
              ElevatedButton(
                onPressed: _isLoading ? null : _submit,
                style: ElevatedButton.styleFrom(
                  backgroundColor: DriverTheme.electricBlue,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  elevation: 4,
                ),
                child: _isLoading
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                      )
                    : Text(
                        _isRegister ? 'Daftar Mitra RBT Sekarang' : 'Masuk Sebagai Mitra',
                        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                      ),
              ),

              const SizedBox(height: 16),

              // Footer Info
              Center(
                child: Text(
                  _isRegister
                      ? 'Sudah punya akun mitra? Klik tab Masuk Driver di atas'
                      : 'Belum terdaftar? Klik tab Daftar Mitra Baru di atas',
                  style: const TextStyle(fontSize: 12, color: DriverTheme.textMuted),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
