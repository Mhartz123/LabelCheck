import 'dart:io';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import '../main.dart';

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

  Future<void> _takePhoto() async {
    if (_controller == null || !_controller!.value.isInitialized) return;
    if (_isTaking) return;
    setState(() => _isTaking = true);
    try {
      final XFile photo = await _controller!.takePicture();
      if (mounted) _showSaveSheet(photo.path);
    } catch (e) {
      debugPrint('Take photo error: $e');
    } finally {
      if (mounted) setState(() => _isTaking = false);
    }
  }

  // ── Resolve the photos directory ─────────────────────────────────────────
  Future<Directory> _getPhotoDir() async {
    final Directory appDir = await getApplicationDocumentsDirectory();
    final Directory photoDir =
        Directory(p.join(appDir.path, 'UI_Prototype_Photos'));
    if (!await photoDir.exists()) await photoDir.create(recursive: true);
    return photoDir;
  }

  // ── Check if a filename is already taken ─────────────────────────────────
  Future<bool> _nameExists(String raw) async {
    if (raw.trim().isEmpty) return false;
    final dir = await _getPhotoDir();
    String fileName = raw.trim();
    if (!fileName.endsWith('.jpeg')) fileName = '$fileName.jpeg';
    fileName = fileName.replaceAll(' ', '_');
    return File(p.join(dir.path, fileName)).existsSync();
  }

  // ── Frame 1.2 — Save Record bottom sheet ─────────────────────────────────
  void _showSaveSheet(String tempPath) {
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
                  // ── Title bar ───────────────────────────────────────────
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

                  // ── Name input ──────────────────────────────────────────
                  TextField(
                    controller: nameController,
                    autofocus: true,
                    onChanged: onChanged,
                    decoration: InputDecoration(
                      hintText: '.jpeg',
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 10),
                      // Border turns red when name is taken
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
                      // Inline error message below the field
                      errorText: isTaken
                          ? 'This name is already taken. Please choose another.'
                          : null,
                      errorStyle: const TextStyle(
                          color: Color(0xFFE57373), fontSize: 11),
                      errorBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(
                            color: Color(0xFFE57373)),
                      ),
                      focusedErrorBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(
                            color: Color(0xFFE57373), width: 2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),

                  // ── Instructions ────────────────────────────────────────
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

                  // ── Cancel / Save ───────────────────────────────────────
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
                            padding: const EdgeInsets.symmetric(
                                vertical: 14),
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
                          // Disabled if empty or name is taken
                          onPressed: (isEmpty || isTaken)
                              ? null
                              : () async {
                                  final raw =
                                      nameController.text.trim();
                                  Navigator.of(context).pop();
                                  await _savePhoto(tempPath, raw);
                                },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF4CAF50),
                            foregroundColor: Colors.white,
                            disabledBackgroundColor:
                                Colors.grey.shade300,
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10)),
                            padding: const EdgeInsets.symmetric(
                                vertical: 14),
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

  // ── Save photo to app-private folder ─────────────────────────────────────
  Future<void> _savePhoto(String tempPath, String rawName) async {
    try {
      final dir = await _getPhotoDir();
      String fileName = rawName.endsWith('.jpeg')
          ? rawName
          : '$rawName.jpeg';
      fileName = fileName.replaceAll(' ', '_');
      final String destPath = p.join(dir.path, fileName);
      await File(tempPath).copy(destPath);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Photo "$fileName" saved!'),
            backgroundColor: const Color(0xFF4CAF50),
          ),
        );
      }
    } catch (e) {
      debugPrint('Save photo error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Failed to save photo.'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: _isReady && _controller != null
          ? Stack(
              fit: StackFit.expand,
              children: [
                CameraPreview(_controller!),
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
                        icon: _isFlashOn
                            ? Icons.flash_on
                            : Icons.flash_off,
                        iconColor: Colors.white,
                        size: 52,
                        onTap: _toggleFlash,
                      ),
                    ],
                  ),
                ),
              ],
            )
          : const Center(
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
}

// ── Circle button widget ──────────────────────────────────────────────────────

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
          border:
              isShutter ? Border.all(color: Colors.white, width: 4) : null,
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
