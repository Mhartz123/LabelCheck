import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../models/scan_record.dart';

/// Draws a packaging photo with the damage model's detection boxes on top.
///
/// [DamageDetection] rects are normalised 0..1 against the source photo, so
/// the only thing needed to place them is the image's own aspect ratio: an
/// [AspectRatio] sized to the photo makes every fit mode equivalent, and the
/// fractions then scale straight to layout pixels. The dimensions are resolved
/// from the decoded image rather than assumed, because a portrait capture and
/// a landscape one need different boxes.
///
/// Until the image resolves the widget renders the photo alone — the boxes
/// appear a frame later rather than landing in the wrong place.
class DamageOverlay extends StatefulWidget {
  final File photo;
  final List<DamageDetection> detections;

  /// Drawn at the size the parent gives it; wrap in a [SizedBox] to constrain.
  const DamageOverlay({
    super.key,
    required this.photo,
    required this.detections,
  });

  @override
  State<DamageOverlay> createState() => _DamageOverlayState();
}

class _DamageOverlayState extends State<DamageOverlay> {
  ImageStream? _stream;
  ImageStreamListener? _listener;
  double? _aspect;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolve();
  }

  @override
  void didUpdateWidget(DamageOverlay old) {
    super.didUpdateWidget(old);
    if (old.photo.path != widget.photo.path) {
      _aspect = null;
      _resolve();
    }
  }

  void _resolve() {
    _detach();
    final provider = FileImage(widget.photo);
    final stream = provider.resolve(createLocalImageConfiguration(context));
    final listener = ImageStreamListener((ImageInfo info, bool _) {
      final ui.Image image = info.image;
      final aspect = image.width / image.height;
      info.dispose();
      if (!mounted) return;
      if (_aspect != aspect) setState(() => _aspect = aspect);
    }, onError: (_, __) {
      // A missing or unreadable photo just renders as the plain Image below,
      // which shows its own error placeholder. Nothing to add here.
    });
    stream.addListener(listener);
    _stream = stream;
    _listener = listener;
  }

  void _detach() {
    if (_stream != null && _listener != null) {
      _stream!.removeListener(_listener!);
    }
    _stream = null;
    _listener = null;
  }

  @override
  void dispose() {
    _detach();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final image = Image.file(widget.photo, fit: BoxFit.cover);
    final aspect = _aspect;
    if (aspect == null || widget.detections.isEmpty) return image;

    return AspectRatio(
      aspectRatio: aspect,
      child: Stack(
        fit: StackFit.expand,
        children: [
          image,
          CustomPaint(painter: _BoxPainter(widget.detections)),
        ],
      ),
    );
  }
}

class _BoxPainter extends CustomPainter {
  final List<DamageDetection> detections;

  _BoxPainter(this.detections);

  // Amber reads as "look here" against both the green app chrome and the
  // brown/white cardboard these photos are mostly made of, where the app's
  // own red/green status colours would either vanish or imply a verdict.
  static const _stroke = Color(0xFFFFB300);
  static const _chip = Color(0xFFE65100);

  @override
  void paint(Canvas canvas, Size size) {
    final border = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..color = _stroke;
    // A dark halo keeps the box visible on a light box face too.
    final halo = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4.5
      ..color = Colors.black.withValues(alpha: 0.35);

    for (final d in detections) {
      final rect = Rect.fromLTWH(
        d.left * size.width,
        d.top * size.height,
        d.width * size.width,
        d.height * size.height,
      );
      final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(4));
      canvas.drawRRect(rrect, halo);
      canvas.drawRRect(rrect, border);
      _paintChip(canvas, size, rect, '${d.label} ${d.confidenceLabel}');
    }
  }

  void _paintChip(Canvas canvas, Size size, Rect box, String text) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 10,
          fontWeight: FontWeight.w700,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    const padH = 5.0, padV = 2.5;
    final w = painter.width + padH * 2;
    final h = painter.height + padV * 2;

    // Prefer sitting just above the box; drop inside its top edge when the
    // box is already at the top of the frame, and pull left when it would
    // otherwise run off the right edge.
    var left = box.left;
    if (left + w > size.width) left = size.width - w;
    if (left < 0) left = 0;
    var top = box.top - h - 2;
    if (top < 0) top = box.top + 2;

    final chip = RRect.fromRectAndRadius(
      Rect.fromLTWH(left, top, w, h),
      const Radius.circular(3),
    );
    canvas.drawRRect(chip, Paint()..color = _chip);
    painter.paint(canvas, Offset(left + padH, top + padV));
  }

  @override
  bool shouldRepaint(_BoxPainter old) => old.detections != detections;
}

/// The "where the damage was found" block: one annotated photo per packaging
/// shot that carries a detection.
///
/// Shared by the results screen and a saved record's detail screen so both
/// show the same evidence the same way — they differ only in where the photos
/// come from (a just-finished scan's temp files vs. the record folder).
///
/// Renders nothing at all when there is no geometry to draw: records saved
/// before boxes were stored, detectors that report classes without
/// coordinates, and clean scans all fall through to the caller's text summary.
class DamageEvidence extends StatelessWidget {
  /// Packaging photos in [BoxSlot] order — the order
  /// [DamageDetection.sourceIndex] counts in.
  final List<File> photos;
  final List<DamageDetection> detections;

  /// Colour for the heading, so the block sits inside either screen's
  /// damage card without fighting its palette.
  final Color foreground;

  const DamageEvidence({
    super.key,
    required this.photos,
    required this.detections,
    required this.foreground,
  });

  @override
  Widget build(BuildContext context) {
    if (photos.isEmpty || detections.isEmpty) return const SizedBox.shrink();

    final byPhoto = <int, List<DamageDetection>>{};
    for (final d in detections) {
      if (d.sourceIndex < 0 || d.sourceIndex >= photos.length) continue;
      byPhoto.putIfAbsent(d.sourceIndex, () => []).add(d);
    }
    if (byPhoto.isEmpty) return const SizedBox.shrink();

    final indices = byPhoto.keys.toList()..sort();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 12),
        Text(
          indices.length == 1
              ? 'Where the damage was found'
              : 'Where the damage was found (${indices.length} photos)',
          style: TextStyle(
              fontSize: 11.5, fontWeight: FontWeight.w700, color: foreground),
        ),
        const SizedBox(height: 8),
        for (final i in indices) ...[
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: DamageOverlay(
              photo: photos[i],
              detections: byPhoto[i]!,
            ),
          ),
          const SizedBox(height: 8),
        ],
      ],
    );
  }
}
