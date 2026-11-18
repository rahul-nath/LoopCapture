"""Check an existing LoopCapture MP4/GIF pair with Apple's native frameworks."""
from pathlib import Path
import subprocess
import sys
import tempfile
import shutil

if len(sys.argv) not in (2, 3) or (len(sys.argv) == 3 and sys.argv[2] != "--copy"):
    raise SystemExit("Usage: check_media.py /path/to/Screen\u0020Recording.mp4")

root = Path(__file__).resolve().parents[1]
movie = Path(sys.argv[1]).resolve()
compiler = subprocess.check_output(["xcrun", "--show-sdk-path"], text=True).strip()
output = root / "build/check_media"
command = ["xcrun", "clang++", "-std=c++17", "-fobjc-arc", "-arch", "arm64", "-isystem", compiler + "/usr/include/c++/v1", str(root / "tests/check_media.mm"), "-o", str(output)]
for framework in ["AppKit", "AVKit", "AVFoundation", "CoreMedia", "ScreenCaptureKit", "Carbon", "UniformTypeIdentifiers", "ImageIO"]:
    command += ["-framework", framework]
subprocess.run(command, check=True)
with tempfile.TemporaryDirectory() as directory:
    recording = Path(directory) / "capture.mp4"
    shutil.copyfile(movie, recording)
    subprocess.run([str(output), str(recording), str(recording.with_suffix(".gif")), *sys.argv[2:]], check=True)
