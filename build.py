"""Build the iPad app with Apple's Xcode 27 toolchain. Personal signing is separate."""
import plistlib
import shutil
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path


ROOT = Path(__file__).resolve().parent


def output(*args):
    return subprocess.check_output(args, text=True).strip()


def build(destination):
    sdk_version = output("xcrun", "--sdk", "iphoneos", "--show-sdk-version")
    if int(sdk_version.split(".")[0]) < 27:
        raise RuntimeError("The live capture target requires the iPadOS 27 SDK.")
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="GameLensLive-") as temp:
        stage = Path(temp)
        app = stage / "Payload" / "GameLensLive.app"
        subprocess.run([
            "xcodebuild", "-project", str(ROOT / "GameLensLive.xcodeproj"), "-target", "GameLensLive",
            "-configuration", "Release", "-sdk", "iphoneos", "ARCHS=arm64", "ONLY_ACTIVE_ARCH=NO",
            "CODE_SIGNING_ALLOWED=NO", f"SYMROOT={stage / 'products'}",
            f"OBJROOT={stage / 'objects'}", "build",
        ], check=True)
        products = list((stage / "products").rglob("GameLensLive.app"))
        if len(products) != 1:
            raise RuntimeError("Missing built application")
        shutil.copytree(products[0], app)
        metadata = list((app / "Metadata.appintents").rglob("*"))
        if not any(p.is_file() and p.stat().st_size > 0 for p in metadata):
            raise RuntimeError("The build did not contain Shortcuts action metadata")
        with (app / "Info.plist").open("rb") as f:
            info = plistlib.load(f)
        for icon in (ROOT / "Icons").glob("*.png"):
            shutil.copyfile(icon, app / icon.name)
        executable = app / info["CFBundleExecutable"]
        subprocess.run(["codesign", "--force", "--sign", "-", "--timestamp=none", app], check=True)
        subprocess.run(["codesign", "--verify", "--strict", app], check=True)
        if output("xcrun", "lipo", "-archs", executable) != "arm64":
            raise ValueError("Wrong platform architecture")
        package = stage / "GameLensLive.ipa"
        subprocess.run(["ditto", "-c", "-k", "--norsrc", "--keepParent", stage / "Payload", package], check=True)
        with zipfile.ZipFile(package) as archive:
            assert archive.testzip() is None
            assert "Payload/GameLensLive.app/GameLensLive" in archive.namelist()
        shutil.copyfile(package, destination)
    print(destination, flush=True)


if __name__ == "__main__":
    build(Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else ROOT / "build" / "GameLensLive.ipa")
