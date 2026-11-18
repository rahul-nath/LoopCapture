"""Package the compiled recorder for installation in /Applications on compatible Macs."""
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parent
# Build in an empty directory so local recordings and stale bundle contents cannot ship.
with tempfile.TemporaryDirectory() as temporary:
    stage = Path(temporary)
    for name in ("build.py", "LoopCapture.mm", "LICENSE"):
        shutil.copyfile(root / name, stage / name)
    subprocess.run([sys.executable, stage / "build.py"], check=True)
    app = stage / "build" / "LoopCapture.app"
    requirements = stage / "requirements.plist"
    requirements.write_bytes(plistlib.dumps({"arch": ["arm64"], "os": ["15.0"]}))
    destination = root / "build" / "LoopCapture-macOS-arm64.pkg"
    destination.parent.mkdir(exist_ok=True)
    subprocess.run([
        "productbuild", "--product", requirements, "--component", app, "/Applications",
        stage / destination.name,
    ], check=True)
    shutil.copyfile(stage / destination.name, destination)
    print(destination)
