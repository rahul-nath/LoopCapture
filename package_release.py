"""Package the compiled recorder for installation in /Applications on compatible Macs."""
import argparse
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--notary-profile", metavar="NAME", help="build the signed release using this notarytool Keychain profile")
profile = parser.parse_args().notary_profile
root = Path(__file__).resolve().parent
name = "LoopCapture-macOS-arm64.pkg" if profile else "LoopCapture-Dev-macOS-arm64.pkg"
out = root / "build" / "signed" if profile else root / "build"
out.mkdir(parents=True, exist_ok=True)
# Build in an empty directory so local recordings and stale bundle contents cannot ship.
with tempfile.TemporaryDirectory(dir=out) as temporary:
    stage = Path(temporary)
    for source in ("build.py", "LoopCapture.mm", "LICENSE"):
        shutil.copyfile(root / source, stage / source)
    subprocess.run([sys.executable, stage / "build.py", *(["--release"] if profile else [])], check=True)
    app, = (stage / "build").glob("*.app")
    requirements = stage / "requirements.plist"
    requirements.write_bytes(plistlib.dumps({"arch": ["arm64"], "os": ["15.0"]}))
    package = stage / name
    signing = ["--sign", "Developer ID Installer: Rahul Nath (XV2AQBZSXC)", "--timestamp"] if profile else []
    subprocess.run([
        "productbuild", *signing, "--product", requirements, "--component", app, "/Applications", package,
    ], check=True)
    if profile:
        subprocess.run(["pkgutil", "--check-signature", package], check=True)
        result = subprocess.check_output([
            "xcrun", "notarytool", "submit", package, "--keychain-profile", profile,
            "--wait", "--output-format", "json",
        ], text=True)
        submission = json.loads(result)
        if submission["status"] != "Accepted":
            raise SystemExit(f"Notarization {submission['status']} for submission {submission['id']}")
        subprocess.run(["xcrun", "stapler", "staple", package], check=True)
        subprocess.run(["xcrun", "stapler", "validate", package], check=True)
    package.replace(out / name)
    print(out / name)
