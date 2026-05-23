import 'dart:io';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import '../../services/fda_checker.dart';
import '../../services/scan_store.dart';
import 'package:permission_handler/permission_handler.dart';
import 'result_screen.dart';

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
  bool _isFlashOn = false;
  int _cameraIndex = 0;
  List<CameraDescription> _cameras = [];

  // Zoom
  double _currentZoom = 1.0;
  double _baseZoom = 1.0;
  double _minZoom = 1.0;
  double _maxZoom = 1.0;

  // Focus
  Offset? _focusPoint;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadCameras();
  }

  Future<void> _loadCameras() async {
    // Request storage + camera permissions before anything else
    await _requestPermissions();
    _cameras = await availableCameras();
    _initCamera(_cameraIndex);
  }

  Future<void> _requestPermissions() async {
    await Permission.camera.request();
    if (await Permission.photos.isDenied) await Permission.photos.request();
    if (await Permission.storage.isDenied) await Permission.storage.request();
    // Android 11+ needs MANAGE_EXTERNAL_STORAGE for /storage/emulated/0
    if (!await Permission.manageExternalStorage.isGranted) {
      await Permission.manageExternalStorage.request();
    }
  }

  Future<void> _initCamera(int index) async {
    if (_cameras.isEmpty) return;
    final prev = _controller;
    if (prev != null) await prev.dispose();

    final controller = CameraController(
      _cameras[index],
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
    super.dispose();
  }

  Future<void> _switchCamera() async {
    if (_cameras.length < 2) return;
    setState(() => _isReady = false);
    _cameraIndex = (_cameraIndex + 1) % _cameras.length;
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

  // ── Take photo ─────────────────────────────────────────────────────────────
  Future<void> _takePhoto() async {
    if (_controller == null || !_controller!.value.isInitialized) return;
    if (_isTaking) return;
    setState(() => _isTaking = true);

    try {
      final XFile photo = await _controller!.takePicture();

      // Run ML Kit OCR
      final inputImage = InputImage.fromFilePath(photo.path);
      final textRecognizer = TextRecognizer();
      final RecognizedText recognizedText =
      await textRecognizer.processImage(inputImage);
      await textRecognizer.close();

      final String extractedText = recognizedText.text;
      final ScanResult result = FdaChecker.classify(extractedText);

      // Show result screen first, then ask to save
      if (mounted) {
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => ResultScreen(result: result),
          ),
        );
        // After user returns from result screen, show save sheet
        if (mounted) _showSaveSheet(photo.path, result);
      }
    } catch (e) {
      debugPrint('Scan error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Scan failed. Try again.'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isTaking = false);
    }
  }

  // ── Resolve photos directory ───────────────────────────────────────────────
  Future<Directory> _getPhotoDir() async {
    const String publicPictures = '/storage/emulated/0/Pictures/VeriFyDA';
    final Directory photoDir = Directory(publicPictures);
    if (!await photoDir.exists()) await photoDir.create(recursive: true);
    return photoDir;
  }

  // ── Check duplicate name ───────────────────────────────────────────────────
  Future<bool> _nameExists(String raw) async {
    if (raw.trim().isEmpty) return false;
    final dir = await _getPhotoDir();
    String fileName = raw.trim();
    if (!fileName.endsWith('.jpeg')) fileName = '$fileName.jpeg';
    fileName = fileName.replaceAll(' ', '_');
    return File(p.join(dir.path, fileName)).existsSync();
  }

  // ── Save Record bottom sheet ───────────────────────────────────────────────
  void _showSaveSheet(String tempPath, ScanResult result) {
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
                      hintText: '.jpeg',
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
                    '*Please input a name for the picture you just took.',
                    style: TextStyle(fontSize: 12, color: Colors.black54),
                  ),
                  const SizedBox(height: 6),
                  const Text('Example :',
                      style:
                      TextStyle(fontSize: 12, color: Colors.black54)),
                  const Text(
                    'Loaf_of_bread.jpeg',
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
                            File(tempPath).deleteSync();
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
                            await _savePhoto(tempPath, raw, result);
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

  // ── Save photo ─────────────────────────────────────────────────────────────
  Future<void> _savePhoto(String tempPath, String rawName, ScanResult result) async {
    try {
      final dir = await _getPhotoDir();
      String fileName =
      rawName.endsWith('.jpeg') ? rawName : '$rawName.jpeg';
      fileName = fileName.replaceAll(' ', '_');
      final String destPath = p.join(dir.path, fileName);
      await File(tempPath).copy(destPath);

      // Save scan result alongside the photo
      await ScanStore.save(
        photoPath: destPath,
        status: result.statusLabel,
        matchedKeyword: result.matchedKeyword,
        extractedText: result.extractedText,
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Photo "$fileName" saved!'),
            backgroundColor: const Color(0xFF4CAF50),
          ),
        );
      }
    } catch (e, st) {
      debugPrint('Save photo error: $e\n$st');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Save failed: $e'),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 6),
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

          // Zoom level badge
          if (_currentZoom > _minZoom + 0.05)
            Positioned(
              top: 60,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
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
                ),
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
                  onTap: _switchCamera,
                ),
                _CircleButton(
                  color: Colors.white,
                  icon: _isTaking ? null : Icons.circle,
                  iconColor: Colors.white,
                  size: 72,
                  onTap: _isTaking ? null : _takePhoto,
                  isShutter: true,
                  isTaking: _isTaking,
                ),
                _CircleButton(
                  color: Colors.grey.withValues(alpha: 0.6),
                  icon: _isFlashOn ? Icons.flash_on : Icons.flash_off,
                  iconColor: Colors.white,
                  size: 52,
                  onTap: _toggleFlash,
                ),
              ],
            ),
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