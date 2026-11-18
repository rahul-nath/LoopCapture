"""Build the native Apple Silicon app with the installed Apple compiler only."""
import argparse
from pathlib import Path
import plistlib
import shutil
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--release", action="store_true", help="sign with the official Developer ID Application identity")
release = parser.parse_args().release
name = "LoopCapture" if release else "LoopCapture Dev"
identifier = "local.rahul.LoopCapture" if release else "local.rahul.LoopCapture.dev"
root = Path(__file__).resolve().parent
app = root / "build" / f"{name}.app"
contents = app / "Contents"
(contents / "MacOS").mkdir(parents=True, exist_ok=True)
resources = contents / "Resources"
resources.mkdir(exist_ok=True)
shutil.copyfile(root / "LICENSE", resources / "LICENSE")
plist = {
    "CFBundleExecutable": "LoopCapture",
    "CFBundleIdentifier": identifier,
    "CFBundleName": name,
    "CFBundleDisplayName": name,
    "CFBundlePackageType": "APPL",
    "CFBundleShortVersionString": "1.0.1",
    "CFBundleVersion": "2",
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
signing = ["--sign", "Developer ID Application: Rahul Nath (XV2AQBZSXC)", "--options", "runtime", "--timestamp"] if release else ["--sign", "-"]
subprocess.run(["codesign", "--force", *signing, "--identifier", identifier, app], check=True)
subprocess.run(["codesign", "--verify", "--strict", app], check=True)
subprocess.run([str(contents / "MacOS/LoopCapture"), "--self-test"], check=True)
print(app)
