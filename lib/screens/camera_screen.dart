import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import '../main.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import '../models/scan_record.dart';
import 'package:image/image.dart' as img;
import '../services/app_storage.dart';
import '../services/date_code_parser.dart';
import '../services/ocr_geometry.dart';
import '../services/ocr_preprocessor.dart';
import '../services/compliance_engine.dart';
import '../services/image_cropper.dart';
import '../services/scan_store.dart';
import '../services/report_service.dart';
import '../theme/app_colors.dart';
import '../widgets/capture_tips.dart';
import 'result_screen.dart';

enum CameraMode { label, damage, inspection }

/// One capture read twice: as photographed, and after enhancement, alongside
/// the quality measurement taken while enhancing it.
typedef _DualRead = ({
  RecognizedText? original,
  RecognizedText? enhanced,
  CaptureQuality? quality,
});

/// What one label slot's capture turned into: the winning reading, the date it
/// yielded where the slot is the expiry, and how legible the capture was.
///
/// Held from the moment the photo is taken so the confirmation sheet can show
/// the user what will actually be extracted, and so the analysis step reuses
/// the reading instead of paying for recognition a second time.
/// The outcome of reading one slot across however many frames were taken.
class _FrameVote {
  /// The reading that won.
  final _SlotRead read;

  /// Which frame it came from, so that frame's image is the one kept.
  final int frameIndex;

  /// Frames that produced the same answer, and frames read in total.
  final int agreeing;
  final int total;

  const _FrameVote({
    required this.read,
    required this.frameIndex,
    required this.agreeing,
    required this.total,
  });

  bool get isMultiFrame => total > 1;

  /// Every frame that produced an answer produced the SAME answer. On a
  /// dot-matrix code this is worth much more than any single read's
  /// confidence, because the frames fail independently.
  bool get unanimous => agreeing == total;
}

class _SlotRead {
  final RecognizedText? text;
  final DateCode? dateCode;
  final CaptureQuality? quality;

  const _SlotRead({this.text, this.dateCode, this.quality});
}

enum _CapturePhase { label, box }

enum _ScanUiStage {
  extractingText,
  matchingRegistry,
  classifying,
  checkingDamage,
}

typedef _LabelSpec = ({PhotoSlot slot, String title, String helper});

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

typedef _GuidePreset = ({String label, Size size});

const List<_GuidePreset> _guidePresets = [
  (label: 'Small', size: Size(190, 130)),
  (label: 'Medium', size: Size(250, 180)),
  (label: 'Large', size: Size(310, 230)),
];

const Size _expirationGuideSize = Size(210, 100);

const Size _damageGuideSize = Size(300, 360);
const Size _damageGuideSizeLandscape = Size(360, 260);

/// Capture resolution, tried in order until one initializes.
///
/// This is the single largest lever on OCR accuracy in the whole pipeline.
/// ResolutionPreset.high is ~720p, which after the expiration guide crop
/// (210x100 logical px on a ~411x914 screen) leaves ML Kit roughly 368x140
/// pixels to read a dot-matrix date code from — glyphs around 15-25px tall,
/// at or below the recognizer's floor. No amount of upscaling in
/// OcrPreprocessor can re-add strokes the sensor never sampled.
///
/// ultraHigh (~2160p) triples that linearly. `max` is deliberately NOT the
/// first choice: it is unbounded, and on a 48MP sensor the full-frame decode
/// in ImageCropper would allocate well over 100MB — the minimum-spec target
/// device has 3GB of RAM.
const List<ResolutionPreset> _captureResolutionLadder = <ResolutionPreset>[
  ResolutionPreset.ultraHigh,
  ResolutionPreset.veryHigh,
  ResolutionPreset.high,
];

const Color _camAccent = Color(0xFF2FD79B);
const Color _camOnAccent = Color(0xFF04261B);
const Color _camControlBg = Color(0x8C0E1512);
const Color _camTrackBg = Color(0xA60E1512);

class CameraScreen extends StatefulWidget {
  final CameraMode mode;

  final PackagingType? packagingType;

  const CameraScreen({super.key, required this.mode, this.packagingType})
      : assert(
  mode == CameraMode.label || packagingType != null,
  'packagingType is required for damage and inspection scans',
  );

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

  double _currentZoom = 1.0;
  double _baseZoom = 1.0;
  double _minZoom = 1.0;
  double _maxZoom = 1.0;

  Offset? _focusPoint;

  late _CapturePhase _phase;
  int _slotIndex = 0;

  int _guidePresetIndex = 1;

  final Map<PhotoSlot, String> _labelPaths = {};

  /// Shown on the shutter while a multi-frame capture is in progress.
  String? _frameProgress;

  /// The reading for each captured label slot, taken at capture time so the
  /// confirmation sheet can show it and the analysis step can reuse it.
  final Map<PhotoSlot, _SlotRead> _slotReads = {};

  /// One recognizer for the whole capture session. Creating one per photo
  /// costs a model load each time, and recognition now runs on the shutter
  /// rather than once at the end.
  TextRecognizer? _recognizer;
  final Map<BoxSlot, String> _boxPaths = {};

  final Set<PhotoSlot> _declaredMissing = {};

  Size _previewSize = Size.zero;

  bool get _isLabelPhase => _phase == _CapturePhase.label;

  List<_BoxSpec> get _boxSlots {
    final typeLabel = (widget.packagingType ?? PackagingType.box).label;
    final lower = typeLabel.toLowerCase();
    return [
      (
      slot: BoxSlot.front,
      title: '$typeLabel — Front',
      helper: 'Fill the frame with the whole front of the $lower',
      ),
      (
      slot: BoxSlot.side1,
      title: '$typeLabel — Side',
      helper: 'Fill the frame with one side of the $lower',
      ),
      (
      slot: BoxSlot.side2,
      title: '$typeLabel — Other side',
      helper: 'Fill the frame with the other side of the $lower',
      ),
      (
      slot: BoxSlot.back,
      title: '$typeLabel — Back',
      helper: 'Fill the frame with the whole back of the $lower',
      ),
    ];
  }

  int get _slotCount =>
      _isLabelPhase ? _labelSlots.length : _boxSlots.length;

  String get _currentTitle =>
      _isLabelPhase ? _labelSlots[_slotIndex].title : _boxSlots[_slotIndex].title;

  String get _currentHelper => _isLabelPhase
      ? _labelSlots[_slotIndex].helper
      : _boxSlots[_slotIndex].helper;

  PhotoSlot? get _currentLabelSlot =>
      _isLabelPhase ? _labelSlots[_slotIndex].slot : null;

  bool get _canDeclareMissing =>
      _currentLabelSlot == PhotoSlot.expiration ||
          _currentLabelSlot == PhotoSlot.ingredients;

  List<_ScanUiStage> get _activeStages {
    switch (widget.mode) {
      case CameraMode.label:
        return const [
          _ScanUiStage.extractingText,
          _ScanUiStage.matchingRegistry,
          _ScanUiStage.classifying,
        ];
      case CameraMode.damage:
        return const [_ScanUiStage.checkingDamage];
      case CameraMode.inspection:
        return const [
          _ScanUiStage.extractingText,
          _ScanUiStage.matchingRegistry,
          _ScanUiStage.classifying,
          _ScanUiStage.checkingDamage,
        ];
    }
  }

  String get _modeBadgeText {
    final typeLabel = widget.packagingType?.label.toUpperCase();
    switch (widget.mode) {
      case CameraMode.label:
        return 'LABEL CHECK';
      case CameraMode.damage:
        return '$typeLabel DAMAGE CHECK';
      case CameraMode.inspection:
        return _isLabelPhase
            ? 'INSPECTION · LABEL STEP'
            : 'INSPECTION · $typeLabel STEP';
    }
  }

  Color get _modeBadgeColor {
    switch (widget.mode) {
      case CameraMode.label:
        return _camAccent;
      case CameraMode.damage:
        return const Color(0xFF4FC3F7);
      case CameraMode.inspection:
        return const Color(0xFFCE93D8);
    }
  }

  Size get _guideSize {
    if (!_isLabelPhase) {
      return _isLandscape ? _damageGuideSizeLandscape : _damageGuideSize;
    }
    return _currentLabelSlot == PhotoSlot.expiration
        ? _expirationGuideSize
        : _guidePresets[_guidePresetIndex].size;
  }

  bool get _isLandscape => _previewSize.width > _previewSize.height;

  EdgeInsets _viewPadding = EdgeInsets.zero;

  static const double _landscapeColumnMinWidth = 96;

  static const double _landscapeBadgeRowHeight = 56;

  Rect get _landscapeGuideBand {
    return Rect.fromLTRB(
      _viewPadding.left,
      _viewPadding.top + _landscapeBadgeRowHeight,
      _previewSize.width - _viewPadding.right,
      _previewSize.height - _viewPadding.bottom - 16,
    );
  }

  Rect get _portraitGuideBand {
    final top = _viewPadding.top + (_canDeclareMissing ? 170 : 126);
    final bottom = _previewSize.height - (_isLabelPhase ? 260 : 170);
    return Rect.fromLTRB(0, top, _previewSize.width, bottom);
  }

  Offset get _guideCenter {
    final size = _guideSize;
    final band = _isLandscape ? _landscapeGuideBand : _portraitGuideBand;

    final x = size.width <= band.width
        ? band.center.dx
        : _previewSize.width / 2;
    final y = size.height <= band.height
        ? band.center.dy
        : _previewSize.height / 2;

    return _clampGuideCenter(Offset(x, y), size);
  }

  Rect get _guideRect {
    final size = _guideSize;
    return Rect.fromCenter(
      center: _guideCenter,
      width: size.width,
      height: size.height,
    );
  }

  Offset _clampGuideCenter(Offset center, Size size) {
    final halfW = size.width / 2;
    final halfH = size.height / 2;
    final x = _previewSize.width >= size.width
        ? center.dx.clamp(halfW, _previewSize.width - halfW)
        : center.dx;
    final y = _previewSize.height >= size.height
        ? center.dy.clamp(halfH, _previewSize.height - halfH)
        : center.dy;
    return Offset(x, y);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _phase = widget.mode == CameraMode.damage
        ? _CapturePhase.box
        : _CapturePhase.label;
    _initCamera(_cameraIndex);

    ComplianceEngine.warmUp(packagingType: widget.packagingType);

    _applyCameraOrientations();
  }

  Future<void> _initCamera(int index) async {
    if (globalCameras.isEmpty) return;
    final prev = _controller;
    if (prev != null) await prev.dispose();

    // Walk down the ladder rather than trusting the plugin's own fallback,
    // which is documented as "may fall back to a higher or lower resolution"
    // and does not guarantee a working session on every device.
    for (final preset in _captureResolutionLadder) {
      final controller = CameraController(
        globalCameras[index],
        preset,
        enableAudio: false,
      );
      _controller = controller;
      try {
        await controller.initialize();
        _minZoom = await controller.getMinZoomLevel();
        _maxZoom = await controller.getMaxZoomLevel();
        _currentZoom = _minZoom;
        debugPrint('Camera: $preset, preview '
            '${controller.value.previewSize}, '
            'aspect ${controller.value.aspectRatio}');
        if (mounted) setState(() => _isReady = true);
        return;
      } catch (e) {
        debugPrint('Camera init error at $preset: $e');
        await controller.dispose();
        _controller = null;
      }
    }
  }

  /// Preview width/height as it is actually laid out on screen, matching what
  /// CameraPreview itself computes. Null until the controller is ready.
  double? get _previewAspectRatio {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return null;
    final aspect = controller.value.aspectRatio;
    if (aspect <= 0) return null;
    return _isLandscape ? aspect : 1 / aspect;
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
    _recognizer?.close();

    SystemChrome.setPreferredOrientations(
        const [DeviceOrientation.portraitUp]);

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

  void _onScaleStart(ScaleStartDetails details) {
    _baseZoom = _currentZoom;
  }

  Future<void> _onScaleUpdate(ScaleUpdateDetails details) async {
    if (_controller == null || !_controller!.value.isInitialized) return;
    if (details.pointerCount < 2) return;
    final newZoom = (_baseZoom * details.scale).clamp(_minZoom, _maxZoom);
    if ((newZoom - _currentZoom).abs() < 0.01) return;
    setState(() => _currentZoom = newZoom);
    await _controller!.setZoomLevel(newZoom);
  }

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

  /// Frames taken for the expiration slot.
  ///
  /// A dot-matrix code sits right at the recognizer's limit, and which
  /// characters survive changes shot to shot as focus, hand shake and the
  /// angle of the light move. Three frames read independently and voted is a
  /// far stronger signal than one lucky exposure, and frames DISAGREEING is
  /// itself the honest answer that the code could not be read.
  ///
  /// Only this slot pays the cost. The name and ingredient panels are ordinary
  /// solid print where a second frame buys almost nothing.
  static const int kExpiryFrameCount = 3;

  /// Takes one picture and returns the guide-cropped path, or null on failure.
  Future<String?> _captureCrop({required bool cropToGuide}) async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return null;

    final XFile photo = await controller.takePicture();
    final stagedPath = await AppStorage.newCapturePath(
      prefix: _isLabelPhase
          ? _labelSlots[_slotIndex].slot.name
          : _boxSlots[_slotIndex].slot.name,
    );
    await photo.saveTo(stagedPath);
    try {
      await File(photo.path).delete();
    } catch (_) {}

    if (!cropToGuide) return stagedPath;

    final guide = Rect.fromCenter(
      center: _guideCenter,
      width: _guideSize.width,
      height: _guideSize.height,
    );
    final croppedPath = await ImageCropper.cropToGuide(
      stagedPath,
      screenSize: _previewSize,
      guideRect: guide,
      previewAspectRatio: _previewAspectRatio,
    );
    if (croppedPath != stagedPath) _deleteQuietly(stagedPath);
    return croppedPath;
  }

  static void _deleteQuietly(String path) {
    try {
      final file = File(path);
      if (file.existsSync()) file.deleteSync();
    } catch (_) {}
  }

  Future<void> _takePhoto() async {
    if (_controller == null || !_controller!.value.isInitialized) return;
    if (_isTaking || _isProcessing) return;
    setState(() => _isTaking = true);

    try {
      if (!_isLabelPhase) {
        final path = await _captureCrop(cropToGuide: false);
        if (path == null) return;
        _boxPaths[_boxSlots[_slotIndex].slot] = path;
        await _advanceOrFinish();
        return;
      }

      final slot = _labelSlots[_slotIndex].slot;
      final frameCount =
          slot == PhotoSlot.expiration ? kExpiryFrameCount : 1;

      final paths = <String>[];
      for (var i = 0; i < frameCount; i++) {
        if (frameCount > 1 && mounted) {
          setState(() => _frameProgress = '${i + 1}/$frameCount');
        }
        final path = await _captureCrop(cropToGuide: true);
        if (path != null) paths.add(path);
      }
      if (mounted) setState(() => _frameProgress = null);
      if (paths.isEmpty) return;

      // Recognition happens here rather than after all three photos, so the
      // user can be shown what was actually extracted while the pack is still
      // in their hand and a retake costs nothing. The reading is kept and
      // reused by the analysis step.
      final voted = await _readFrames(slot, paths);
      if (!mounted) {
        for (final path in paths) {
          _deleteQuietly(path);
        }
        return;
      }

      final keptPath = paths[voted.frameIndex];
      final read = voted.read;

      if (_needsConfirmation(slot, read)) {
        final accepted = await _confirmCapture(slot, keptPath, read, voted);
        if (!accepted) {
          for (final path in paths) {
            _deleteQuietly(path);
          }
          return; // stay on this slot for another attempt
        }
      }

      for (final path in paths) {
        if (path != keptPath) _deleteQuietly(path);
      }
      _labelPaths[slot] = keptPath;
      _slotReads[slot] = read;

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

  Future<void> _declareCurrentMissing() async {
    if (_isTaking || _isProcessing) return;
    final slot = _currentLabelSlot;
    if (slot == null) return;

    _slotReads.remove(slot);
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
      return;
    }

    if (widget.mode == CameraMode.inspection && _isLabelPhase) {
      setState(() {
        _phase = _CapturePhase.box;
        _slotIndex = 0;
      });
      if (mounted) {
        final typeLabel = (widget.packagingType ?? PackagingType.box).label;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Label photos done — now photograph the $typeLabel.'),
            backgroundColor: const Color(0xFF4CAF50),
            duration: const Duration(seconds: 2),
          ),
        );
      }
      return;
    }

    await _runAnalysis();
  }

  Future<void> _runAnalysis() async {
    switch (widget.mode) {
      case CameraMode.label:
        await _runLabelAnalysis();
        break;
      case CameraMode.damage:
        await _runDamageAnalysis();
        break;
      case CameraMode.inspection:
        await _runInspectionAnalysis();
        break;
    }
  }

  /// Assembles the per-slot text from the readings taken at capture time.
  ///
  /// Recognition already ran on the shutter so the confirmation sheet could
  /// show what was extracted; re-running it here would double the ML Kit work
  /// and could hand the compliance engine a different answer from the one the
  /// user was shown and accepted. A slot with no cached reading is recognized
  /// on the spot, which only happens if a capture predates this flow.
  Future<_OcrResult> _ocrLabelSlots() async {
    final textBySlot = <PhotoSlot, String>{};
    final buffer = StringBuffer();

    double? nameConfidence;
    DateCode? dateCode;
    try {
      for (final spec in _labelSlots) {
        final path = _labelPaths[spec.slot];
        if (path == null) continue;

        final read =
            _slotReads[spec.slot] ?? await _readSlot(spec.slot, path);
        final recognized = read.text;
        if (spec.slot == PhotoSlot.expiration) dateCode = read.dateCode;
        if (recognized == null) continue;

        switch (spec.slot) {
          case PhotoSlot.front:
            nameConfidence = _meanLineConfidence(recognized);
            textBySlot[spec.slot] = _frontTextByProminence(recognized);
          case PhotoSlot.expiration:
            textBySlot[spec.slot] = recognized.text;
          case PhotoSlot.ingredients:
            textBySlot[spec.slot] = recognized.text;
        }

        if (buffer.isNotEmpty) buffer.write('\n\n');
        buffer.write(recognized.text);
      }
    } catch (e) {
      debugPrint('OCR error: $e');
    }
    return _OcrResult(
      textBySlot: textBySlot,
      combinedText: buffer.toString(),
      nameConfidence: nameConfidence,
      dateCode: dateCode,
    );
  }

  static OcrProfile _profileFor(PhotoSlot slot) => switch (slot) {
    PhotoSlot.front => OcrProfile.productName,
    PhotoSlot.expiration => OcrProfile.dateCode,
    PhotoSlot.ingredients => OcrProfile.ingredients,
  };

  /// Shows what was read off [path] and asks whether to keep it.
  ///
  /// Returns true to accept the capture, false to retake. Deliberately not
  /// dismissible by tapping away: an accidental dismissal that silently
  /// accepted a bad read would defeat the point of asking.
  Future<bool> _confirmCapture(
      PhotoSlot slot, String path, _SlotRead read, _FrameVote vote) async {
    final quality = read.quality;
    var hint = quality != null && !quality.passes ? quality.failureReason : null;

    // Frames disagreeing outranks any blur measurement: it is direct evidence
    // that the code is being read differently each time, which no sharpness
    // number can tell you.
    if (vote.isMultiFrame && vote.agreeing > 0 && !vote.unanimous) {
      hint = 'Only ${vote.agreeing} of ${vote.total} shots read this the same '
          '— worth retaking';
    }
    final summary = _readSummary(slot, read);
    final good = _isGoodRead(slot, read);

    final accepted = await showModalBottomSheet<bool>(
      context: context,
      isDismissible: false,
      enableDrag: false,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 10, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.border,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.file(
                File(path),
                height: 120,
                width: double.infinity,
                fit: BoxFit.cover,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              vote.isMultiFrame
                  ? (slot == PhotoSlot.expiration
                      ? 'Date read  ·  ${vote.agreeing}/${vote.total} shots agree'
                      : 'Text read  ·  ${vote.agreeing}/${vote.total} shots agree')
                  : (slot == PhotoSlot.expiration ? 'Date read' : 'Text read'),
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.6,
                color: AppColors.muted,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              summary,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: good ? AppColors.text : const Color(0xFFE57373),
              ),
            ),
            if (hint != null) ...[
              const SizedBox(height: 10),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.info_outline,
                      size: 16, color: Color(0xFFE0A030)),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      hint,
                      style: const TextStyle(
                          fontSize: 13, color: Color(0xFFE0A030)),
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(sheetContext).pop(false),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      side: BorderSide(color: AppColors.border),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                    child: Text('Retake',
                        style: TextStyle(
                            color: AppColors.text,
                            fontWeight: FontWeight.w600)),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: () => Navigator.of(sheetContext).pop(true),
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.accent,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                    child: const Text('Use this',
                        style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
    return accepted ?? false;
  }

  /// Whether [read] looks like a usable result, for colouring the summary.
  bool _isGoodRead(PhotoSlot slot, _SlotRead read) => switch (slot) {
        PhotoSlot.expiration => read.dateCode?.expiry != null,
        PhotoSlot.front => _readingScore(read.text) >= kMinReadingScore,
        PhotoSlot.ingredients =>
          (read.text?.text ?? '').replaceAll(RegExp(r'[^A-Za-z]'), '').length >=
              8,
      };

  /// Minimum confidence-weighted character count below which a front or
  /// ingredients capture is considered to have read nothing worth keeping, and
  /// the user is asked to confirm it. Deliberately low: the job is to catch a
  /// capture that failed outright, not to second-guess a thin but real read.
  static const double kMinReadingScore = 8;

  /// Recognizes [path] for [slot] and keeps the result.
  Future<_SlotRead> _readSlot(PhotoSlot slot, String path) async {
    final recognizer = _recognizer ??= TextRecognizer();
    final profile = _profileFor(slot);
    final reads = await _recognizeBoth(recognizer, path, profile);

    if (slot == PhotoSlot.expiration) {
      final picked = _pickByDateCode(
        reads,
        maxSkewDegrees: OcrGeometry.maxSkewDegreesFor(profile),
      );
      return _SlotRead(
          text: picked.text, dateCode: picked.code, quality: reads.quality);
    }
    return _SlotRead(text: _pickRicher(reads), quality: reads.quality);
  }

  /// Reads every frame of a capture and votes on the answer.
  ///
  /// Agreement is decided on the extracted VALUE, not on the recognized text:
  /// two frames can disagree character by character and still yield the same
  /// date, and it is the date that the verdict depends on. A slot with only
  /// one frame falls through as a vote of one, so callers need no special
  /// case.
  Future<_FrameVote> _readFrames(PhotoSlot slot, List<String> paths) async {
    final reads = <_SlotRead>[];
    for (final path in paths) {
      reads.add(await _readSlot(slot, path));
    }

    if (reads.length == 1) {
      return _FrameVote(
          read: reads.first, frameIndex: 0, agreeing: 1, total: 1);
    }

    // Tally by extracted value. Frames that read nothing are counted in the
    // total but can never win, so three unreadable frames stay unreadable
    // rather than one of them being promoted by default.
    final tally = <String, List<int>>{};
    for (var i = 0; i < reads.length; i++) {
      final key = _voteKey(slot, reads[i]);
      if (key == null) continue;
      (tally[key] ??= <int>[]).add(i);
    }

    if (tally.isEmpty) {
      debugPrint('OCR $slot: ${reads.length} frames, none readable');
      return _FrameVote(
          read: reads.first, frameIndex: 0, agreeing: 0, total: reads.length);
    }

    var bestKey = tally.keys.first;
    for (final entry in tally.entries) {
      if (entry.value.length > tally[bestKey]!.length) bestKey = entry.key;
    }
    final winners = tally[bestKey]!;

    debugPrint('OCR $slot: ${winners.length}/${reads.length} frames agree '
        'on "$bestKey"');
    return _FrameVote(
      read: reads[winners.first],
      frameIndex: winners.first,
      agreeing: winners.length,
      total: reads.length,
    );
  }

  /// The value two frames have to agree on, or null when a frame read nothing
  /// worth voting with.
  static String? _voteKey(PhotoSlot slot, _SlotRead read) {
    if (slot == PhotoSlot.expiration) {
      final code = read.dateCode;
      final expiry = code?.expiry;
      if (expiry == null) return null;
      final made = code!.manufactured;
      return '${expiry.toIso8601String()}|${made?.toIso8601String() ?? ""}';
    }
    final text = read.text?.text.replaceAll(RegExp(r'\s+'), ' ').trim() ?? '';
    return text.isEmpty ? null : text;
  }

  /// Whether the user should be shown what was read before the capture is
  /// accepted.
  ///
  /// The expiry always asks, because it is the one slot whose extracted VALUE
  /// — not merely its text — drives a compliance verdict, and a silently wrong
  /// date is worse than any number of retakes. The other two only interrupt
  /// when the capture measured badly or came back with almost nothing, so an
  /// ordinary scan stays a three-tap flow.
  bool _needsConfirmation(PhotoSlot slot, _SlotRead read) {
    if (slot == PhotoSlot.expiration) return true;
    final quality = read.quality;
    if (quality != null && !quality.passes) return true;
    return _readingScore(read.text) < kMinReadingScore;
  }

  /// One line describing what will be extracted from [slot].
  String _readSummary(PhotoSlot slot, _SlotRead read) {
    switch (slot) {
      case PhotoSlot.expiration:
        final code = read.dateCode;
        if (code == null || code.expiry == null) {
          return 'No expiry date found';
        }
        final expiry = _formatMonthDay(code.expiry!, code.matchedFormat);
        final made = code.manufactured;
        return made == null
            ? 'Expiry: $expiry'
            : 'Expiry: $expiry   ·   Made: ${_formatMonthDay(made, null)}';
      case PhotoSlot.front:
        final text = read.text;
        if (text == null) return 'No text read';
        final headline = _frontTextByProminence(text).split('\n').first.trim();
        return headline.isEmpty ? 'No text read' : headline;
      case PhotoSlot.ingredients:
        final letters = (read.text?.text ?? '')
            .replaceAll(RegExp(r'[^A-Za-z]'), '')
            .length;
        return letters >= 8
            ? 'Ingredient list detected ($letters letters)'
            : 'No ingredient list detected';
    }
  }

  static String _formatMonthDay(DateTime date, String? format) {
    const months = <String>[
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    final month = months[date.month - 1];
    // A month-precision code resolves to the last day of the month, so showing
    // that day back to the user would invent a precision the pack never had.
    final monthOnly = format != null && !format.contains('DD');
    return monthOnly ? '$month ${date.year}' : '$month ${date.day}, ${date.year}';
  }

  /// Both readings of one capture: ML Kit on the crop as photographed, and ML
  /// Kit on the enhanced crop.
  ///
  /// The pipeline used to run on the enhanced image only, which meant a
  /// capture the enhancement HURT had no way back. That is not hypothetical:
  /// OcrPreprocessor flattens to luma, and on a colour front panel — green and
  /// red type over purple board on an MX3 carton — the separation a reader
  /// sees collapses to a few levels before the contrast stretch and unsharp
  /// mask even run. ML Kit takes colour images natively and was never given
  /// the chance to try.
  ///
  /// Two recognitions per slot rather than one. ML Kit's on-device Latin model
  /// is cheap next to the capture itself, and the second read is also what
  /// finally makes the preprocessing measurable: every scan now reports which
  /// path won, which is the A/B comparison the evaluation set is supposed to
  /// produce in bulk.
  Future<_DualRead> _recognizeBoth(
      TextRecognizer recognizer,
      String path,
      OcrProfile profile,
      ) async {
    String? enhancedPath;
    CaptureQuality? quality;
    try {
      final decoded = img.decodeImage(await File(path).readAsBytes());
      if (decoded != null) {
        // Logged per capture because a preprocessing failure currently looks
        // exactly like preprocessing having worked: the catch below falls back
        // to the raw file and recognition carries on regardless. Without this
        // there is no way to tell from a device whether the pipeline ran.
        quality = OcrPreprocessor.assess(decoded, profile);
        final enhanced = OcrPreprocessor.run(decoded, profile);
        debugPrint('OCR $profile: crop ${decoded.width}x${decoded.height} '
            '-> ${enhanced.width}x${enhanced.height}, '
            'sharpness ${quality.sharpness.toStringAsFixed(0)}, '
            'spread ${quality.contrastSpread}, '
            'blown ${quality.blownRatio.toStringAsFixed(3)}, '
            'gate ${quality.passes ? "pass" : "FAIL (${quality.failureReason})"}');
        final dir = await AppStorage.capturesDir();
        enhancedPath = await OcrPreprocessor.writeTempJpeg(
          enhanced,
          directory: dir.path,
          prefix: 'ocr',
        );
      }
    } catch (e) {
      debugPrint('OCR preprocessing failed for $path: $e');
    }

    try {
      final original = await _recognizeFile(recognizer, path);
      final enhanced = enhancedPath == null
          ? null
          : await _recognizeFile(recognizer, enhancedPath);
      return (original: original, enhanced: enhanced, quality: quality);
    } finally {
      if (enhancedPath != null) {
        try {
          await File(enhancedPath).delete();
        } catch (_) {}
      }
    }
  }

  Future<RecognizedText?> _recognizeFile(
      TextRecognizer recognizer, String path) async {
    try {
      return await recognizer.processImage(InputImage.fromFilePath(path));
    } catch (e) {
      debugPrint('OCR error on $path: $e');
      return null;
    }
  }

  /// Picks the reading that yields the better date code.
  ///
  /// "Better" is not a guess here — a parsed date beats an ambiguous one beats
  /// an unreadable one, and a pair with a manufacture date alongside the expiry
  /// beats a lone expiry, because the pair is cross-checked against the shelf
  /// life and a single date is not.
  ({DateCode? code, RecognizedText? text}) _pickByDateCode(
      _DualRead reads, {
        required double maxSkewDegrees,
      }) {
    DateCode? bestCode;
    RecognizedText? bestText;
    var bestRank = -1;
    var winner = 'none';

    // Enhanced first, so a tie goes to the calibrated path.
    for (final candidate in <(String, RecognizedText?)>[
      ('enhanced', reads.enhanced),
      ('original', reads.original),
    ]) {
      final text = candidate.$2;
      if (text == null) continue;
      final code =
      DateCodeParser.parse(text, maxSkewDegrees: maxSkewDegrees);
      final rank = _rankDateCode(code);
      if (rank > bestRank) {
        bestRank = rank;
        bestCode = code;
        bestText = text;
        winner = candidate.$1;
      }
    }

    debugPrint('OCR dateCode: $winner reading won '
        '(${bestCode?.status.name ?? "no reading"}'
        '${bestCode?.matchedFormat == null ? "" : ", ${bestCode!.matchedFormat}"}'
        '${bestCode?.confidence == null ? "" : ", conf ${bestCode!.confidence!.toStringAsFixed(2)}"})');
    return (code: bestCode, text: bestText);
  }

  static int _rankDateCode(DateCode code) {
    final byStatus = switch (code.status) {
      DateCodeStatus.parsed => 2,
      DateCodeStatus.ambiguous => 1,
      DateCodeStatus.unreadable => 0,
    };
    return byStatus * 2 + (code.manufactured != null ? 1 : 0);
  }

  /// Picks the reading carrying more legible text, for the slots with no
  /// structured result to test against.
  RecognizedText? _pickRicher(_DualRead reads) {
    final enhancedScore = _readingScore(reads.enhanced);
    final originalScore = _readingScore(reads.original);
    final useEnhanced = reads.enhanced != null &&
        (reads.original == null || enhancedScore >= originalScore);

    debugPrint('OCR text: ${useEnhanced ? "enhanced" : "original"} reading won '
        '(enhanced ${enhancedScore.toStringAsFixed(0)} vs '
        'original ${originalScore.toStringAsFixed(0)})');
    return useEnhanced ? reads.enhanced : reads.original;
  }

  /// Alphanumeric characters recognized, each weighted by the confidence of
  /// the line it came from.
  ///
  /// Character count alone would reward a reading that hallucinated extra
  /// junk; mean confidence alone would reward one that found three characters
  /// and was sure of them. The product penalises both. Where the recognizer
  /// reports no confidence the weight is 1 and this degrades to a plain count.
  static double _readingScore(RecognizedText? text) {
    if (text == null) return 0;
    var score = 0.0;
    for (final block in text.blocks) {
      for (final line in block.lines) {
        var characters = 0;
        for (final unit in line.text.codeUnits) {
          final isDigit = unit >= 0x30 && unit <= 0x39;
          final isUpper = unit >= 0x41 && unit <= 0x5A;
          final isLower = unit >= 0x61 && unit <= 0x7A;
          if (isDigit || isUpper || isLower) characters++;
        }
        score += characters * (line.confidence ?? 1.0);
      }
    }
    return score;
  }

  /// The front panel's text with its display type hoisted to the front, since
  /// LabelParser takes the product name from the first usable line.
  ///
  /// Each prominent line is kept whole and on its own line. Joining the
  /// tallest ELEMENTS instead, which is what this used to do, glued fragments
  /// from opposite ends of the panel into one string - an MX3 carton came back
  /// as "M MS" and a Medicol carton as "LE NT DNE*" that way.
  String _frontTextByProminence(RecognizedText recognized) {
    final lines = OcrGeometry.horizontalLines(
      recognized,
      maxSkewDegrees: kProductNameMaxSkewDegrees,
    );
    final prominent = OcrGeometry.prominentLines(lines);
    final headline = prominent
        .map((line) => line.text.trim())
        .where((text) => text.isNotEmpty)
        .join('\n');
    if (headline.isEmpty) return recognized.text;
    return '$headline\n${recognized.text}';
  }

  List<String> get _capturedBoxPaths => [
    for (final spec in _boxSlots)
      if (_boxPaths[spec.slot] != null) _boxPaths[spec.slot]!,
  ];

  Future<void> _runLabelAnalysis() async {
    setState(() {
      _isProcessing = true;
      _scanStage = _ScanUiStage.extractingText;
    });
    await _settleProcessingOverlay();
    if (!mounted) return;

    final ocr = await _ocrLabelSlots();

    final record = await ComplianceEngine.analyzeLabel(
      textBySlot: ocr.textBySlot,
      combinedText: ocr.combinedText,
      ocrConfidence: ocr.nameConfidence,
      dateCode: ocr.dateCode,
      expirationDeclaredMissing:
      _declaredMissing.contains(PhotoSlot.expiration),
      ingredientsDeclaredMissing:
      _declaredMissing.contains(PhotoSlot.ingredients),
      onStageChange: _mapStageChange,
    );

    await _finishAnalysis(record);
  }

  /// How long the progress card is held after it first paints, before the
  /// analysis is allowed to start.
  static const Duration _processingSettle = Duration(milliseconds: 220);

  /// Lets the processing overlay actually reach the screen before the heavy
  /// work begins.
  ///
  /// `setState` only *schedules* a frame; the awaits that follow it resolve as
  /// microtasks, and microtasks all drain before the scheduled frame is ever
  /// built. So the analysis would start — and on the damage path, block —
  /// while the camera preview was still the thing on screen, and the user saw
  /// the shutter freeze and then jump straight to the result. Waiting on
  /// [SchedulerBinding.endOfFrame] guarantees the card has been rendered, and
  /// the short hold afterwards keeps it from flashing past on a fast scan.
  Future<void> _settleProcessingOverlay() async {
    await WidgetsBinding.instance.endOfFrame;
    await Future<void>.delayed(_processingSettle);
  }

  Future<void> _runDamageAnalysis() async {
    setState(() {
      _isProcessing = true;
      _scanStage = _ScanUiStage.checkingDamage;
    });
    await _settleProcessingOverlay();
    if (!mounted) return;

    final record = await ComplianceEngine.analyzeDamage(
      packagingType: widget.packagingType!,
      boxPhotoPaths: _capturedBoxPaths,
    );

    await _finishAnalysis(record);
  }

  Future<void> _runInspectionAnalysis() async {
    setState(() {
      _isProcessing = true;
      _scanStage = _ScanUiStage.extractingText;
    });
    await _settleProcessingOverlay();
    if (!mounted) return;

    final ocr = await _ocrLabelSlots();

    final record = await ComplianceEngine.analyzeInspection(
      textBySlot: ocr.textBySlot,
      combinedText: ocr.combinedText,
      packagingType: widget.packagingType!,
      boxPhotoPaths: _capturedBoxPaths,
      ocrConfidence: ocr.nameConfidence,
      dateCode: ocr.dateCode,
      expirationDeclaredMissing:
      _declaredMissing.contains(PhotoSlot.expiration),
      ingredientsDeclaredMissing:
      _declaredMissing.contains(PhotoSlot.ingredients),
      onStageChange: _mapStageChange,
    );

    await _finishAnalysis(record);
  }

  void _mapStageChange(ScanStage stage) {
    if (!mounted) return;
    setState(() {
      _scanStage = switch (stage) {
        ScanStage.matchingRegistry => _ScanUiStage.matchingRegistry,
        ScanStage.classifying => _ScanUiStage.classifying,
        ScanStage.checkingDamage => _ScanUiStage.checkingDamage,
      };
    });
  }

  Future<void> _finishAnalysis(ScanRecord record) async {
    if (mounted) setState(() => _isProcessing = false);

    if (mounted) {

      await SystemChrome.setPreferredOrientations(
          const [DeviceOrientation.portraitUp]);
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ResultScreen(
            record: record,
            boxPhotoPaths: _capturedBoxPaths,
          ),
        ),
      );
      _applyCameraOrientations();
      if (mounted) _showSaveSheet(record);
    }
  }

  void _applyCameraOrientations() {
    SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.portraitUp,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
  }

  /// Mean ML Kit line confidence over [recognized], or null when the
  /// recognizer did not report any.
  ///
  /// Null is the expected answer on Android: the plugin forwards
  /// `Text.Line.getConfidence()` faithfully, but the on-device Latin
  /// recognizer generally leaves it unset. That matters well beyond this
  /// method — ComplianceEngine gates its semantic tier on
  /// `ocrConfidence != null && ocrConfidence < threshold`, so a null here
  /// means that tier never runs at all. The counts are logged rather than
  /// assumed because it is a property of the ML Kit build on the device, not
  /// something that can be settled by reading the source.
  double? _meanLineConfidence(RecognizedText recognized) {
    var sum = 0.0;
    var withConfidence = 0;
    var withoutConfidence = 0;
    for (final block in recognized.blocks) {
      for (final line in block.lines) {
        final c = line.confidence;
        if (c != null) {
          sum += c;
          withConfidence++;
        } else {
          withoutConfidence++;
        }
      }
    }
    debugPrint('OCR confidence: $withConfidence line(s) reported, '
        '$withoutConfidence without');
    return withConfidence == 0 ? null : sum / withConfidence;
  }

  Future<bool> _nameExists(String raw) => ScanStore.recordExists(raw);

  void _resetCaptureFlow() {
    setState(() {
      _labelPaths.clear();
      _slotReads.clear();
      _boxPaths.clear();
      _declaredMissing.clear();
      _slotIndex = 0;
      _phase = widget.mode == CameraMode.damage
          ? _CapturePhase.box
          : _CapturePhase.label;
    });
  }

  void _discardCapturedPhotos() {
    for (final path in [..._labelPaths.values, ..._boxPaths.values]) {
      final f = File(path);
      if (f.existsSync()) f.deleteSync();
    }
    _resetCaptureFlow();
  }

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

  Future<void> _confirmExit() async {
    if (_isTaking || _isProcessing) return;
    final hasPhotos = _labelPaths.isNotEmpty || _boxPaths.isNotEmpty;
    if (!hasPhotos) {
      Navigator.of(context).pop();
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Exit scan?'),
        content: const Text(
            'This discards every photo you\'ve taken so far for this scan.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(foregroundColor: const Color(0xFFE57373)),
            child: const Text('Exit'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      _discardCapturedPhotos();
      if (mounted) Navigator.of(context).pop();
    }
  }

  void _showSaveSheet(ScanRecord record) {
    final TextEditingController nameController = TextEditingController();

    final BuildContext cameraContext = context;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      isDismissible: false,

      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
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

            final Color fieldBorder =
            isTaken ? const Color(0xFFE57373) : AppColors.border;
            final Color fieldFocus =
            isTaken ? const Color(0xFFE57373) : AppColors.accent;

            OutlineInputBorder border(Color color, double width) =>
                OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: color, width: width),
                );

            return Padding(
              padding: EdgeInsets.only(
                left: 20,
                right: 20,
                top: 10,
                bottom: MediaQuery.of(context).viewInsets.bottom + 20,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: AppColors.border,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),

                  Row(
                    children: [
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: AppColors.accent.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(Icons.save_outlined,
                            color: AppColors.accent, size: 20),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text('Save record',
                                style: TextStyle(
                                  fontSize: 17,
                                  fontWeight: FontWeight.bold,
                                  color: AppColors.text,
                                )),
                            const SizedBox(height: 2),
                            Text('Name this scan to file it in Records',
                                style: TextStyle(
                                  fontSize: 12.5,
                                  color: AppColors.muted,
                                )),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),

                  Text('RECORD NAME',
                      style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.8,
                        color: AppColors.muted,
                      )),
                  const SizedBox(height: 8),
                  TextField(
                    controller: nameController,
                    autofocus: true,
                    onChanged: onChanged,
                    style: TextStyle(fontSize: 15, color: AppColors.text),
                    decoration: InputDecoration(
                      hintText: 'Loaf_of_bread',
                      hintStyle: TextStyle(
                          color: AppColors.muted.withValues(alpha: 0.7)),
                      filled: true,
                      fillColor: AppColors.bg,
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 14),
                      enabledBorder: border(fieldBorder, 1),
                      focusedBorder: border(fieldFocus, 1.8),
                      errorText: isTaken
                          ? 'This name is already taken. Please choose another.'
                          : null,
                      errorStyle: const TextStyle(
                          color: Color(0xFFE57373), fontSize: 11),
                      errorBorder: border(const Color(0xFFE57373), 1),
                      focusedErrorBorder:
                      border(const Color(0xFFE57373), 1.8),
                    ),
                  ),
                  const SizedBox(height: 10),

                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.info_outline,
                          size: 14, color: AppColors.muted),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Once saved, this name can\'t be changed. Use '
                              'letters, numbers, and underscores.',
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.4,
                            color: AppColors.muted,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),

                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () {
                            Navigator.of(context).pop();
                            _discardCapturedPhotos();
                            if (cameraContext.mounted) {
                              Navigator.of(cameraContext).pop();
                            }
                          },
                          style: OutlinedButton.styleFrom(
                            foregroundColor: AppColors.text,
                            backgroundColor: AppColors.surface,
                            side: BorderSide(color: AppColors.border),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12)),
                            padding:
                            const EdgeInsets.symmetric(vertical: 15),
                          ),
                          child: const Text('Cancel',
                              style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600)),
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
                            final saved = await _saveRecord(raw, record);
                            if (saved && cameraContext.mounted) {

                              Navigator.of(cameraContext)
                                  .popUntil((route) => route.isFirst);
                            }
                          },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppColors.accent,
                            foregroundColor: Colors.white,

                            disabledBackgroundColor: AppColors.surfaceAlt,
                            disabledForegroundColor: AppColors.muted,
                            elevation: 0,
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12)),
                            padding:
                            const EdgeInsets.symmetric(vertical: 15),
                          ),
                          child: const Text('Save record',
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

  Future<bool> _saveRecord(String rawName, ScanRecord record) async {
    try {
      final dir = await ScanStore.save(
        rawName: rawName,
        capturedPhotoPaths: Map.of(_labelPaths),
        boxPhotoPaths: Map.of(_boxPaths),
        record: record,
      );

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
      return true;
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
      return false;
    }
  }

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

    final isLabelPhase = _isLabelPhase;

    return Scaffold(
      backgroundColor: Colors.black,
      body: LayoutBuilder(
        builder: (context, constraints) {

          _previewSize = Size(constraints.maxWidth, constraints.maxHeight);

          _viewPadding = MediaQuery.of(context).padding;
          final isLandscape = _isLandscape;

          return Stack(
            fit: StackFit.expand,
            children: [

              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onScaleStart: _onScaleStart,
                onScaleUpdate: _onScaleUpdate,
                onTapUp: _onTapFocus,
                child: CameraPreview(_controller!),
              ),

              Positioned(
                left: _guideCenter.dx,
                top: _guideCenter.dy,
                child: FractionalTranslation(
                  translation: const Offset(-0.5, -0.5),
                  child: IgnorePointer(
                    child: _GuideFrame(
                      size: _guideSize,
                      showFrame: isLabelPhase,
                      zoomLabel: _currentZoom > _minZoom + 0.05
                          ? '${_currentZoom.toStringAsFixed(1)}x'
                          : null,
                    ),
                  ),
                ),
              ),

              if (_focusPoint != null)
                Positioned(
                  left: _focusPoint!.dx - 35,
                  top: _focusPoint!.dy - 35,
                  child: _FocusCircle(
                    key: ValueKey(_focusPoint),
                    visible: true,
                  ),
                ),

              ...isLandscape
                  ? _landscapeOverlay(isLabelPhase)
                  : _portraitOverlay(isLabelPhase),
            ],
          );
        },
      ),
    );
  }

  List<Widget> _portraitOverlay(bool isLabelPhase) {
    return [
      Positioned(
        top: _viewPadding.top + 10,
        left: 14,
        right: 14,
        child: _topCluster(),
      ),

      if (_isProcessing) _processingOverlay(),

      if (isLabelPhase && !_isProcessing)
        Positioned(
          bottom: 212,
          left: 0,
          right: 0,
          child: Center(child: _buildGuideControl()),
        ),

      Positioned(
        bottom: 118,
        left: 0,
        right: 0,
        child: _thumbnailRow(isLabelPhase),
      ),

      Positioned(
        bottom: 28,
        left: 0,
        right: 0,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [_flipButton(), _shutterButton(), _flashButton()],
        ),
      ),
    ];
  }

  List<Widget> _landscapeOverlay(bool isLabelPhase) {

    final leftInset = _viewPadding.left;
    final rightInset = _viewPadding.right;
    final topInset = _viewPadding.top;
    final bottomInset = _viewPadding.bottom;

    final columnLeft = 16 + leftInset;

    final columnWidth = (_guideRect.left - 14 - columnLeft).clamp(0.0, 420.0);

    return [

      Positioned(
        top: topInset + 8,
        left: 34 + leftInset,
        right: 34 + rightInset,
        child: _topCluster(withText: false),
      ),

      if (!_isProcessing && columnWidth >= _landscapeColumnMinWidth)
        Positioned(
          left: columnLeft,
          top: topInset + _landscapeBadgeRowHeight,
          bottom: 16 + bottomInset,
          width: columnWidth,
          child: _landscapeInfoColumn(isLabelPhase),
        ),

      if (_isProcessing) _processingOverlay(),

      Positioned(
        right: 16 + rightInset,
        top: topInset,
        bottom: bottomInset,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _flipButton(),
              const SizedBox(height: 20),
              _shutterButton(),
              const SizedBox(height: 20),
              _flashButton(),
            ],
          ),
        ),
      ),
    ];
  }

  Widget _landscapeInfoColumn(bool isLabelPhase) {

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [

        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.only(bottom: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                _stepText(leftAligned: true),
                if (_canDeclareMissing) ...[
                  const SizedBox(height: 10),
                  _declareMissingPill(),
                ],
              ],
            ),
          ),
        ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isLabelPhase) ...[
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: _buildGuideControl(),
              ),
              const SizedBox(height: 10),
            ],
            _thumbnailWrap(isLabelPhase),
          ],
        ),
      ],
    );
  }

  Widget _topCluster({bool withText = true}) {
    final hasPhotos = _labelPaths.isNotEmpty || _boxPaths.isNotEmpty;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Stack(
          alignment: Alignment.center,
          children: [
            _modeBadge(),
            if (!_isProcessing)
              Row(
                children: [
                  _iconButton(
                      Icons.close, _isTaking ? null : _confirmExit),
                  const Spacer(),
                  _iconButton(
                      Icons.info_outline, () => showCaptureTips(context)),
                  if (hasPhotos) ...[
                    const SizedBox(width: 8),
                    _iconButton(Icons.delete_outline,
                        _isTaking ? null : _confirmClearAll),
                  ],
                ],
              ),
          ],
        ),
        if (withText && !_isProcessing) ...[
          const SizedBox(height: 10),
          _stepText(),

          if (_canDeclareMissing) ...[
            const SizedBox(height: 10),
            _declareMissingPill(),
          ],
        ],
      ],
    );
  }

  Widget _modeBadge() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
      decoration: BoxDecoration(
        color: _modeBadgeColor,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        _modeBadgeText,
        style: const TextStyle(
          color: _camOnAccent,
          fontSize: 11.5,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.8,
        ),
      ),
    );
  }

  Widget _stepText({bool leftAligned = false}) {
    final counter = leftAligned
        ? 'STEP ${_slotIndex + 1}/$_slotCount'
        : 'STEP ${_slotIndex + 1} OF $_slotCount · '
        '${_currentTitle.toUpperCase()}';

    return Column(
      crossAxisAlignment:
      leftAligned ? CrossAxisAlignment.start : CrossAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          counter,
          textAlign: leftAligned ? TextAlign.left : TextAlign.center,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.7),
            fontSize: 11.5,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.1,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          _currentHelper,
          textAlign: leftAligned ? TextAlign.left : TextAlign.center,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.92),
            fontSize: leftAligned ? 13 : 15,
            fontWeight: FontWeight.w500,
            height: 1.3,
          ),
        ),
      ],
    );
  }

  Widget _iconButton(IconData icon, VoidCallback? onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 40,
        height: 40,
        decoration: const BoxDecoration(
          color: _camControlBg,
          shape: BoxShape.circle,
        ),
        child: Icon(icon, color: Colors.white, size: 19),
      ),
    );
  }

  Widget _declareMissingPill() {
    return GestureDetector(
      onTap: _isTaking ? null : _declareCurrentMissing,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: _camTrackBg,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.35),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.report_gmailerrorred_outlined,
                color: Colors.white, size: 16),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                _currentLabelSlot == PhotoSlot.expiration
                    ? 'No expiration date on the box'
                    : 'No ingredient list on the box',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _processingOverlay() {
    return Container(
      color: const Color(0xFF2E7D32),
      child: Center(
        child: _ScanProgressCard(
          stage: _scanStage,
          stages: _activeStages,
        ),
      ),
    );
  }

  Widget _thumbnailRow(bool isLabelPhase) {
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: 20,
      runSpacing: 10,
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
    );
  }

  Widget _flipButton() {
    return _CircleButton(
      color: _camControlBg,
      icon: Icons.refresh,
      iconColor: Colors.white,
      size: 52,
      onTap: _isProcessing ? null : _switchCamera,
    );
  }

  Widget _shutterButton() {
    return _CircleButton(
      color: Colors.white,
      icon: null,
      iconColor: Colors.white,
      size: 76,
      onTap: (_isTaking || _isProcessing) ? null : _takePhoto,
      isShutter: true,
      isTaking: _isTaking,
      progress: _frameProgress,
    );
  }

  Widget _flashButton() {
    return _CircleButton(
      color: _camControlBg,
      icon: _isFlashOn ? Icons.flash_on : Icons.flash_off,
      iconColor: Colors.white,
      size: 52,
      onTap: _isProcessing ? null : _toggleFlash,
    );
  }

  Widget _buildGuideControl() {
    if (_currentLabelSlot == PhotoSlot.expiration) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(
          color: _camTrackBg,
          borderRadius: BorderRadius.circular(999),
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
        color: _camTrackBg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < _guidePresets.length; i++) _presetPill(i),
        ],
      ),
    );
  }

  Widget _thumbnailWrap(bool isLabelPhase) {
    final slots = isLabelPhase ? _labelSlots : _boxSlots;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (var i = 0; i < slots.length; i++)
          _SlotThumbnail(
            label: null,
            isCurrent: i == _slotIndex,
            imagePath: isLabelPhase
                ? _labelPaths[slots[i].slot]
                : _boxPaths[slots[i].slot],
            size: 48,
          ),
      ],
    );
  }

  Widget _presetPill(int index) {
    final selected = index == _guidePresetIndex;
    return GestureDetector(
      onTap: _isTaking ? null : () => setState(() => _guidePresetIndex = index),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? _camAccent : Colors.transparent,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          _guidePresets[index].label,
          style: TextStyle(
            color: selected
                ? _camOnAccent
                : Colors.white.withValues(alpha: 0.75),
            fontSize: 13,
            fontWeight: selected ? FontWeight.w800 : FontWeight.w500,
          ),
        ),
      ),
    );
  }

  static String _shortTitle(String title) {
    final dashIndex = title.indexOf('—');
    final cleaned = dashIndex == -1 ? title : title.substring(dashIndex + 1).trim();
    return cleaned.split(' ').first;
  }
}

class _OcrResult {
  final Map<PhotoSlot, String> textBySlot;
  final String combinedText;
  final double? nameConfidence;

  final DateCode? dateCode;

  const _OcrResult({
    required this.textBySlot,
    required this.combinedText,
    required this.nameConfidence,
    this.dateCode,
  });
}

class _SlotThumbnail extends StatelessWidget {

  final String? label;
  final bool isCurrent;
  final String? imagePath;

  final double size;

  const _SlotThumbnail({
    required this.label,
    required this.isCurrent,
    required this.imagePath,
    this.size = 52,
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
              width: size,
              height: size,
              decoration: BoxDecoration(
                color: isCurrent
                    ? _camAccent.withValues(alpha: 0.18)
                    : _camControlBg,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: isCurrent
                      ? _camAccent
                      : Colors.white.withValues(alpha: 0.28),
                  width: isCurrent ? 2 : 1,
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
                  color: isCurrent
                      ? _camAccent
                      : Colors.white.withValues(alpha: 0.5),
                  size: size * 0.4)
                  : null,
            ),
            if (isCaptured)
              Positioned(
                right: -2,
                top: -2,
                child: Container(
                  padding: const EdgeInsets.all(2),
                  decoration: const BoxDecoration(
                    color: _camAccent,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.check,
                      size: 10, color: _camOnAccent),
                ),
              ),
          ],
        ),
        if (label != null) ...[
          const SizedBox(height: 5),
          Text(
            label!,
            style: TextStyle(
              color: isCurrent
                  ? _camAccent
                  : Colors.white.withValues(alpha: 0.7),
              fontSize: 10.5,
              fontWeight: isCurrent ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ],
      ],
    );
  }
}

class _GuideFrame extends StatelessWidget {
  final Size size;

  final String? zoomLabel;

  /// Whether to paint the corner brackets and the centre scan line.
  ///
  /// They are drawn for label capture, where the still really is cropped to
  /// this rect before OCR sees it — the box is a promise about what will be
  /// kept. Damage capture keeps the full frame and the detector sweeps the
  /// whole photo, so the same box would promise a crop that never happens and
  /// push people into framing tighter than they need to. Off for damage; the
  /// zoom pill still shows, since pinch-zoom works in both phases.
  final bool showFrame;

  const _GuideFrame({
    required this.size,
    this.zoomLabel,
    this.showFrame = true,
  });

  @override
  Widget build(BuildContext context) {
    final arm = (size.shortestSide * 0.26).clamp(18.0, 46.0);

    return SizedBox(
      width: size.width,
      height: size.height,
      child: Stack(
        children: [
          if (showFrame) ...[
            Positioned.fill(
              child: CustomPaint(painter: _GuideCornerPainter(arm: arm)),
            ),
            Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: Container(
                  height: 2,
                  width: double.infinity,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        _camAccent.withValues(alpha: 0),
                        _camAccent,
                        _camAccent.withValues(alpha: 0),
                      ],
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: _camAccent.withValues(alpha: 0.5),
                        blurRadius: 12,
                        spreadRadius: 1,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
          if (zoomLabel != null)
            Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: _camTrackBg,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    zoomLabel!,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.w600),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _GuideCornerPainter extends CustomPainter {
  final double arm;

  const _GuideCornerPainter({required this.arm});

  @override
  void paint(Canvas canvas, Size size) {
    const r = 16.0;
    final w = size.width;
    final h = size.height;

    final paint = Paint()
      ..color = Colors.white.withValues(alpha: 0.95)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final path = Path()
      ..moveTo(0, arm + r)
      ..lineTo(0, r)
      ..arcToPoint(const Offset(r, 0), radius: const Radius.circular(r))
      ..lineTo(arm + r, 0)
      ..moveTo(w - arm - r, 0)
      ..lineTo(w - r, 0)
      ..arcToPoint(Offset(w, r), radius: const Radius.circular(r))
      ..lineTo(w, arm + r)
      ..moveTo(w, h - arm - r)
      ..lineTo(w, h - r)
      ..arcToPoint(Offset(w - r, h), radius: const Radius.circular(r))
      ..lineTo(w - arm - r, h)
      ..moveTo(arm + r, h)
      ..lineTo(r, h)
      ..arcToPoint(Offset(0, h - r), radius: const Radius.circular(r))
      ..lineTo(0, h - arm - r);

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_GuideCornerPainter oldDelegate) =>
      oldDelegate.arm != arm;
}

class _CircleButton extends StatelessWidget {
  final Color color;
  final IconData? icon;
  final Color iconColor;
  final double size;
  final VoidCallback? onTap;
  final bool isShutter;
  final bool isTaking;

  /// "2/3" while a multi-frame capture is running, so the wait reads as
  /// progress rather than as the app having hung.
  final String? progress;

  const _CircleButton({
    required this.color,
    required this.icon,
    required this.iconColor,
    required this.size,
    required this.onTap,
    this.isShutter = false,
    this.isTaking = false,
    this.progress,
  });

  @override
  Widget build(BuildContext context) {
    if (isShutter) {
      return GestureDetector(
        onTap: onTap,
        child: Container(
          width: size,
          height: size,
          padding: const EdgeInsets.all(5),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.black.withValues(alpha: 0.35),
            border: Border.all(
                color: Colors.white.withValues(alpha: 0.9), width: 3),
          ),
          child: isTaking
              ? Stack(
            alignment: Alignment.center,
            children: [
              const Padding(
                padding: EdgeInsets.all(12),
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: Colors.white),
              ),
              if (progress != null)
                Text(progress!,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.bold)),
            ],
          )
              : Container(
            decoration: BoxDecoration(shape: BoxShape.circle, color: color),
          ),
        ),
      );
    }

    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(shape: BoxShape.circle, color: color),
        child: Icon(icon, color: iconColor, size: size * 0.42),
      ),
    );
  }
}

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

    _scale = Tween<double>(begin: 1.3, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOut),
    );

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

class _ScanProgressCard extends StatelessWidget {
  final _ScanUiStage stage;

  final List<_ScanUiStage> stages;

  const _ScanProgressCard({required this.stage, required this.stages});

  static const _subtitles = {
    _ScanUiStage.extractingText: 'Reading text from your label photos',
    _ScanUiStage.matchingRegistry: 'Checking against the FDA database',
    _ScanUiStage.classifying: 'Running the compliance model',
    _ScanUiStage.checkingDamage: 'Inspecting the packaging for damage',
  };

  static const _stepLabels = {
    _ScanUiStage.extractingText: 'Extracting label text (OCR)',
    _ScanUiStage.matchingRegistry: 'Matching FDA registry',
    _ScanUiStage.classifying: 'Classifying label result',
    _ScanUiStage.checkingDamage: 'Checking packaging for damage',
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
          for (final s in stages)
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
