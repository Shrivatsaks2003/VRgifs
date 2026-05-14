# VR GIF Viewer (Flutter)

A Flutter VR GIF viewer built around an offline-first flow. GIFs can be shared
into the app from the Android share sheet, copied into app-local storage, and
assigned a QR code that resolves to that locally stored GIF ID.

## Features

- Real-time QR scanning with `mobile_scanner`
- Android native GIF input box for direct keyboard GIF insertion
- Android share-target flow for GIFs coming from the share sheet of other apps
- App-local GIF persistence in the application documents directory
- In-app QR generation for locally stored GIF IDs
- Side-by-side stereoscopic layout for mobile VR viewers
- GIF overlay placement based on the detected QR code bounds
- Position smoothing to reduce jitter
- Short persistence window so the GIF stays visible after the QR code drops out
- Bundled asset GIF fallback
- Torch toggle and camera switching

## Offline flow

1. On Android, open the `Library + QR` tab and tap the native keyboard GIF input box.
2. Send a GIF from the keyboard, or share a GIF into the app from another Android app.
3. The app copies that GIF into its local documents directory.
4. The app generates a QR payload like `vrgif://local/<gif-id>`.
5. Scanning that QR loads the matching local GIF if it exists on the device.

Important: a QR code only carries the local GIF identifier, not the full GIF
binary. Another device will need the same GIF stored in its app memory for the
QR to resolve offline.

## Bundled asset GIFs

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
- Imported GIFs are stored in the app documents folder on the phone.
- On Android, the app can receive a shared GIF directly from another app.
- The app now also exposes a focused native rich-content text editor so keyboards
  such as Gboard can commit GIF content directly into the app.
- Remote URL resolution has been removed from the scanner flow.
- The scanner is configured for QR codes only, matching the original workflow.
