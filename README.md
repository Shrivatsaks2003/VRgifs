# VR GIF Viewer (Flutter)

A Flutter rebuild of the original VR GIF viewer. The app scans QR codes through
the device camera, resolves each QR payload to either a bundled GIF asset or a
remote GIF URL, and overlays the animation into a side-by-side VR layout.

## Features

- Real-time QR scanning with `mobile_scanner`
- Side-by-side stereoscopic layout for mobile VR viewers
- GIF overlay placement based on the detected QR code bounds
- Position smoothing to reduce jitter
- Short persistence window so the GIF stays visible after the QR code drops out
- Local asset GIFs and remote URL GIFs
- Torch toggle and camera switching

## Local GIF assets

Put local GIF files inside `assets/` and encode the filename in the QR code.

Examples:

- `cat.gif`
- `holograms/orb.gif`

The app tries both the QR value itself and `assets/<qr-value>`.

## Run

```bash
flutter pub get
flutter run
```

## Project structure

- `lib/main.dart`: main Flutter app and VR viewer screen
- `assets/`: bundled local GIF files
- `android/`, `ios/`, `web/`: generated Flutter platform runners

## Notes

- Camera permission is required on Android and iOS.
- Remote GIFs are loaded directly from their URLs instead of being cached to a
  project folder like the Python version.
- The scanner is configured for QR codes only, matching the original workflow.
