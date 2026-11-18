"""Build the native Apple Silicon app with the installed Apple compiler only."""
from pathlib import Path
import plistlib
import subprocess

root = Path(__file__).resolve().parent
app = root / "build/LoopCapture.app"
contents = app / "Contents"
(contents / "MacOS").mkdir(parents=True, exist_ok=True)
plist = {
    "CFBundleExecutable": "LoopCapture",
    "CFBundleIdentifier": "local.rahul.LoopCapture",
    "CFBundleName": "LoopCapture",
    "CFBundleDisplayName": "LoopCapture",
    "CFBundlePackageType": "APPL",
    "CFBundleShortVersionString": "1.0",
    "CFBundleVersion": "1",
    "LSMinimumSystemVersion": "15.0",
    "LSUIElement": True,
    "LSRequiresNativeExecution": True,
    "NSHighResolutionCapable": True,
    "NSScreenCaptureUsageDescription": "Record the area you select, then preview before saving.",
}
(contents / "Info.plist").write_bytes(plistlib.dumps(plist))
command = [
    "xcrun", "clang++", "-std=c++17", "-fobjc-arc", "-O2", "-arch", "arm64",
    "-mmacosx-version-min=15.0", "-Wall", "-Wextra", "-Wno-unused-parameter",
    "-isystem", subprocess.check_output(["xcrun", "--show-sdk-path"], text=True).strip() + "/usr/include/c++/v1",
    str(root / "LoopCapture.mm"), "-o", str(contents / "MacOS/LoopCapture"),
    "-framework", "AppKit", "-framework", "ScreenCaptureKit", "-framework", "AVKit",
    "-framework", "AVFoundation", "-framework", "CoreMedia", "-framework", "Carbon",
    "-framework", "UniformTypeIdentifiers",
    "-framework", "ImageIO",
]
result = subprocess.run(command, text=True, capture_output=True)
(root / 'build/compiler.log').write_text(result.stdout + result.stderr)
if result.returncode:
    print('\n'.join(line for line in result.stderr.splitlines() if 'error:' in line or 'warning:' in line)[:5000])
    raise SystemExit(result.returncode)
if result.stderr:
    print(result.stderr)
subprocess.run(["codesign", "--force", "--sign", "-", "--identifier", "local.rahul.LoopCapture", str(app)], check=True)
subprocess.run([str(contents / "MacOS/LoopCapture"), "--self-test"], check=True)
print(app)
