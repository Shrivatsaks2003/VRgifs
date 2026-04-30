# VR GIF Viewer (SBS)

A Python-based virtual reality application that brings digital content into the physical world via QR codes. This tool scans QR codes through a webcam and overlays associated GIF animations onto the real-world view in a Side-by-Side (SBS) format, optimized for VR headsets.

## 🚀 Features

- **Real-time QR Detection**: Uses `pyzbar` for high-speed QR code scanning.
- **SBS VR Rendering**: Side-by-Side output for compatibility with mobile VR headsets (Google Cardboard, etc.).
- **Dynamic Content Loading**:
  - **Local Assets**: Loads GIFs from the `assets/` directory.
  - **Remote URLs**: Automatically downloads and caches GIFs from URLs encoded in QR codes.
- **Smart Persistence**: GIFs remain visible for a short period even if the QR code leaves the camera's field of view.
- **Holographic Aesthetics**: Smooth alpha blending for transparent GIFs.
- **Jitter Reduction**: Position smoothing algorithms for a stable viewing experience.
- **Digital Zoom**: Enhanced detection capabilities for distant QR codes.

## 🛠️ Prerequisites

- Python 3.8+
- A webcam
- A VR headset (for the SBS effect)
- ZBar library (required for `pyzbar`)
  - **Linux**: `sudo apt-get install libzbar0`
  - **macOS**: `brew install zbar`
  - **Windows**: Included in the `pyzbar` wheel.

## 📦 Installation

1. **Clone the repository**:
   ```bash
   git clone <repository-url>
   cd VRgifs
   ```

2. **Install dependencies**:
   ```bash
   pip install -r requirements.txt
   ```

## 🎮 Usage

1. **Prepare your QR Codes**:
   - Create a QR code containing either a filename (e.g., `cat.gif`) or a direct link to a GIF (e.g., `https://example.com/dance.gif`).
   - If using local files, place them in an `assets/` folder in the project root.

2. **Run the application**:
   ```bash
   python main.py
   ```

3. **View in VR**:
   - Mount your phone/screen in your VR headset.
   - Point the camera at a QR code to trigger the GIF overlay.
   - Press **'q'** to exit the application.

## 🏗️ Project Structure

- `main.py`: The core engine handling camera feed, QR detection, and SBS rendering.
- `gif_handler.py`: Manages GIF loading, frame extraction, and animation loops.
- `requirements.txt`: Python package dependencies.
- `cache/`: (Auto-generated) Stores downloaded remote GIFs.

## 🧪 How it Works

1. **Capture**: The app grabs frames from the webcam.
2. **Detection**: It scans for QR codes. If none are found, it applies a central "digital zoom" to help pick up distant codes.
3. **Processing**: Once a code is found, the app determines if it's a local file or a URL.
4. **Rendering**: The GIF frames are extracted using `Pillow`, converted for `OpenCV`, and alpha-blended onto the camera frame at the QR code's location.
5. **VR Output**: The final frame is duplicated and resized into a Side-by-Side format for stereoscopic viewing.

---
*Created with ❤️ for the VR community.*
