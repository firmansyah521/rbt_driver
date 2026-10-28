import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../constants/driver_theme.dart';

/// Tombol Geser / Slide Ala Grab Driver ("Geser untuk Selesaikan Orderan").
/// Mencegah ketidaksengajaan klik di jalanan Pidie, dengan animasi tarikan mulus,
/// efek haptic feedback, dan indikator panah berdenyut.
class GrabSlideButton extends StatefulWidget {
  final String label;
  final String? sublabel;
  final VoidCallback onSlideComplete;
  final Color? trackColor;
  final Color? sliderColor;
  final IconData icon;
  final double height;

  const GrabSlideButton({
    super.key,
    this.label = 'GESER UNTUK SELESAIKAN',
    this.sublabel,
    required this.onSlideComplete,
    this.trackColor,
    this.sliderColor,
    this.icon = Icons.keyboard_double_arrow_right_rounded,
    this.height = 56.0,
  });

  @override
  State<GrabSlideButton> createState() => GrabSlideButtonState();
}

class GrabSlideButtonState extends State<GrabSlideButton>
    with SingleTickerProviderStateMixin {
  double _dragPosition = 0.0;
  bool _isCompleted = false;
  late AnimationController _animController;
  Animation<double>? _resetAnimation;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
    );
    _animController.addListener(() {
      if (_resetAnimation != null) {
        setState(() {
          _dragPosition = _resetAnimation!.value;
        });
      }
    });
  }

  @override
  void dispose() {
    _animController.dispose();
    super.dispose();
  }

  /// Reset slider kembali ke posisi awal (digunakan bila konfirmasi dibatalkan)
  void reset() {
    if (!mounted) return;
    setState(() {
      _isCompleted = false;
    });
    _animateToPosition(0.0);
  }

  void _animateToPosition(double target) {
    _resetAnimation = Tween<double>(begin: _dragPosition, end: target).animate(
      CurvedAnimation(parent: _animController, curve: Curves.easeOutCubic),
    );
    _animController.forward(from: 0.0);
  }

  @override
  Widget build(BuildContext context) {
    final effectiveTrackColor =
        widget.trackColor ?? const Color(0xFF161616); // Uber Sleek Obsidian
    final effectiveSliderColor =
        widget.sliderColor ?? DriverTheme.onlineGreen; // Uber vibrant green
    final thumbSize = widget.height - 8.0;

    return LayoutBuilder(
      builder: (context, constraints) {
        final maxDrag = constraints.maxWidth - thumbSize - 8.0;

        return Container(
          width: double.infinity,
          height: widget.height,
          decoration: BoxDecoration(
            color: effectiveTrackColor,
            borderRadius: BorderRadius.circular(widget.height / 2),
            border: Border.all(
              color: DriverTheme.cardBorder,
              width: 1.2,
            ),
            boxShadow: const [
              BoxShadow(
                color: Color(0x33000000),
                blurRadius: 6,
                offset: Offset(0, 2),
              ),
            ],
          ),
          child: Stack(
            alignment: Alignment.centerLeft,
            children: [
              // 1. ACTIVE PROGRESS TRACK (Fill hijau mengikuti tarikan)
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                width: _dragPosition + (thumbSize / 2) + 4.0,
                child: Container(
                  decoration: BoxDecoration(
                    color: effectiveSliderColor.withValues(alpha: 0.25),
                    borderRadius: BorderRadius.circular(widget.height / 2),
                  ),
                ),
              ),

              // 2. TEKS & PANAH ANIMASI ALA GRAB
              Center(
                child: Opacity(
                  opacity: (1.0 - (_dragPosition / (maxDrag > 0 ? maxDrag : 1.0)) * 1.5)
                      .clamp(0.0, 1.0),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(width: 40), // Ruang untuk thumb di kiri
                      Flexible(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              widget.label,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 13,
                                fontWeight: FontWeight.bold,
                                letterSpacing: 0.8,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            if (widget.sublabel != null)
                              Text(
                                widget.sublabel!,
                                style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.85),
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 6),
                      Icon(
                        Icons.chevron_right_rounded,
                        color: Colors.white.withValues(alpha: 0.7),
                        size: 20,
                      ),
                      Icon(
                        Icons.chevron_right_rounded,
                        color: Colors.white.withValues(alpha: 0.4),
                        size: 20,
                      ),
                    ],
                  ),
                ),
              ),

              // 3. THUMB GESER (KNOB DRAGGABLE DENGAN GESTURE DETECTOR)
              Positioned(
                left: 4.0 + _dragPosition,
                child: GestureDetector(
                  onHorizontalDragUpdate: (details) {
                    if (_isCompleted) return;
                    _animController.stop();
                    setState(() {
                      _dragPosition = (_dragPosition + details.delta.dx)
                          .clamp(0.0, maxDrag);
                    });
                  },
                  onHorizontalDragEnd: (details) {
                    if (_isCompleted) return;

                    // Jika digeser lebih dari 75% track -> Selesaikan
                    if (_dragPosition >= maxDrag * 0.75) {
                      _animateToPosition(maxDrag);
                      setState(() {
                        _isCompleted = true;
                      });
                      HapticFeedback.heavyImpact();
                      widget.onSlideComplete();
                    } else {
                      // Jika dilepas sebelum batas -> Kembali mulus ke kiri
                      _animateToPosition(0.0);
                    }
                  },
                  child: Container(
                    width: thumbSize,
                    height: thumbSize,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          effectiveSliderColor,
                          const Color(0xFF059669),
                        ],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 2.5),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.35),
                          blurRadius: 6,
                          offset: const Offset(2, 2),
                        ),
                        BoxShadow(
                          color: effectiveSliderColor.withValues(alpha: 0.6),
                          blurRadius: 10,
                          spreadRadius: 1,
                        ),
                      ],
                    ),
                    child: Icon(
                      widget.icon,
                      color: Colors.white,
                      size: 28,
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
