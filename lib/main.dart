import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import "dart:ui" as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:path_provider/path_provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

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

class _VrGifViewerPageState extends State<VrGifViewerPage>
    with SingleTickerProviderStateMixin {
  static const Duration _persistenceWindow = Duration(seconds: 2);
  static const double _smoothingAlpha = 0.2;
  static const String _qrPrefix = 'vrgif://gif/';
  static const MethodChannel _shareIntentMethodChannel = MethodChannel(
    'vrgifs/share_intent/methods',
  );
  static const EventChannel _shareIntentEventChannel = EventChannel(
    'vrgifs/share_intent/events',
  );

  final MobileScannerController _scannerController = MobileScannerController(
    autoStart: true,
    autoZoom: false,
    cameraResolution: const Size(640, 480),
    detectionSpeed: DetectionSpeed.normal,
    detectionTimeoutMs: 150,
    facing: CameraFacing.back,
    formats: <BarcodeFormat>[BarcodeFormat.qrCode],
  );

  late final TabController _tabController;
  Timer? _persistenceTicker;
  _ResolvedGif? _activeGif;
  Rect? _rawBarcodeRect;
  Size _captureSize = Size.zero;
  DateTime? _persistUntil;
  String _statusText = 'SCANNING...';
  String? _lastDetectedValue;
  bool _torchEnabled = false;
  bool _isBusy = false;
  int _scanGeneration = 0;
  List<_StoredGif> _storedGifs = <_StoredGif>[];
  String? _selectedGifId;
  StreamSubscription<dynamic>? _shareIntentSubscription;

  bool get _hasLockedGif =>
      _activeGif != null &&
      _persistUntil != null &&
      DateTime.now().isBefore(_persistUntil!);

  _StoredGif? get _selectedGif {
    for (final gif in _storedGifs) {
      if (gif.id == _selectedGifId) {
        return gif;
      }
    }
    return _storedGifs.isEmpty ? null : _storedGifs.first;
  }

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _persistenceTicker = Timer.periodic(
      const Duration(milliseconds: 120),
      (_) => _handlePersistenceTick(),
    );
    unawaited(_loadStoredGifs());
    _shareIntentSubscription = _shareIntentEventChannel
        .receiveBroadcastStream()
        .listen(_handleSharedGifEvent);
    unawaited(_loadInitialSharedGif());
  }

  @override
  void dispose() {
    _persistenceTicker?.cancel();
    unawaited(_shareIntentSubscription?.cancel());
    _tabController.dispose();
    unawaited(_scannerController.dispose());
    super.dispose();
  }

  Future<Directory> _gifDirectory() async {
    final Directory root = await getApplicationDocumentsDirectory();
    final Directory directory = Directory('${root.path}/gifs');
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    return directory;
  }

  Future<void> _loadStoredGifs() async {
    final Directory directory = await _gifDirectory();
    final List<FileSystemEntity> entities = directory.listSync();
    final List<_StoredGif> gifs = entities
        .whereType<File>()
        .where((file) => file.path.toLowerCase().endsWith('.gif'))
        .map(_StoredGif.fromFile)
        .toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

    if (!mounted) {
      return;
    }

    setState(() {
      _storedGifs = gifs;
      if (_selectedGifId == null ||
          !_storedGifs.any((gif) => gif.id == _selectedGifId)) {
        _selectedGifId = _storedGifs.isEmpty ? null : _storedGifs.first.id;
      }
    });
  }

  Future<void> _loadInitialSharedGif() async {
    try {
      final Map<Object?, Object?>? payload =
          await _shareIntentMethodChannel.invokeMapMethod<Object?, Object?>(
            'getInitialSharedGif',
          );
      if (payload == null) {
        return;
      }
      await _importSharedGif(_IncomingGif.fromChannelMap(payload));
    } on PlatformException {
      return;
    }
  }

  Future<void> _handleSharedGifEvent(dynamic event) async {
    if (event is! Map<Object?, Object?>) {
      return;
    }
    await _importSharedGif(_IncomingGif.fromChannelMap(event));
  }

  Future<void> _deleteGif(_StoredGif gif) async {
    await File(gif.path).delete();
    await _loadStoredGifs();
  }

  Future<void> _importSharedGif(_IncomingGif incomingGif) async {
    if (!incomingGif.isGif) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Shared file is not a GIF. Send a GIF to this app.'),
        ),
      );
      return;
    }

    setState(() {
      _isBusy = true;
    });

    try {
      final String importedId = await _importGifFile(
        sourcePath: incomingGif.path,
        originalName: incomingGif.name,
        sourceLabel: incomingGif.source,
      );

      if (!mounted) {
        return;
      }

      _tabController.animateTo(1);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            incomingGif.source == 'keyboard_input'
                ? 'Imported GIF from keyboard: ${incomingGif.name}'
                : 'Imported shared GIF: ${incomingGif.name}',
          ),
        ),
      );

      setState(() {
        _selectedGifId = importedId;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not import shared GIF: $error')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isBusy = false;
        });
      }
    }
  }

  Future<String> _importGifFile({
    required String sourcePath,
    required String originalName,
    required String sourceLabel,
  }) async {
    final File source = File(sourcePath);
    final Uint8List bytes = await source.readAsBytes();
    final String gifId = _computeGifId(bytes);
    final String sanitizedName = _sanitizeFileName(originalName);
    final String storedName = '${gifId}_$sanitizedName';

    final Directory directory = await _gifDirectory();
    final List<File> existingMatches = directory
        .listSync()
        .whereType<File>()
        .where((file) => _StoredGif.extractId(file.path) == gifId)
        .toList();

    if (existingMatches.isEmpty) {
      final File target = File('${directory.path}/$storedName');
      await target.writeAsBytes(bytes, flush: true);
    }

    await _loadStoredGifs();

    if (mounted) {
      setState(() {
        _selectedGifId = gifId;
        _statusText = switch (sourceLabel) {
          'share_sheet' => 'GIF_IMPORTED_FROM_SHARE',
          'keyboard_input' => 'GIF_IMPORTED_FROM_KEYBOARD',
          _ => 'GIF_IMPORTED',
        };
      });
    }

    return gifId;
  }

  String _sanitizeFileName(String input) {
    final String replaced = input.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
    return replaced.isEmpty ? 'gif.gif' : replaced;
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
      final String? rawValue = barcode.rawValue?.trim();
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
        _statusText = 'LOCAL_GIF_NOT_FOUND';
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
    if (qrValue.startsWith(_qrPrefix)) {
      final String gifId = qrValue.substring(_qrPrefix.length);
      return _resolveStoredGifById(gifId);
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

  Future<_ResolvedGif?> _resolveStoredGifById(String gifId) async {
    for (final gif in _storedGifs) {
      if (gif.id == gifId && await File(gif.path).exists()) {
        return _ResolvedGif.file(
          gif.path,
          debugLabel: gifId,
        );
      }
    }

    final Directory directory = await _gifDirectory();
    final List<File> matches = directory
        .listSync()
        .whereType<File>()
        .where((file) => _StoredGif.extractId(file.path) == gifId)
        .toList();

    if (matches.isEmpty) {
      return null;
    }

    final File gifFile = matches.first;
    return _ResolvedGif.file(
      gifFile.path,
      debugLabel: gifId,
    );
  }

  String _computeGifId(Uint8List bytes) {
    const int fnvOffset = 0xcbf29ce484222325;
    const int fnvPrime = 0x100000001b3;
    const int mask = 0xFFFFFFFFFFFFFFFF;

    int hash = fnvOffset;
    for (final byte in bytes) {
      hash ^= byte;
      hash = (hash * fnvPrime) & mask;
    }

    return hash.toRadixString(16).padLeft(16, '0');
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

  Future<void> _shareQrCode(_StoredGif gif) async {
    try {
      final Directory tempDirectory = await getTemporaryDirectory();
      final File qrFile = File('${tempDirectory.path}/${gif.id}_qr.png');
      final QrPainter painter = QrPainter(
        data: gif.qrPayload,
        version: QrVersions.auto,
        eyeStyle: const QrEyeStyle(
          eyeShape: QrEyeShape.square,
          color: Colors.black,
        ),
        dataModuleStyle: const QrDataModuleStyle(
          dataModuleShape: QrDataModuleShape.square,
          color: Colors.black,
        ),
      );

      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      const double size = 1600;
      
      // Draw solid white background
      canvas.drawRect(
        const Rect.fromLTWH(0, 0, size, size),
        Paint()..color = Colors.white,
      );
      
      // Paint the QR code
      painter.paint(canvas, const Size(size, size));
      
      final ui.Picture picture = recorder.endRecording();
      final ui.Image image = await picture.toImage(size.toInt(), size.toInt());
      final ByteData? pngBytes = await image.toByteData(format: ui.ImageByteFormat.png);

      if (pngBytes == null) {
        throw StateError('Unable to render QR image');
      }

      await qrFile.writeAsBytes(
        pngBytes.buffer.asUint8List(),
        flush: true,
      );

      await Share.shareXFiles(
        <XFile>[
          XFile(
            qrFile.path,
            mimeType: 'image/png',
            name: '${gif.displayName}_qr.png',
          ),
        ],
        text: 'QR code for VR GIF: ${gif.displayName}\n'
            'Scan this in the app to play the associated GIF.',
        subject: 'VR GIF QR Code',
      );
    } catch (error) {
      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not share QR: $error')),
      );
    }
  }

  Future<void> _shareGif(_StoredGif gif) async {
    try {
      await Share.shareXFiles(
        <XFile>[
          XFile(
            gif.path,
            mimeType: 'image/gif',
            name: gif.displayName,
          ),
        ],
        text: 'VR GIF: ${gif.displayName}',
        subject: 'VR GIF Share',
      );
    } catch (error) {
      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not share GIF: $error')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final _StoredGif? selectedGif = _selectedGif;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        body: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                child: _TopPanel(
                  tabController: _tabController,
                  statusText: _statusText,
                  currentValue: _lastDetectedValue,
                  hasLockedGif: _hasLockedGif,
                ),
              ),
              Expanded(
                child: TabBarView(
                  controller: _tabController,
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: _buildScannerTab(),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: _LibraryPanel(
                        gifs: _storedGifs,
                        selectedGifId: _selectedGifId,
                        selectedGif: selectedGif,
                        isBusy: _isBusy,
                        onSelect: (gif) {
                          setState(() {
                            _selectedGifId = gif.id;
                          });
                        },
                        onDelete: _deleteGif,
                        onShareQr: _shareQrCode,
                        onShareGif: _shareGif,
                      ),
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

  Widget _buildScannerTab() {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: const Color(0x3344E0D8)),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(28),
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

class _TopPanel extends StatelessWidget {
  const _TopPanel({
    required this.tabController,
    required this.statusText,
    required this.currentValue,
    required this.hasLockedGif,
  });

  final TabController tabController;
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
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Row(
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
                      const SizedBox(height: 2),
                      Text(
                        currentValue ?? 'Offline mode: local GIF IDs and assets only',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Colors.white70,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            TabBar(
              controller: tabController,
              dividerColor: Colors.transparent,
              indicator: BoxDecoration(
                color: const Color(0x2244E0D8),
                borderRadius: BorderRadius.circular(16),
              ),
              tabs: const [
                Tab(text: 'Scanner'),
                Tab(text: 'Library + QR'),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _LibraryPanel extends StatelessWidget {
  const _LibraryPanel({
    required this.gifs,
    required this.selectedGifId,
    required this.selectedGif,
    required this.isBusy,
    required this.onSelect,
    required this.onDelete,
    required this.onShareQr,
    required this.onShareGif,
  });

  final List<_StoredGif> gifs;
  final String? selectedGifId;
  final _StoredGif? selectedGif;
  final bool isBusy;
  final ValueChanged<_StoredGif> onSelect;
  final Future<void> Function(_StoredGif gif) onDelete;
  final Future<void> Function(_StoredGif gif) onShareQr;
  final Future<void> Function(_StoredGif gif) onShareGif;

  @override
  Widget build(BuildContext context) {
    if (gifs.isEmpty) {
      return LayoutBuilder(
        builder: (context, constraints) {
          final double keyboardInset = MediaQuery.viewInsetsOf(context).bottom;

          return SingleChildScrollView(
            padding: EdgeInsets.only(bottom: keyboardInset + 24),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: const Color(0xFF09141D),
                      borderRadius: BorderRadius.circular(28),
                      border: Border.all(color: const Color(0x3344E0D8)),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.gif_box_outlined,
                            size: 52,
                            color: Colors.white70,
                          ),
                          const SizedBox(height: 16),
                          Text(
                            Platform.isAndroid
                                ? 'Tap the keyboard box below or share a GIF into this app.'
                                : 'Share a GIF into this app to generate an offline QR code.',
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 12),
                          Text(
                            Platform.isAndroid
                                ? 'On Android, tap the native input box below, open Gboard GIFs, and send one directly into the app.'
                                : 'Open the GIF in another app, tap Share, and choose this app. After that, the GIF will appear here automatically.',
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(color: Colors.white70),
                          ),
                          if (Platform.isAndroid) ...[
                            const SizedBox(height: 20),
                            const _KeyboardGifInputCard(),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final bool stacked = constraints.maxWidth < 860;
        if (stacked) {
          return ListView(
            children: [
              if (Platform.isAndroid) ...[
                const _KeyboardGifInputCard(),
                const SizedBox(height: 16),
              ],
              SizedBox(
                height: 360,
                child: _GifListCard(
                  gifs: gifs,
                  selectedGifId: selectedGifId,
                  isBusy: isBusy,
                  onSelect: onSelect,
                  onDelete: onDelete,
                  onShareGif: onShareGif,
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                height: 560,
                child: _QrPreviewCard(
                  gif: selectedGif,
                  onShareQr: onShareQr,
                ),
              ),
            ],
          );
        }

        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              flex: 11,
              child: Column(
                children: [
                  if (Platform.isAndroid) ...[
                    const _KeyboardGifInputCard(),
                    const SizedBox(height: 16),
                  ],
                  Expanded(
                    child: _GifListCard(
                      gifs: gifs,
                      selectedGifId: selectedGifId,
                      isBusy: isBusy,
                      onSelect: onSelect,
                      onDelete: onDelete,
                      onShareGif: onShareGif,
                    ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              flex: 9,
              child: _QrPreviewCard(
                gif: selectedGif,
                onShareQr: onShareQr,
              ),
            ),
          ],
        );
      },
    );
  }
}

class _GifListCard extends StatelessWidget {
  const _GifListCard({
    required this.gifs,
    required this.selectedGifId,
    required this.isBusy,
    required this.onSelect,
    required this.onDelete,
    required this.onShareGif,
  });

  final List<_StoredGif> gifs;
  final String? selectedGifId;
  final bool isBusy;
  final ValueChanged<_StoredGif> onSelect;
  final Future<void> Function(_StoredGif gif) onDelete;
  final Future<void> Function(_StoredGif gif) onShareGif;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFF09141D),
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: const Color(0x3344E0D8)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Local GIF Library',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                if (isBusy) const SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              Platform.isAndroid
                  ? 'GIFs can arrive from the Android keyboard input box below or from the share sheet. They are copied into app-local storage and never resolved from a remote URL.'
                  : 'GIFs arrive from sharing into the app and are copied into app-local storage. They are never resolved from a remote URL.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Colors.white70,
              ),
            ),
            const SizedBox(height: 14),
            Expanded(
              child: ListView.separated(
                itemCount: gifs.length,
                separatorBuilder: (_, _) => const SizedBox(height: 10),
                itemBuilder: (context, index) {
                  final _StoredGif gif = gifs[index];
                  final bool isSelected = gif.id == selectedGifId;
                  return Material(
                    color: isSelected
                        ? const Color(0x2244E0D8)
                        : const Color(0xFF0D1A24),
                    borderRadius: BorderRadius.circular(20),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(20),
                      onTap: () => onSelect(gif),
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Row(
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(14),
                              child: SizedBox(
                                width: 72,
                                height: 72,
                                child: Image.file(
                                  File(gif.path),
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, _, _) => const ColoredBox(
                                    color: Color(0x22000000),
                                    child: Icon(Icons.gif_box_outlined),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    gif.displayName,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context).textTheme.titleMedium,
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    gif.id,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context).textTheme.bodySmall
                                        ?.copyWith(color: Colors.white70),
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              tooltip: 'Share GIF',
                              onPressed: () => onShareGif(gif),
                              icon: const Icon(Icons.share_outlined),
                            ),
                            IconButton(
                              tooltip: 'Delete',
                              onPressed: () => onDelete(gif),
                              icon: const Icon(Icons.delete_outline),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _KeyboardGifInputCard extends StatelessWidget {
  const _KeyboardGifInputCard();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFF0D1A24),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: const Color(0x3344E0D8)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Keyboard GIF Entry',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              'Tap inside this box, open your keyboard GIF picker, and send a GIF directly here.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Colors.white70,
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 76,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(18),
                child: const AndroidView(
                  viewType: 'vrgifs/gif_input_view',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _QrPreviewCard extends StatelessWidget {
  const _QrPreviewCard({
    required this.gif,
    required this.onShareQr,
  });

  final _StoredGif? gif;
  final Future<void> Function(_StoredGif gif) onShareQr;

  @override
  Widget build(BuildContext context) {
    final _StoredGif? currentGif = gif;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFF09141D),
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: const Color(0x3344E0D8)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: currentGif == null
            ? const Center(child: Text('Select a GIF to generate its QR'))
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'QR Payload',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                      ),
                      FilledButton.icon(
                        onPressed: () => onShareQr(currentGif),
                        icon: const Icon(Icons.ios_share_outlined),
                        label: const Text('Share QR'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'This QR stores the GIF ID. Share the GIF file separately using the share icon in the list, then scan this QR on another device to play it.',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Colors.white70,
                    ),
                  ),
                  const SizedBox(height: 18),
                  Expanded(
                    child: Center(
                      child: AspectRatio(
                        aspectRatio: 1,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(28),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(20),
                            child: QrImageView(
                              data: currentGif.qrPayload,
                              version: QrVersions.auto,
                              backgroundColor: Colors.white,
                              eyeStyle: const QrEyeStyle(
                                eyeShape: QrEyeShape.square,
                                color: Colors.black,
                              ),
                              dataModuleStyle: const QrDataModuleStyle(
                                dataModuleShape: QrDataModuleShape.square,
                                color: Colors.black,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  SelectableText(
                    'GIF ID: ${currentGif.id}\nQR: ${currentGif.qrPayload}',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: const Color(0xFF99FFF6),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Scan result plays as soon as the same GIF has been imported into the app on that phone.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: const Color(0xFFFFC857),
                    ),
                  ),
                ],
              ),
      ),
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
          child: switch (gif.source) {
            _GifSource.asset => Image.asset(
                gif.value,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                errorBuilder: _buildGifError,
              ),
            _GifSource.file => Image.file(
                File(gif.value),
                fit: BoxFit.cover,
                gaplessPlayback: true,
                errorBuilder: _buildGifError,
              ),
          },
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

class _StoredGif {
  const _StoredGif({
    required this.id,
    required this.path,
    required this.displayName,
    required this.updatedAt,
  });

  factory _StoredGif.fromFile(File file) {
    final FileStat stat = file.statSync();
    final String filename = file.uri.pathSegments.isEmpty
        ? file.path
        : file.uri.pathSegments.last;
    final String id = extractId(filename);
    final String displayName = filename.replaceFirst(RegExp(r'^[^_]+_'), '');

    return _StoredGif(
      id: id,
      path: file.path,
      displayName: displayName,
      updatedAt: stat.modified,
    );
  }

  static String extractId(String pathOrName) {
    final String filename = pathOrName.split(Platform.pathSeparator).last;
    final int separatorIndex = filename.indexOf('_');
    if (separatorIndex <= 0) {
      return filename;
    }
    return filename.substring(0, separatorIndex);
  }

  final String id;
  final String path;
  final String displayName;
  final DateTime updatedAt;

  String get qrPayload => '${_VrGifViewerPageState._qrPrefix}$id';
}

class _IncomingGif {
  const _IncomingGif({
    required this.path,
    required this.name,
    required this.mimeType,
    required this.source,
  });

  factory _IncomingGif.fromChannelMap(Map<Object?, Object?> map) {
    final String path = (map['path'] ?? '').toString();
    final String name = (map['name'] ?? '').toString();
    final String mimeType = (map['mimeType'] ?? '').toString();
    final String source = (map['source'] ?? 'share_sheet').toString();

    return _IncomingGif(
      path: path,
      name: name.isEmpty ? 'shared.gif' : name,
      mimeType: mimeType,
      source: source,
    );
  }

  final String path;
  final String name;
  final String mimeType;
  final String source;

  bool get isGif =>
      mimeType == 'image/gif' || name.toLowerCase().endsWith('.gif');
}

enum _GifSource { asset, file }

class _ResolvedGif {
  const _ResolvedGif._({
    required this.value,
    required this.source,
    required this.debugLabel,
  });

  const _ResolvedGif.asset(
    String assetPath, {
    required String debugLabel,
  }) : this._(
         value: assetPath,
         source: _GifSource.asset,
         debugLabel: debugLabel,
       );

  const _ResolvedGif.file(
    String path, {
    required String debugLabel,
  }) : this._(
         value: path,
         source: _GifSource.file,
         debugLabel: debugLabel,
       );

  final String value;
  final _GifSource source;
  final String debugLabel;
}
