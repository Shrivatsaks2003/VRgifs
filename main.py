import cv2
import numpy as np
from pyzbar import pyzbar
import os
import requests
import hashlib
from gif_handler import GIFHandler

# Configuration
ASSETS_DIR = "assets"
CACHE_DIR = "cache"
WINDOW_NAME = "VR GIF Viewer (SBS)"
SCREEN_WIDTH = 1280
SCREEN_HEIGHT = 720

def detect_qr(frame):
    """Detects QR codes with a fallback digital zoom for distant objects."""
    # 1. Try normal detection first
    barcodes = pyzbar.decode(frame)
    if barcodes:
        return process_barcodes(barcodes)
    
    # 2. If not found, try a 2x digital zoom on the center (where the VR user is looking)
    h, w = frame.shape[:2]
    cy, cx = h // 2, w // 2
    # Define a crop area (half the size)
    cw, ch = w // 2, h // 2
    crop = frame[cy-ch//2:cy+ch//2, cx-cw//2:cx+cw//2]
    # Resize back up to original size (digital zoom)
    zoomed = cv2.resize(crop, (w, h), interpolation=cv2.INTER_LINEAR)
    
    barcodes = pyzbar.decode(zoomed)
    if barcodes:
        # Note: Bounding box will be relative to zoomed frame, but that's okay 
        # since we just need the data and a rough location.
        return process_barcodes(barcodes)
        
    return None, None

def process_barcodes(barcodes):
    """Helper to extract data and rect from barcodes."""
    for barcode in barcodes:
        barcode_data = barcode.data.decode("utf-8")
        (x, y, w, h) = barcode.rect
        return barcode_data, (x, y, w, h)
    return None, None

def apply_hologram(gif_frame):
    """Applies a holographic effect (scanlines and blue tint) to a frame."""
    if gif_frame is None:
        return None
    
    h, w = gif_frame.shape[:2]
    # 1. Add blue/cyan tint
    # We'll boost the blue and green channels and lower red
    hologram = gif_frame.astype(np.float32)
    hologram[:, :, 0] *= 1.2  # Blue
    hologram[:, :, 1] *= 1.1  # Green
    hologram[:, :, 2] *= 0.7  # Red
    hologram = np.clip(hologram, 0, 255).astype(np.uint8)
    
    # 2. Add scanlines
    for i in range(0, h, 3):
        hologram[i:i+1, :] = hologram[i:i+1, :] * 0.5
        
    return hologram

def draw_hud(frame, status_text):
    """Draws a VR HUD (reticle and status) on the frame."""
    h, w = frame.shape[:2]
    color = (0, 255, 255) # Cyan
    
    # Draw central reticle (crosshair)
    length = 20
    gap = 5
    cv2.line(frame, (w//2, h//2 - length), (w//2, h//2 - gap), color, 1)
    cv2.line(frame, (w//2, h//2 + gap), (w//2, h//2 + length), color, 1)
    cv2.line(frame, (w//2 - length, h//2), (w//2 - gap, h//2), color, 1)
    cv2.line(frame, (w//2 + gap, h//2), (w//2 + length, h//2), color, 1)
    
    # Draw corner brackets
    offset = 40
    size = 30
    # Top Left
    cv2.line(frame, (offset, offset), (offset + size, offset), color, 1)
    cv2.line(frame, (offset, offset), (offset, offset + size), color, 1)
    # Top Right
    cv2.line(frame, (w - offset, offset), (w - offset - size, offset), color, 1)
    cv2.line(frame, (w - offset, offset), (w - offset, offset + size), color, 1)
    # Bottom Left
    cv2.line(frame, (offset, h - offset), (offset + size, h - offset), color, 1)
    cv2.line(frame, (offset, h - offset), (offset, h - offset - size), color, 1)
    # Bottom Right
    cv2.line(frame, (w - offset, h - offset), (w - offset - size, h - offset), color, 1)
    cv2.line(frame, (w - offset, h - offset), (w - offset, h - offset - size), color, 1)
    
    # Draw status text
    cv2.putText(frame, f"SYS_STATUS: {status_text}", (offset + 10, offset + 20), 
                cv2.FONT_HERSHEY_SIMPLEX, 0.4, color, 1)
    
    return frame

def overlay_gif(frame, gif_frame, rect):
    """Overlays a GIF frame onto the camera frame with alpha blending."""
    if gif_frame is None or rect is None:
        return frame
    
    x, y, w, h = rect
    scale = 1.0
    nw, nh = int(w * scale), int(h * scale)
    nx, ny = int(x - (nw - w) / 2), int(y - (nh - h) / 2)
    
    nx, ny = max(0, nx), max(0, ny)
    nw = min(frame.shape[1] - nx, nw)
    nh = min(frame.shape[0] - ny, nh)
    
    if nw <= 0 or nh <= 0:
        return frame

    resized_gif = cv2.resize(gif_frame, (nw, nh))
    
    # Separate color and alpha channels
    if resized_gif.shape[2] == 4:
        gif_bgr = resized_gif[:, :, :3]
        gif_alpha = resized_gif[:, :, 3] / 255.0
        
        # Alpha blending
        for c in range(3):
            frame[ny:ny+nh, nx:nx+nw, c] = (
                gif_alpha * gif_bgr[:, :, c] + 
                (1.0 - gif_alpha) * frame[ny:ny+nh, nx:nx+nw, c]
            )
    else:
        # Fallback if GIF has no alpha channel
        frame[ny:ny+nh, nx:nx+nw] = resized_gif
        
    return frame

def create_sbs_view(frame):
    """Creates a Side-By-Side VR view from a single frame."""
    # Resize frame to half width if needed, or just duplicate
    h, w = frame.shape[:2]
    # We want a final image that is SCREEN_WIDTH x SCREEN_HEIGHT
    # Each eye gets SCREEN_WIDTH/2 x SCREEN_HEIGHT
    eye_width = SCREEN_WIDTH // 2
    eye_height = SCREEN_HEIGHT
    
    # Resize the original frame to fit one eye's view
    eye_view = cv2.resize(frame, (eye_width, eye_height))
    
    # Combine for SBS
    sbs = np.hstack((eye_view, eye_view))
    return sbs

def get_gif_path(qr_data):
    """Determines if QR data is a local file or a URL, and returns a local path."""
    # 1. Check if it's a local file in assets
    local_path = os.path.join(ASSETS_DIR, qr_data)
    if os.path.exists(local_path) and local_path.endswith(".gif"):
        return local_path
    
    # 2. Check if it's a URL
    if qr_data.startswith(("http://", "https://")):
        if not os.path.exists(CACHE_DIR):
            os.makedirs(CACHE_DIR)
            
        # Create a unique filename based on the URL
        url_hash = hashlib.md5(qr_data.encode()).hexdigest()
        cached_path = os.path.join(CACHE_DIR, f"{url_hash}.gif")
        
        if os.path.exists(cached_path):
            return cached_path
            
        print(f"Downloading GIF from URL: {qr_data}")
        try:
            response = requests.get(qr_data, timeout=10)
            if response.status_code == 200:
                with open(cached_path, 'wb') as f:
                    f.write(response.content)
                print(f"Saved to cache: {cached_path}")
                return cached_path
        except Exception as e:
            print(f"Error downloading GIF: {e}")
            
    return None

def main():
    cap = cv2.VideoCapture(0)
    
    # Standard resolution for maximum frame rate/smoothness
    cap.set(cv2.CAP_PROP_FRAME_WIDTH, 640)
    cap.set(cv2.CAP_PROP_FRAME_HEIGHT, 480)
    
    if not cap.isOpened():
        print("Error: Could not open webcam.")
        return

    current_gif_path = None
    gif_handler = None
    last_rect = None
    persistence_counter = 0
    MAX_PERSISTENCE = 30 # Number of frames to keep GIF after losing QR
    
    print("VR GIF Viewer Started. Press 'q' to quit.")

    while True:
        ret, frame = cap.read()
        if not ret:
            break

        frame = cv2.flip(frame, 1)

        # 1. Detect QR
        qr_data, rect = detect_qr(frame)
        
        if qr_data:
            potential_path = get_gif_path(qr_data)
            if potential_path:
                # ONLY load if it's actually a different GIF
                if potential_path != current_gif_path:
                    print(f"Loading new GIF: {qr_data}")
                    current_gif_path = potential_path
                    gif_handler = GIFHandler(current_gif_path)
                    last_rect = rect # Reset to the exact rect on new GIF
                else:
                    if last_rect is None:
                        last_rect = rect
                    else:
                        # Smooth the position and size to prevent jitter
                        alpha = 0.2
                        last_rect = tuple(int(alpha * new_val + (1 - alpha) * old_val) for new_val, old_val in zip(rect, last_rect))
                
                persistence_counter = MAX_PERSISTENCE
        
        # 2. Overlay GIF if persistence > 0
        status = "SCANNING..."
        if gif_handler and persistence_counter > 0:
            status = "SIGNAL_LOCKED"
            gif_frame = gif_handler.get_next_frame()
            
            # The GIF will render normally without the hologram effect
            frame = overlay_gif(frame, gif_frame, last_rect)
            
            # Decrease persistence if QR is lost
            if not qr_data:
                persistence_counter -= 1
        
        # 3. Add HUD (Removed as requested)
        # frame = draw_hud(frame, status)

        # 4. Create VR View
        sbs_view = create_sbs_view(frame)

        # 4. Show
        cv2.imshow(WINDOW_NAME, sbs_view)

        if cv2.waitKey(1) & 0xFF == ord('q'):
            break

    cap.release()
    cv2.destroyAllWindows()

if __name__ == "__main__":
    main()
