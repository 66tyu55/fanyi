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
    sdk_path = output("xcrun", "--sdk", "iphoneos", "--show-sdk-path")
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="GameLensLive-") as temp:
        stage = Path(temp)
        app = stage / "Payload" / "GameLensLive.app"
        app.mkdir(parents=True)
        with (ROOT / "Info.plist").open("rb") as f:
            info = plistlib.load(f)
        info["DTPlatformName"] = "iphoneos"
        info["DTSDKName"] = "iphoneos" + sdk_version
        info["DTPlatformVersion"] = sdk_version
        with (app / "Info.plist").open("wb") as f:
            plistlib.dump(info, f, fmt=plistlib.FMT_BINARY)
        for icon in (ROOT / "Icons").glob("*.png"):
            shutil.copyfile(icon, app / icon.name)
        executable = app / info["CFBundleExecutable"]
        subprocess.run([
            "xcrun", "--sdk", "iphoneos", "swiftc", "-sdk", sdk_path,
            "-target", "arm64-apple-ios27.0", "-module-name", "GameLensLive",
            "-swift-version", "5", "-parse-as-library", "-O",
            *sorted((ROOT / "Sources").glob("*.swift")), "-o", executable,
        ], check=True)
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
