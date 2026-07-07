import 'dart:io';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import '../main.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import '../models/scan_record.dart';
import '../services/compliance_engine.dart';
import '../services/scan_store.dart';
import '../services/report_service.dart';
import 'result_screen.dart';

/// Static definition of one capture step in the camera flow.
class SlotSpec {
  final PhotoSlot slot;
  final String title;
  final String helper;
  final bool alwaysOptional;

  const SlotSpec({
    required this.slot,
    required this.title,
    required this.helper,
    this.alwaysOptional = false,
  });
}

const List<SlotSpec> _allSlots = [
  SlotSpec(
    slot: PhotoSlot.front,
    title: 'Front label',
    helper: 'Frame the product name & main label inside the guide',
  ),
  SlotSpec(
    slot: PhotoSlot.back,
    title: 'Back label',
    helper: 'Frame the ingredients & FDA Reg. No. side inside the guide',
  ),
  SlotSpec(
    slot: PhotoSlot.side1,
    title: 'Side label',
    helper: 'Frame any additional label details inside the guide',
  ),
  SlotSpec(
    slot: PhotoSlot.side2,
    title: 'Side label (extra)',
    helper: 'Optional — capture another angle if useful',
    alwaysOptional: true,
  ),
];

class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen>
    with WidgetsBindingObserver {
  CameraController? _controller;
  bool _isReady = false;
  bool _isTaking = false;
  bool _isProcessing = false;
  bool _isFlashOn = false;
  int _cameraIndex = 0;

  // Zoom
  double _currentZoom = 1.0;
  double _baseZoom = 1.0;
  double _minZoom = 1.0;
  double _maxZoom = 1.0;

  // Focus
  Offset? _focusPoint;

  // ── Multi-shot capture state ────────────────────────────────────────────
  int _currentSlotIndex = 0;
  bool _skipBackConfirmed = false;
  final Map<PhotoSlot, String> _capturedPaths = {};

  List<SlotSpec> get _activeSlots {
    if (_skipBackConfirmed) {
      return _allSlots.where((s) => s.slot != PhotoSlot.back).toList();
    }
    return _allSlots;
  }

  SlotSpec get _currentSlot => _activeSlots[_currentSlotIndex];
  int get _totalSlots => _activeSlots.length;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initCamera(_cameraIndex);
  }

  Future<void> _initCamera(int index) async {
    if (globalCameras.isEmpty) return;
    final prev = _controller;
    if (prev != null) await prev.dispose();

    final controller = CameraController(
      globalCameras[index],
      ResolutionPreset.high,
      enableAudio: false,
    );
    _controller = controller;
    try {
      await controller.initialize();
      _minZoom = await controller.getMinZoomLevel();
      _maxZoom = await controller.getMaxZoomLevel();
      _currentZoom = _minZoom;
      if (mounted) setState(() => _isReady = true);
    } catch (e) {
      debugPrint('Camera init error: $e');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_controller == null || !_controller!.value.isInitialized) return;
    if (state == AppLifecycleState.inactive) {
      _controller?.dispose();
      if (mounted) setState(() => _isReady = false);
    } else if (state == AppLifecycleState.resumed) {
      _initCamera(_cameraIndex);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
    // Best-effort cleanup of any temp photos abandoned mid-flow.
    for (final path in _capturedPaths.values) {
      try {
        final f = File(path);
        if (f.existsSync()) f.deleteSync();
      } catch (_) {}
    }
    super.dispose();
  }

  Future<void> _switchCamera() async {
    if (globalCameras.length < 2) return;
    setState(() => _isReady = false);
    _cameraIndex = (_cameraIndex + 1) % globalCameras.length;
    await _initCamera(_cameraIndex);
  }

  Future<void> _toggleFlash() async {
    if (_controller == null || !_controller!.value.isInitialized) return;
    setState(() => _isFlashOn = !_isFlashOn);
    await _controller!
        .setFlashMode(_isFlashOn ? FlashMode.torch : FlashMode.off);
  }

  // ── Pinch to zoom ──────────────────────────────────────────────────────────
  void _onScaleStart(ScaleStartDetails details) {
    _baseZoom = _currentZoom;
  }

  Future<void> _onScaleUpdate(ScaleUpdateDetails details) async {
    if (_controller == null || !_controller!.value.isInitialized) return;
    if (details.pointerCount < 2) return; // only act on pinch, not single tap
    final newZoom = (_baseZoom * details.scale).clamp(_minZoom, _maxZoom);
    if ((newZoom - _currentZoom).abs() < 0.01) return; // skip tiny changes
    setState(() => _currentZoom = newZoom);
    await _controller!.setZoomLevel(newZoom);
  }

  // ── Tap to focus ───────────────────────────────────────────────────────────
  Future<void> _onTapFocus(TapUpDetails details) async {
    if (_controller == null || !_controller!.value.isInitialized) return;
    final RenderBox box = context.findRenderObject() as RenderBox;
    final Offset localPos = box.globalToLocal(details.globalPosition);
    final double x = (localPos.dx / box.size.width).clamp(0.0, 1.0);
    final double y = (localPos.dy / box.size.height).clamp(0.0, 1.0);

    try {
      await _controller!.setFocusMode(FocusMode.auto);
      await _controller!.setFocusPoint(Offset(x, y));
      await _controller!.setExposurePoint(Offset(x, y));
    } catch (e) {
      debugPrint('Focus error: $e');
    }

    setState(() {
      _focusPoint = localPos;
    });
  }

  // ── Skip controls ───────────────────────────────────────────────────────
  void _onSkipBackTap() {
    // Do NOT touch _currentSlotIndex — splicing Back out of _activeSlots
    // naturally shifts Side1 into the current index.
    setState(() => _skipBackConfirmed = true);
  }

  void _onSkipCurrentSlot() {
    _advanceOrFinish();
  }

  // ── Take photo ─────────────────────────────────────────────────────────────
  Future<void> _takePhoto() async {
    if (_controller == null || !_controller!.value.isInitialized) return;
    if (_isTaking || _isProcessing) return;
    setState(() => _isTaking = true);

    try {
      final XFile photo = await _controller!.takePicture();
      _capturedPaths[_currentSlot.slot] = photo.path;
      await _advanceOrFinish();
    } catch (e) {
      debugPrint('Capture error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Capture failed. Try again.'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isTaking = false);
    }
  }

  Future<void> _advanceOrFinish() async {
    if (_currentSlotIndex < _totalSlots - 1) {
      setState(() => _currentSlotIndex++);
    } else {
      await _runOcrAndClassify();
    }
  }

  // ── OCR across all captured photos, then classify ──────────────────────
  Future<void> _runOcrAndClassify() async {
    setState(() => _isProcessing = true);

    const orderedSlots = [
      PhotoSlot.front,
      PhotoSlot.back,
      PhotoSlot.side1,
      PhotoSlot.side2,
    ];
    final orderedPaths = [
      for (final s in orderedSlots)
        if (_capturedPaths[s] != null) _capturedPaths[s]!,
    ];

    final textRecognizer = TextRecognizer();
    final buffer = StringBuffer();
    try {
      for (final path in orderedPaths) {
        final inputImage = InputImage.fromFilePath(path);
        final recognized = await textRecognizer.processImage(inputImage);
        if (buffer.isNotEmpty) buffer.write('\n\n');
        buffer.write(recognized.text);
      }
    } catch (e) {
      debugPrint('OCR error: $e');
    } finally {
      await textRecognizer.close();
    }

    final combinedText = buffer.toString();
    final record = await ComplianceEngine.analyze(
      combinedText: combinedText,
      photoPaths: orderedPaths,
    );

    if (mounted) setState(() => _isProcessing = false);

    if (mounted) {
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ResultScreen(record: record),
        ),
      );
      if (mounted) _showSaveSheet(record);
    }
  }

  // ── Check duplicate name ───────────────────────────────────────────────────
  Future<bool> _nameExists(String raw) => ScanStore.recordExists(raw);

  void _resetCaptureFlow() {
    setState(() {
      _capturedPaths.clear();
      _currentSlotIndex = 0;
      _skipBackConfirmed = false;
    });
  }

  void _discardCapturedPhotos() {
    for (final path in _capturedPaths.values) {
      final f = File(path);
      if (f.existsSync()) f.deleteSync();
    }
    _resetCaptureFlow();
  }

  // ── Save Record bottom sheet ───────────────────────────────────────────────
  void _showSaveSheet(ScanRecord record) {
    final TextEditingController nameController = TextEditingController();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      isDismissible: false,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        bool isTaken = false;
        bool isEmpty = true;

        return StatefulBuilder(
          builder: (context, setSheetState) {
            void onChanged(String val) async {
              final taken = await _nameExists(val);
              setSheetState(() {
                isTaken = taken;
                isEmpty = val.trim().isEmpty;
              });
            }

            return Padding(
              padding: EdgeInsets.only(
                left: 20,
                right: 20,
                top: 20,
                bottom: MediaQuery.of(context).viewInsets.bottom + 20,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: const Color(0xFFD4A847),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Text(
                      'User Instruction - Save Record',
                      style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 14),
                    ),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: nameController,
                    autofocus: true,
                    onChanged: onChanged,
                    decoration: InputDecoration(
                      hintText: 'Record name',
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 10),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(
                          color: isTaken
                              ? const Color(0xFFE57373)
                              : Colors.grey.shade400,
                        ),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(
                          color: isTaken
                              ? const Color(0xFFE57373)
                              : const Color(0xFF4CAF50),
                          width: 2,
                        ),
                      ),
                      errorText: isTaken
                          ? 'This name is already taken. Please choose another.'
                          : null,
                      errorStyle: const TextStyle(
                          color: Color(0xFFE57373), fontSize: 11),
                      errorBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide:
                        const BorderSide(color: Color(0xFFE57373)),
                      ),
                      focusedErrorBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(
                            color: Color(0xFFE57373), width: 2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    '*Please input a name for the record you just scanned.',
                    style: TextStyle(fontSize: 12, color: Colors.black54),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    '*Note: once saved, this name cannot be changed.',
                    style: TextStyle(fontSize: 12, color: Colors.black54),
                  ),
                  const SizedBox(height: 6),
                  const Text('Example :',
                      style:
                      TextStyle(fontSize: 12, color: Colors.black54)),
                  const Text(
                    'Loaf_of_bread',
                    style: TextStyle(
                        fontSize: 12,
                        color: Colors.black54,
                        fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 20),
                  Row(
                    children: [
                      Expanded(
                        child: ElevatedButton(
                          onPressed: () {
                            Navigator.of(context).pop();
                            _discardCapturedPhotos();
                          },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFFE57373),
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10)),
                            padding:
                            const EdgeInsets.symmetric(vertical: 14),
                          ),
                          child: const Text('Cancel',
                              style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.bold)),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: ElevatedButton(
                          onPressed: (isEmpty || isTaken)
                              ? null
                              : () async {
                            final raw = nameController.text.trim();
                            Navigator.of(context).pop();
                            await _saveRecord(raw, record);
                          },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF4CAF50),
                            foregroundColor: Colors.white,
                            disabledBackgroundColor: Colors.grey.shade300,
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10)),
                            padding:
                            const EdgeInsets.symmetric(vertical: 14),
                          ),
                          child: const Text('Save',
                              style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.bold)),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  // ── Save record ─────────────────────────────────────────────────────────────
  Future<void> _saveRecord(String rawName, ScanRecord record) async {
    try {
      final dir = await ScanStore.save(
        rawName: rawName,
        capturedPhotoPaths: Map.of(_capturedPaths),
        record: record,
      );

      // Submit flagged results to central dashboard (fire-and-forget)
      ReportService.submit(
        recordDir: dir,
        record: record,
        productName: rawName,
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Record "$rawName" saved!'),
            backgroundColor: const Color(0xFF4CAF50),
          ),
        );
      }
      _resetCaptureFlow();
    } catch (e) {
      debugPrint('Save record error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Failed to save record.'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  // ── Build ──────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    if (!_isReady || _controller == null) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CircularProgressIndicator(color: Colors.white),
              SizedBox(height: 16),
              Text('Starting camera...',
                  style: TextStyle(color: Colors.white)),
            ],
          ),
        ),
      );
    }

    final slot = _currentSlot;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Camera preview — GestureDetector wraps it for pinch + tap
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onScaleStart: _onScaleStart,
            onScaleUpdate: _onScaleUpdate,
            onTapUp: _onTapFocus,
            child: CameraPreview(_controller!),
          ),

          // Framing guide
          IgnorePointer(
            child: Center(
              child: Container(
                width: 240,
                height: 240,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.85),
                    width: 1.5,
                  ),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: _currentZoom > _minZoom + 0.05
                    ? Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '${_currentZoom.toStringAsFixed(1)}x',
                    style: const TextStyle(
                        color: Colors.white, fontSize: 14),
                  ),
                )
                    : null,
              ),
            ),
          ),

          // Focus circle indicator — always in tree, animates on each tap
          if (_focusPoint != null)
            Positioned(
              left: _focusPoint!.dx - 35,
              top: _focusPoint!.dy - 35,
              child: _FocusCircle(
                key: ValueKey(_focusPoint), // new key = fresh animation on every tap
                visible: true,
              ),
            ),

          // Top step header
          Positioned(
            top: 56,
            left: 20,
            right: 20,
            child: Column(
              children: [
                Container(
                  padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  decoration: BoxDecoration(
                    color: const Color(0xFF4CAF50),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    'PHOTO ${_currentSlotIndex + 1} OF $_totalSlots',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.6,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  slot.title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  slot.helper,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.8),
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 10),
                if (slot.slot == PhotoSlot.back && !_skipBackConfirmed)
                  GestureDetector(
                    onTap: _onSkipBackTap,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.55),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                            color: Colors.white.withValues(alpha: 0.4)),
                      ),
                      child: const Text(
                        'Front & back identical? · Skip to 3 photos',
                        style: TextStyle(color: Colors.white, fontSize: 11.5),
                      ),
                    ),
                  ),
                if (slot.alwaysOptional)
                  TextButton(
                    onPressed: _onSkipCurrentSlot,
                    child: const Text(
                      'Skip this photo (optional)',
                      style: TextStyle(color: Colors.white, fontSize: 12.5),
                    ),
                  ),
              ],
            ),
          ),

          if (_isProcessing)
            Container(
              color: Colors.black.withValues(alpha: 0.6),
              child: const Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    CircularProgressIndicator(color: Colors.white),
                    SizedBox(height: 16),
                    Text('Analyzing label...',
                        style: TextStyle(color: Colors.white)),
                  ],
                ),
              ),
            ),

          // Thumbnail strip
          Positioned(
            bottom: 120,
            left: 0,
            right: 0,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: _allSlots.map((s) {
                final isSkippedBack =
                    s.slot == PhotoSlot.back && _skipBackConfirmed;
                final isCaptured = _capturedPaths.containsKey(s.slot);
                final isCurrent = !isSkippedBack && s.slot == slot.slot;
                return _SlotThumbnail(
                  spec: s,
                  isCurrent: isCurrent,
                  isCaptured: isCaptured,
                  isSkipped: isSkippedBack,
                  imagePath: _capturedPaths[s.slot],
                );
              }).toList(),
            ),
          ),

          // Bottom controls — placed ABOVE gesture layer so buttons still work
          Positioned(
            bottom: 32,
            left: 0,
            right: 0,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _CircleButton(
                  color: Colors.black.withValues(alpha: 0.6),
                  icon: Icons.flip_camera_android,
                  iconColor: Colors.white,
                  size: 52,
                  onTap: _isProcessing ? null : _switchCamera,
                ),
                _CircleButton(
                  color: Colors.white,
                  icon: _isTaking ? null : Icons.circle,
                  iconColor: Colors.white,
                  size: 72,
                  onTap: (_isTaking || _isProcessing) ? null : _takePhoto,
                  isShutter: true,
                  isTaking: _isTaking,
                ),
                _CircleButton(
                  color: Colors.grey.withValues(alpha: 0.6),
                  icon: _isFlashOn ? Icons.flash_on : Icons.flash_off,
                  iconColor: Colors.white,
                  size: 52,
                  onTap: _isProcessing ? null : _toggleFlash,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Slot thumbnail ─────────────────────────────────────────────────────────────

class _SlotThumbnail extends StatelessWidget {
  final SlotSpec spec;
  final bool isCurrent;
  final bool isCaptured;
  final bool isSkipped;
  final String? imagePath;

  const _SlotThumbnail({
    required this.spec,
    required this.isCurrent,
    required this.isCaptured,
    required this.isSkipped,
    required this.imagePath,
  });

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: isSkipped ? 0.35 : 1.0,
      child: Column(
        children: [
          Stack(
            clipBehavior: Clip.none,
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: isCurrent
                        ? const Color(0xFF4CAF50)
                        : Colors.white.withValues(alpha: 0.4),
                    width: isCurrent ? 2.5 : 1,
                  ),
                  image: imagePath != null
                      ? DecorationImage(
                    image: FileImage(File(imagePath!)),
                    fit: BoxFit.cover,
                  )
                      : null,
                ),
                child: imagePath == null
                    ? Icon(Icons.image_outlined,
                    color: Colors.white.withValues(alpha: 0.5), size: 20)
                    : null,
              ),
              if (isCaptured)
                Positioned(
                  right: -2,
                  top: -2,
                  child: Container(
                    padding: const EdgeInsets.all(2),
                    decoration: const BoxDecoration(
                      color: Color(0xFF4CAF50),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.check,
                        size: 10, color: Colors.white),
                  ),
                ),
              if (spec.alwaysOptional)
                Positioned(
                  left: -6,
                  top: -6,
                  child: Container(
                    padding:
                    const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                    decoration: BoxDecoration(
                      color: Colors.black87,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Text('opt',
                        style: TextStyle(color: Colors.white, fontSize: 8)),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 3),
          Text(
            spec.title.split(' ').first,
            style: const TextStyle(color: Colors.white, fontSize: 10),
          ),
        ],
      ),
    );
  }
}

// ── Circle button ──────────────────────────────────────────────────────────────

class _CircleButton extends StatelessWidget {
  final Color color;
  final IconData? icon;
  final Color iconColor;
  final double size;
  final VoidCallback? onTap;
  final bool isShutter;
  final bool isTaking;

  const _CircleButton({
    required this.color,
    required this.icon,
    required this.iconColor,
    required this.size,
    required this.onTap,
    this.isShutter = false,
    this.isTaking = false,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: color,
          border: isShutter
              ? Border.all(color: Colors.white, width: 4)
              : null,
        ),
        child: isTaking
            ? const Padding(
          padding: EdgeInsets.all(16),
          child: CircularProgressIndicator(
              strokeWidth: 2, color: Colors.black),
        )
            : Icon(icon, color: iconColor, size: size * 0.45),
      ),
    );
  }
}

// ── Focus circle animation ─────────────────────────────────────────────────────

class _FocusCircle extends StatefulWidget {
  final bool visible;
  const _FocusCircle({super.key, required this.visible});

  @override
  State<_FocusCircle> createState() => _FocusCircleState();
}

class _FocusCircleState extends State<_FocusCircle>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _opacity;
  late Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );

    // Scale from slightly large → normal size (snappy lock-in feel)
    _scale = Tween<double>(begin: 1.3, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOut),
    );

    // Fade in quickly, then fade out toward the end
    _opacity = TweenSequence([
      TweenSequenceItem(
          tween: Tween<double>(begin: 0.0, end: 0.85), weight: 20),
      TweenSequenceItem(
          tween: Tween<double>(begin: 0.85, end: 0.85), weight: 50),
      TweenSequenceItem(
          tween: Tween<double>(begin: 0.85, end: 0.0), weight: 30),
    ]).animate(_controller);

    if (widget.visible) _controller.forward(from: 0);
  }

  @override
  void didUpdateWidget(_FocusCircle oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.visible && !oldWidget.visible) {
      _controller.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        return Opacity(
          opacity: _opacity.value,
          child: Transform.scale(
            scale: _scale.value,
            child: Container(
              width: 70,
              height: 70,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.9),
                  width: 1.5,
                ),
                color: Colors.white.withValues(alpha: 0.08),
              ),
            ),
          ),
        );
      },
    );
  }
}
