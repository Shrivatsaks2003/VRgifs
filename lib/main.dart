import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const VrGifsApp());
}

class VrGifsApp extends StatelessWidget {
  const VrGifsApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'VR GIF Viewer',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF03070A),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF44E0D8),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const VrGifViewerPage(),
    );
  }
}

class VrGifViewerPage extends StatefulWidget {
  const VrGifViewerPage({super.key});

  @override
  State<VrGifViewerPage> createState() => _VrGifViewerPageState();
}

class _VrGifViewerPageState extends State<VrGifViewerPage> {
  static const Duration _persistenceWindow = Duration(seconds: 2);
  static const double _smoothingAlpha = 0.2;

  final MobileScannerController _scannerController = MobileScannerController(
    autoStart: true,
    autoZoom: false,
    cameraResolution: const Size(640, 480),
    detectionSpeed: DetectionSpeed.normal,
    detectionTimeoutMs: 150,
    facing: CameraFacing.back,
    formats: <BarcodeFormat>[BarcodeFormat.qrCode],
  );

  Timer? _persistenceTicker;
  _ResolvedGif? _activeGif;
  Rect? _rawBarcodeRect;
  Size _captureSize = Size.zero;
  DateTime? _persistUntil;
  String _statusText = 'SCANNING...';
  String? _lastDetectedValue;
  bool _torchEnabled = false;
  int _scanGeneration = 0;

  bool get _hasLockedGif =>
      _activeGif != null &&
      _persistUntil != null &&
      DateTime.now().isBefore(_persistUntil!);

  @override
  void initState() {
    super.initState();
    _persistenceTicker = Timer.periodic(
      const Duration(milliseconds: 120),
      (_) => _handlePersistenceTick(),
    );
  }

  @override
  void dispose() {
    _persistenceTicker?.cancel();
    unawaited(_scannerController.dispose());
    super.dispose();
  }

  void _handlePersistenceTick() {
    if (!mounted || _persistUntil == null) {
      return;
    }

    if (DateTime.now().isBefore(_persistUntil!)) {
      return;
    }

    setState(() {
      _persistUntil = null;
      _rawBarcodeRect = null;
      _statusText = 'SCANNING...';
    });
  }

  Future<void> _handleDetect(BarcodeCapture capture) async {
    Barcode? selectedBarcode;
    for (final barcode in capture.barcodes) {
      final rawValue = barcode.rawValue?.trim();
      if (rawValue != null && rawValue.isNotEmpty) {
        selectedBarcode = barcode;
        break;
      }
    }

    if (selectedBarcode == null) {
      return;
    }

    final String detectedValue = selectedBarcode.rawValue!.trim();
    final Rect? newRect = _rectFromCorners(selectedBarcode.corners);

    if (detectedValue == _lastDetectedValue && _activeGif != null) {
      setState(() {
        _captureSize = capture.size;
        _rawBarcodeRect = _smoothRect(_rawBarcodeRect, newRect);
        _persistUntil = DateTime.now().add(_persistenceWindow);
        _statusText = 'SIGNAL_LOCKED';
      });
      return;
    }

    final int generation = ++_scanGeneration;
    final _ResolvedGif? resolvedGif = await _resolveGifSource(detectedValue);

    if (!mounted || generation != _scanGeneration) {
      return;
    }

    if (resolvedGif == null) {
      setState(() {
        _statusText = 'GIF_LOAD_FAILED';
      });
      return;
    }

    setState(() {
      _activeGif = resolvedGif;
      _captureSize = capture.size;
      _rawBarcodeRect = _smoothRect(_rawBarcodeRect, newRect);
      _persistUntil = DateTime.now().add(_persistenceWindow);
      _statusText = 'SIGNAL_LOCKED';
      _lastDetectedValue = detectedValue;
    });
  }

  Future<_ResolvedGif?> _resolveGifSource(String qrValue) async {
    final Uri? uri = Uri.tryParse(qrValue);
    if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) {
      return _ResolvedGif.network(
        uri.toString(),
        debugLabel: uri.toString(),
      );
    }

    final List<String> candidates = <String>[
      qrValue,
      'assets/$qrValue',
    ];

    for (final candidate in candidates) {
      try {
        await rootBundle.load(candidate);
        return _ResolvedGif.asset(
          candidate,
          debugLabel: candidate,
        );
      } on FlutterError {
        continue;
      }
    }

    return null;
  }

  Rect? _rectFromCorners(List<Offset> corners) {
    if (corners.isEmpty) {
      return null;
    }

    double left = corners.first.dx;
    double top = corners.first.dy;
    double right = corners.first.dx;
    double bottom = corners.first.dy;

    for (final corner in corners.skip(1)) {
      left = math.min(left, corner.dx);
      top = math.min(top, corner.dy);
      right = math.max(right, corner.dx);
      bottom = math.max(bottom, corner.dy);
    }

    return Rect.fromLTRB(left, top, right, bottom);
  }

  Rect? _smoothRect(Rect? previous, Rect? current) {
    if (current == null) {
      return previous;
    }

    if (previous == null) {
      return current;
    }

    return Rect.fromLTWH(
      _lerp(previous.left, current.left),
      _lerp(previous.top, current.top),
      _lerp(previous.width, current.width),
      _lerp(previous.height, current.height),
    );
  }

  double _lerp(double from, double to) {
    return (_smoothingAlpha * to) + ((1 - _smoothingAlpha) * from);
  }

  Future<void> _toggleTorch() async {
    await _scannerController.toggleTorch();
    if (!mounted) {
      return;
    }
    setState(() {
      _torchEnabled = !_torchEnabled;
    });
  }

  Future<void> _switchCamera() async {
    await _scannerController.switchCamera();
  }

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        body: SafeArea(
          child: Stack(
            children: [
              LayoutBuilder(
                builder: (context, constraints) {
                  final Size viewportSize = Size(
                    constraints.maxWidth,
                    constraints.maxHeight,
                  );
                  final Rect? overlayRect = _mapRectToViewport(
                    rawRect: _rawBarcodeRect,
                    captureSize: _captureSize,
                    viewportSize: viewportSize,
                  );

                  return _ViewerPanel(
                    controller: _scannerController,
                    gif: _activeGif,
                    overlayRect: overlayRect,
                    onDetect: _handleDetect,
                  );
                },
              ),
              IgnorePointer(
                child: Positioned.fill(
                  child: CustomPaint(painter: const _VrHudPainter()),
                ),
              ),
              Positioned(
                left: 18,
                top: 18,
                right: 18,
                child: _StatusPanel(
                  statusText: _statusText,
                  currentValue: _lastDetectedValue,
                  hasLockedGif: _hasLockedGif,
                ),
              ),
              Positioned(
                right: 18,
                bottom: 18,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    FilledButton.tonalIcon(
                      onPressed: _toggleTorch,
                      icon: Icon(
                        _torchEnabled ? Icons.flash_on : Icons.flash_off,
                      ),
                      label: Text(_torchEnabled ? 'Torch On' : 'Torch Off'),
                    ),
                    const SizedBox(height: 10),
                    FilledButton.tonalIcon(
                      onPressed: _switchCamera,
                      icon: const Icon(Icons.cameraswitch_outlined),
                      label: const Text('Switch Camera'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Rect? _mapRectToViewport({
    required Rect? rawRect,
    required Size captureSize,
    required Size viewportSize,
  }) {
    if (rawRect == null ||
        captureSize.width == 0 ||
        captureSize.height == 0 ||
        viewportSize.width == 0 ||
        viewportSize.height == 0) {
      return null;
    }

    final double widthScale = viewportSize.width / captureSize.width;
    final double heightScale = viewportSize.height / captureSize.height;
    final double scale = math.min(widthScale, heightScale);

    final double scaledWidth = captureSize.width * scale;
    final double scaledHeight = captureSize.height * scale;
    final double offsetX = (viewportSize.width - scaledWidth) / 2;
    final double offsetY = (viewportSize.height - scaledHeight) / 2;

    final Rect fitted = Rect.fromLTWH(
      offsetX + (rawRect.left * scale),
      offsetY + (rawRect.top * scale),
      rawRect.width * scale,
      rawRect.height * scale,
    );

    return Rect.fromCenter(
      center: fitted.center,
      width: fitted.width * 1.15,
      height: fitted.height * 1.15,
    );
  }
}

class _ViewerPanel extends StatelessWidget {
  const _ViewerPanel({
    required this.controller,
    required this.gif,
    required this.overlayRect,
    required this.onDetect,
  });

  final MobileScannerController controller;
  final _ResolvedGif? gif;
  final Rect? overlayRect;
  final ValueChanged<BarcodeCapture> onDetect;

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: ColoredBox(
        color: Colors.black,
        child: Stack(
          fit: StackFit.expand,
          children: [
            MobileScanner(
              controller: controller,
              fit: BoxFit.contain,
              onDetect: onDetect,
              tapToFocus: true,
              errorBuilder: (context, error) {
                return ColoredBox(
                  color: Colors.black,
                  child: Center(
                    child: Text(
                      error.errorDetails?.message ?? 'Camera unavailable',
                      textAlign: TextAlign.center,
                    ),
                  ),
                );
              },
            ),
            if (gif != null && overlayRect != null)
              Positioned.fromRect(
                rect: overlayRect!,
                child: IgnorePointer(
                  child: RepaintBoundary(
                    child: _GifOverlay(gif: gif!),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _GifOverlay extends StatelessWidget {
  const _GifOverlay({required this.gif});

  final _ResolvedGif gif;

  @override
  Widget build(BuildContext context) {
    final BorderRadius borderRadius = BorderRadius.circular(20);

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        boxShadow: const [
          BoxShadow(
            color: Color(0x6644E0D8),
            blurRadius: 24,
            spreadRadius: 6,
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: borderRadius,
        child: ColoredBox(
          color: Colors.transparent,
          child: gif.isAsset
              ? Image.asset(
                  gif.value,
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                  errorBuilder: _buildGifError,
                )
              : Image.network(
                  gif.value,
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                  errorBuilder: _buildGifError,
                ),
        ),
      ),
    );
  }

  Widget _buildGifError(
    BuildContext context,
    Object error,
    StackTrace? stackTrace,
  ) {
    return const ColoredBox(
      color: Color(0x22000000),
      child: Center(
        child: Icon(Icons.gif_box_outlined, color: Colors.white70),
      ),
    );
  }
}

class _StatusPanel extends StatelessWidget {
  const _StatusPanel({
    required this.statusText,
    required this.currentValue,
    required this.hasLockedGif,
  });

  final String statusText;
  final String? currentValue;
  final bool hasLockedGif;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xAA07121A),
        border: Border.all(color: const Color(0xFF44E0D8).withValues(alpha: 0.4)),
        borderRadius: BorderRadius.circular(22),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        child: DefaultTextStyle(
          style: Theme.of(context).textTheme.bodyMedium!.copyWith(
            color: Colors.white,
          ),
          child: Row(
            children: [
              Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  color: hasLockedGif
                      ? const Color(0xFF58F5AA)
                      : const Color(0xFFFFC857),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'VR GIF VIEWER',
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        letterSpacing: 2,
                        color: const Color(0xFF99FFF6),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'SYS_STATUS: $statusText',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    if (currentValue != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        currentValue!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Colors.white70,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _VrHudPainter extends CustomPainter {
  const _VrHudPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final Paint cyan = Paint()
      ..color = const Color(0x6644E0D8)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;

    final Offset center = Offset(size.width / 2, size.height / 2);
    canvas.drawLine(
      Offset(center.dx - 18, center.dy),
      Offset(center.dx - 6, center.dy),
      cyan,
    );
    canvas.drawLine(
      Offset(center.dx + 6, center.dy),
      Offset(center.dx + 18, center.dy),
      cyan,
    );
    canvas.drawLine(
      Offset(center.dx, center.dy - 18),
      Offset(center.dx, center.dy - 6),
      cyan,
    );
    canvas.drawLine(
      Offset(center.dx, center.dy + 6),
      Offset(center.dx, center.dy + 18),
      cyan,
    );

    final Rect frame = Rect.fromLTWH(22, 22, size.width - 44, size.height - 44);
    const double corner = 26;
    canvas.drawLine(frame.topLeft, frame.topLeft + const Offset(corner, 0), cyan);
    canvas.drawLine(frame.topLeft, frame.topLeft + const Offset(0, corner), cyan);
    canvas.drawLine(
      frame.topRight,
      frame.topRight + const Offset(-corner, 0),
      cyan,
    );
    canvas.drawLine(
      frame.topRight,
      frame.topRight + const Offset(0, corner),
      cyan,
    );
    canvas.drawLine(
      frame.bottomLeft,
      frame.bottomLeft + const Offset(corner, 0),
      cyan,
    );
    canvas.drawLine(
      frame.bottomLeft,
      frame.bottomLeft + const Offset(0, -corner),
      cyan,
    );
    canvas.drawLine(
      frame.bottomRight,
      frame.bottomRight + const Offset(-corner, 0),
      cyan,
    );
    canvas.drawLine(
      frame.bottomRight,
      frame.bottomRight + const Offset(0, -corner),
      cyan,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _ResolvedGif {
  const _ResolvedGif._({
    required this.value,
    required this.isAsset,
    required this.debugLabel,
  });

  const _ResolvedGif.asset(
    String assetPath, {
    required String debugLabel,
  }) : this._(
         value: assetPath,
         isAsset: true,
         debugLabel: debugLabel,
       );

  const _ResolvedGif.network(
    String url, {
    required String debugLabel,
  }) : this._(
         value: url,
         isAsset: false,
         debugLabel: debugLabel,
       );

  final String value;
  final bool isAsset;
  final String debugLabel;
}
