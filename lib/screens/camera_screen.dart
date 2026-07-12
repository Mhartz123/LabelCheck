import 'dart:io';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import '../main.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import '../models/scan_record.dart';
import '../services/compliance_engine.dart';
import '../services/image_cropper.dart';
import '../services/scan_store.dart';
import '../services/report_service.dart';
import 'result_screen.dart';

/// UI-facing scan progress. OCR happens in this screen before
/// ComplianceEngine.analyze() is ever called, so it gets its own leading
/// stage ahead of [ScanStage].
enum _ScanUiStage {
  extractingText,
  matchingRegistry,
  classifying,
  checkingDamage,
}

/// The scan runs as one sequential inspection with two capture phases:
///  1. [label] — 3 close-ups (product/expiration/ingredients), each cropped to
///     the framing guide then OCR'd for the FDA/label/expiry/ingredient checks.
///  2. [box]   — 4 full-frame box shots (front/side/side/back) sent to the
///     YOLOv8 damage API.
enum _CapturePhase { label, box }

/// One label-capture step.
typedef _LabelSpec = ({PhotoSlot slot, String title, String helper});

/// One box-capture step.
typedef _BoxSpec = ({BoxSlot slot, String title, String helper});

const List<_LabelSpec> _labelSlots = [
  (
    slot: PhotoSlot.front,
    title: 'Product name / label',
    helper: 'Frame the product name or full label inside the guide',
  ),
  (
    slot: PhotoSlot.expiration,
    title: 'Expiration date',
    helper: 'Frame the expiration / best-before date inside the guide',
  ),
  (
    slot: PhotoSlot.ingredients,
    title: 'Ingredient list',
    helper: 'Frame the ingredient list inside the guide',
  ),
];

const List<_BoxSpec> _boxSlots = [
  (
    slot: BoxSlot.front,
    title: 'Box — Front',
    helper: 'Fit the whole front of the box inside the guide',
  ),
  (
    slot: BoxSlot.side1,
    title: 'Box — Side',
    helper: 'Fit one side of the box inside the guide',
  ),
  (
    slot: BoxSlot.side2,
    title: 'Box — Other side',
    helper: 'Fit the other side of the box inside the guide',
  ),
  (
    slot: BoxSlot.back,
    title: 'Box — Back',
    helper: 'Fit the whole back of the box inside the guide',
  ),
];

/// Selectable framing-box presets for the label close-ups. Users pick the one
/// that best isolates the target text, so a logo that's too big or too long
/// doesn't pull in surrounding detail that confuses OCR.
typedef _GuidePreset = ({String label, Size size});

const List<_GuidePreset> _guidePresets = [
  (label: 'Small', size: Size(190, 130)),
  (label: 'Medium', size: Size(250, 180)),
  (label: 'Large', size: Size(310, 230)),
];

/// The expiration date is small and must not capture nearby text, so its
/// framing box is fixed tight regardless of the selected preset.
const Size _expirationGuideSize = Size(210, 100);

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
  _ScanUiStage _scanStage = _ScanUiStage.extractingText;
  bool _isFlashOn = false;
  int _cameraIndex = 0;

  // Zoom
  double _currentZoom = 1.0;
  double _baseZoom = 1.0;
  double _minZoom = 1.0;
  double _maxZoom = 1.0;

  // Focus
  Offset? _focusPoint;

  // ── Sequential capture state ────────────────────────────────────────────
  _CapturePhase _phase = _CapturePhase.label;
  int _slotIndex = 0;

  /// Index into [_guidePresets] for the label framing box. Defaults to Medium.
  int _guidePresetIndex = 1;

  final Map<PhotoSlot, String> _labelPaths = {};
  final Map<BoxSlot, String> _boxPaths = {};

  /// Label slots the user has verified are physically absent from the packaging
  /// (via the "not on the box" button). A declared-missing element flags the
  /// scan non-compliant — see [ComplianceEngine.analyze].
  final Set<PhotoSlot> _declaredMissing = {};

  /// Rendered size of the camera area, captured in [build] via LayoutBuilder.
  /// The framing guide is centered in this space, so it's also the coordinate
  /// system used to crop label photos to the guide.
  Size _previewSize = Size.zero;

  int get _slotCount =>
      _phase == _CapturePhase.label ? _labelSlots.length : _boxSlots.length;

  String get _currentTitle => _phase == _CapturePhase.label
      ? _labelSlots[_slotIndex].title
      : _boxSlots[_slotIndex].title;

  String get _currentHelper => _phase == _CapturePhase.label
      ? _labelSlots[_slotIndex].helper
      : _boxSlots[_slotIndex].helper;

  /// The label slot currently being captured, or null during the box phase.
  PhotoSlot? get _currentLabelSlot =>
      _phase == _CapturePhase.label ? _labelSlots[_slotIndex].slot : null;

  /// Whether the current slot is one the user can declare absent from the
  /// packaging (expiration date or ingredient list).
  bool get _canDeclareMissing =>
      _currentLabelSlot == PhotoSlot.expiration ||
      _currentLabelSlot == PhotoSlot.ingredients;

  /// Framing-guide dimensions. Box shots use a fixed upright rectangle. Label
  /// close-ups use the user-selected [_guidePresets] entry so oversized/long
  /// logos don't drag in surrounding text — except the expiration slot, which
  /// is locked to a small tight frame ([_expirationGuideSize]) so nearby text
  /// can't be mistaken for the date.
  Size get _guideSize {
    if (_phase == _CapturePhase.box) return const Size(300, 360);
    if (_currentLabelSlot == PhotoSlot.expiration) return _expirationGuideSize;
    return _guidePresets[_guidePresetIndex].size;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initCamera(_cameraIndex);
    // Prefetch the FDA dataset (and DistilBERT if enabled) while the user is
    // still framing/capturing photos, so analyze() doesn't pay full load
    // latency.
    ComplianceEngine.warmUp();
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
    for (final path in [..._labelPaths.values, ..._boxPaths.values]) {
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

  // ── Take photo ─────────────────────────────────────────────────────────────
  Future<void> _takePhoto() async {
    if (_controller == null || !_controller!.value.isInitialized) return;
    if (_isTaking || _isProcessing) return;
    setState(() => _isTaking = true);

    try {
      final XFile photo = await _controller!.takePicture();

      if (_phase == _CapturePhase.label) {
        // Isolate the label region: crop to the framing guide so OCR isn't
        // distracted by the surrounding scene.
        final guide = Rect.fromCenter(
          center: Offset(_previewSize.width / 2, _previewSize.height / 2),
          width: _guideSize.width,
          height: _guideSize.height,
        );
        final croppedPath = await ImageCropper.cropToGuide(
          photo.path,
          screenSize: _previewSize,
          guideRect: guide,
        );
        final slot = _labelSlots[_slotIndex].slot;
        _labelPaths[slot] = croppedPath;
      } else {
        // Box shots are used full-frame for damage detection — no crop.
        _boxPaths[_boxSlots[_slotIndex].slot] = photo.path;
      }

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

  /// Records the current label element (expiration or ingredients) as absent
  /// from the packaging and advances without a photo. The scan will be flagged
  /// non-compliant for the missing element.
  Future<void> _declareCurrentMissing() async {
    if (_isTaking || _isProcessing) return;
    final slot = _currentLabelSlot;
    if (slot == null) return;

    // Drop any photo already taken for this slot (unlikely mid-flow).
    final existing = _labelPaths.remove(slot);
    if (existing != null) {
      try {
        final f = File(existing);
        if (f.existsSync()) f.deleteSync();
      } catch (_) {}
    }

    setState(() => _declaredMissing.add(slot));
    await _advanceOrFinish();
  }

  Future<void> _advanceOrFinish() async {
    if (_slotIndex < _slotCount - 1) {
      setState(() => _slotIndex++);
    } else if (_phase == _CapturePhase.label) {
      // Label step done — move on to the box/damage step.
      setState(() {
        _phase = _CapturePhase.box;
        _slotIndex = 0;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Label photos done — now photograph the box.'),
            backgroundColor: Color(0xFF4CAF50),
            duration: Duration(seconds: 2),
          ),
        );
      }
    } else {
      await _runAnalysis();
    }
  }

  // ── OCR the label crops, then run label + damage analysis ──────────────
  Future<void> _runAnalysis() async {
    setState(() {
      _isProcessing = true;
      _scanStage = _ScanUiStage.extractingText;
    });

    // OCR each label crop separately so its text routes straight to that
    // slot's field (see LabelParser) instead of guessing field boundaries out
    // of one combined blob.
    final textRecognizer = TextRecognizer();
    final textBySlot = <PhotoSlot, String>{};
    final buffer = StringBuffer();
    // Mean OCR confidence on the product-name (front) crop — gates the
    // last-ditch semantic tier in ComplianceEngine.
    double? nameConfidence;
    try {
      for (final spec in _labelSlots) {
        final path = _labelPaths[spec.slot];
        if (path == null) continue;
        final inputImage = InputImage.fromFilePath(path);
        final recognized = await textRecognizer.processImage(inputImage);
        textBySlot[spec.slot] = recognized.text;
        if (spec.slot == PhotoSlot.front) {
          nameConfidence = _meanLineConfidence(recognized);
        }
        if (buffer.isNotEmpty) buffer.write('\n\n');
        buffer.write(recognized.text);
      }
    } catch (e) {
      debugPrint('OCR error: $e');
    } finally {
      await textRecognizer.close();
    }

    final combinedText = buffer.toString();
    final boxPhotoPaths = [
      for (final spec in _boxSlots)
        if (_boxPaths[spec.slot] != null) _boxPaths[spec.slot]!,
    ];

    final record = await ComplianceEngine.analyze(
      textBySlot: textBySlot,
      combinedText: combinedText,
      boxPhotoPaths: boxPhotoPaths,
      ocrConfidence: nameConfidence,
      expirationDeclaredMissing:
          _declaredMissing.contains(PhotoSlot.expiration),
      ingredientsDeclaredMissing:
          _declaredMissing.contains(PhotoSlot.ingredients),
      onStageChange: (stage) {
        if (!mounted) return;
        setState(() {
          _scanStage = switch (stage) {
            ScanStage.matchingRegistry => _ScanUiStage.matchingRegistry,
            ScanStage.classifying => _ScanUiStage.classifying,
            ScanStage.checkingDamage => _ScanUiStage.checkingDamage,
          };
        });
      },
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

  /// Mean recognized-line confidence (0..1) across [recognized], or null if
  /// ML Kit didn't populate confidences (e.g. on platforms/models that omit
  /// them) — in which case the caller treats OCR as "not known to be low".
  double? _meanLineConfidence(RecognizedText recognized) {
    var sum = 0.0;
    var count = 0;
    for (final block in recognized.blocks) {
      for (final line in block.lines) {
        final c = line.confidence;
        if (c != null) {
          sum += c;
          count++;
        }
      }
    }
    return count == 0 ? null : sum / count;
  }

  // ── Check duplicate name ───────────────────────────────────────────────────
  Future<bool> _nameExists(String raw) => ScanStore.recordExists(raw);

  void _resetCaptureFlow() {
    setState(() {
      _labelPaths.clear();
      _boxPaths.clear();
      _declaredMissing.clear();
      _phase = _CapturePhase.label;
      _slotIndex = 0;
    });
  }

  void _discardCapturedPhotos() {
    for (final path in [..._labelPaths.values, ..._boxPaths.values]) {
      final f = File(path);
      if (f.existsSync()) f.deleteSync();
    }
    _resetCaptureFlow();
  }

  /// Confirms before wiping every captured photo and restarting the flow from
  /// the first label slot.
  Future<void> _confirmClearAll() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear all photos?'),
        content: const Text(
            'This discards every photo you\'ve taken and restarts the scan '
            'from the first step.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(foregroundColor: const Color(0xFFE57373)),
            child: const Text('Clear all'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      _discardCapturedPhotos();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('All photos cleared.'),
            backgroundColor: Color(0xFF4CAF50),
            duration: Duration(seconds: 2),
          ),
        );
      }
    }
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
        capturedPhotoPaths: Map.of(_labelPaths),
        boxPhotoPaths: Map.of(_boxPaths),
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

    final isLabelPhase = _phase == _CapturePhase.label;

    return Scaffold(
      backgroundColor: Colors.black,
      body: LayoutBuilder(
        builder: (context, constraints) {
          // The guide is centered in this space; reuse it as the crop
          // coordinate system for label photos.
          _previewSize = Size(constraints.maxWidth, constraints.maxHeight);

          return Stack(
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
                    width: _guideSize.width,
                    height: _guideSize.height,
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
                    key: ValueKey(_focusPoint),
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
                    // Which of the two major steps we're on.
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 4),
                      decoration: BoxDecoration(
                        color: isLabelPhase
                            ? const Color(0xFF4CAF50)
                            : const Color(0xFF1E88E5),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        isLabelPhase
                            ? 'STEP 1 OF 2 · LABEL CHECK'
                            : 'STEP 2 OF 2 · BOX CHECK',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 0.6,
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'PHOTO ${_slotIndex + 1} OF $_slotCount',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.85),
                        fontSize: 10.5,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.6,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _currentTitle,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _currentHelper,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.8),
                        fontSize: 12,
                      ),
                    ),
                    // "Not on the box" — lets the user verify a required label
                    // element is absent, which flags the scan non-compliant.
                    if (isLabelPhase && !_isProcessing && _canDeclareMissing) ...[
                      const SizedBox(height: 12),
                      GestureDetector(
                        onTap: _isTaking ? null : _declareCurrentMissing,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 8),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.45),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                              color: Colors.white.withValues(alpha: 0.6),
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.report_gmailerrorred_outlined,
                                  color: Colors.white, size: 16),
                              const SizedBox(width: 6),
                              Text(
                                _currentLabelSlot == PhotoSlot.expiration
                                    ? 'No expiration date on the box'
                                    : 'No ingredient list on the box',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),

              // Clear-all shortcut — top-left. Only shown once at least one
              // photo has been captured, so there's something to discard.
              if (!_isProcessing &&
                  (_labelPaths.isNotEmpty || _boxPaths.isNotEmpty))
                Positioned(
                  top: 52,
                  left: 12,
                  child: GestureDetector(
                    onTap: _isTaking ? null : _confirmClearAll,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.5),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.delete_outline,
                              color: Colors.white, size: 16),
                          SizedBox(width: 5),
                          Text('Clear all',
                              style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600)),
                        ],
                      ),
                    ),
                  ),
                ),

              if (_isProcessing)
                Container(
                  color: const Color(0xFF2E7D32),
                  child: Center(child: _ScanProgressCard(stage: _scanStage)),
                ),

              // Framing-box preset selector — label phase only. Sits well
              // above the thumbnail strip (bottom: 120, ~70px tall) so the
              // Small/Medium/Large pills don't crowd the slot thumbnails.
              if (isLabelPhase && !_isProcessing)
                Positioned(
                  bottom: 212,
                  left: 0,
                  right: 0,
                  child: Center(child: _buildGuideControl()),
                ),

              // Thumbnail strip for the current phase
              Positioned(
                bottom: 120,
                left: 0,
                right: 0,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: isLabelPhase
                      ? [
                          for (var i = 0; i < _labelSlots.length; i++)
                            _SlotThumbnail(
                              label: _shortTitle(_labelSlots[i].title),
                              isCurrent: i == _slotIndex,
                              imagePath: _labelPaths[_labelSlots[i].slot],
                            ),
                        ]
                      : [
                          for (var i = 0; i < _boxSlots.length; i++)
                            _SlotThumbnail(
                              label: _shortTitle(_boxSlots[i].title),
                              isCurrent: i == _slotIndex,
                              imagePath: _boxPaths[_boxSlots[i].slot],
                            ),
                        ],
                ),
              ),

              // Bottom controls — above the gesture layer so buttons work
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
          );
        },
      ),
    );
  }

  /// The framing-box control shown during the label phase: a preset picker for
  /// most slots, or a locked "fixed tight frame" badge for the expiration slot.
  Widget _buildGuideControl() {
    if (_currentLabelSlot == PhotoSlot.expiration) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(24),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.lock_outline, color: Colors.white, size: 14),
            SizedBox(width: 6),
            Text('Fixed tight frame for the date',
                style: TextStyle(color: Colors.white, fontSize: 12)),
          ],
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(24),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < _guidePresets.length; i++) _presetPill(i),
        ],
      ),
    );
  }

  Widget _presetPill(int index) {
    final selected = index == _guidePresetIndex;
    return GestureDetector(
      onTap: _isTaking ? null : () => setState(() => _guidePresetIndex = index),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFF4CAF50) : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          _guidePresets[index].label,
          style: TextStyle(
            color: Colors.white,
            fontSize: 13,
            fontWeight: selected ? FontWeight.bold : FontWeight.w500,
          ),
        ),
      ),
    );
  }

  /// First word of a slot title, used as the compact thumbnail caption.
  static String _shortTitle(String title) {
    final cleaned = title.replaceFirst('Box — ', '');
    return cleaned.split(' ').first;
  }
}

// ── Slot thumbnail ─────────────────────────────────────────────────────────────

class _SlotThumbnail extends StatelessWidget {
  final String label;
  final bool isCurrent;
  final String? imagePath;

  const _SlotThumbnail({
    required this.label,
    required this.isCurrent,
    required this.imagePath,
  });

  @override
  Widget build(BuildContext context) {
    final isCaptured = imagePath != null;
    return Column(
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
          ],
        ),
        const SizedBox(height: 3),
        Text(
          label,
          style: const TextStyle(color: Colors.white, fontSize: 10),
        ),
      ],
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

// ── Scan progress card ──────────────────────────────────────────────────────

class _ScanProgressCard extends StatelessWidget {
  final _ScanUiStage stage;

  const _ScanProgressCard({required this.stage});

  static const _subtitles = {
    _ScanUiStage.extractingText: 'Reading text from your label photos',
    _ScanUiStage.matchingRegistry: 'Checking against the FDA database',
    _ScanUiStage.classifying: 'Running the compliance model',
    _ScanUiStage.checkingDamage: 'Inspecting the box for damage',
  };

  static const _stepLabels = {
    _ScanUiStage.extractingText: 'Extracting label text (OCR)',
    _ScanUiStage.matchingRegistry: 'Matching FDA registry',
    _ScanUiStage.classifying: 'Classifying label result',
    _ScanUiStage.checkingDamage: 'Checking box for damage',
  };

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 36),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 84,
            height: 84,
            child: Stack(
              alignment: Alignment.center,
              children: const [
                CircularProgressIndicator(
                  color: Colors.white,
                  strokeWidth: 3,
                ),
                Icon(Icons.document_scanner_outlined,
                    color: Colors.white, size: 30),
              ],
            ),
          ),
          const SizedBox(height: 24),
          const Text(
            'Analyzing scan...',
            style: TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            _subtitles[stage]!,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.85),
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 24),
          for (final s in _ScanUiStage.values)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: _ScanStepRow(
                label: _stepLabels[s]!,
                completed: s.index < stage.index,
                active: s == stage,
              ),
            ),
        ],
      ),
    );
  }
}

class _ScanStepRow extends StatelessWidget {
  final String label;
  final bool completed;
  final bool active;

  const _ScanStepRow({
    required this.label,
    required this.completed,
    required this.active,
  });

  @override
  Widget build(BuildContext context) {
    final color = (completed || active)
        ? Colors.white
        : Colors.white.withValues(alpha: 0.45);

    return Row(
      children: [
        Icon(
          completed ? Icons.check_circle : Icons.circle_outlined,
          color: color,
          size: 18,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 13.5,
              fontWeight: active ? FontWeight.bold : FontWeight.normal,
            ),
          ),
        ),
      ],
    );
  }
}
