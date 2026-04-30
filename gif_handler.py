import cv2
import numpy as np
from PIL import Image, ImageSequence

class GIFHandler:
    def __init__(self, file_path):
        self.file_path = file_path
        self.frames = []
        self.current_frame_index = 0
        self.load_gif(file_path)

    def load_gif(self, file_path):
        """Loads a GIF and extracts frames as OpenCV-compatible images with Alpha channel."""
        try:
            with Image.open(file_path) as img:
                for frame in ImageSequence.Iterator(img):
                    # Convert PIL image to RGBA to preserve transparency
                    frame_rgba = frame.convert('RGBA')
                    frame_np = np.array(frame_rgba)
                    # Convert to BGRA for OpenCV
                    frame_bgra = cv2.cvtColor(frame_np, cv2.COLOR_RGBA2BGRA)
                    self.frames.append(frame_bgra)
            print(f"Loaded {len(self.frames)} frames from {file_path}")
        except Exception as e:
            print(f"Error loading GIF {file_path}: {e}")
            self.frames = []

    def get_next_frame(self):
        """Returns the next frame in the sequence."""
        if not self.frames:
            return None
        
        frame = self.frames[self.current_frame_index]
        self.current_frame_index = (self.current_frame_index + 1) % len(self.frames)
        return frame

    def reset(self):
        """Resets the animation to the first frame."""
        self.current_frame_index = 0
