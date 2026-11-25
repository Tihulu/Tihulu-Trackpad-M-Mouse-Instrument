"""Guard the app identity and dependency boundary of the standalone SDK."""
import json
from pathlib import Path
import plistlib
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
ENGINE = "tihulu-mac-instrument-engine"
NATIVE = "tihulu-mac-instrument-native"
APP = "Tihulu Trackpad & M. Mouse Instrument.app"
STUDIO = "NoSpeakerStudio"


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def check_sources():
    package = json.loads(subprocess.check_output(
        ["swift", "package", "--package-path", str(ROOT / "studio"), "dump-package"],
        timeout=30))
    products = {p["name"]: p for p in package["products"]}
    targets = {t["name"]: t for t in package["targets"]}
    require(package["name"] == STUDIO, "Swift package identity changed")
    require(products[STUDIO]["targets"] == [STUDIO], "App executable product changed")
    require(products[ENGINE]["targets"] == ["TihuluEngineCLI"], "Engine product changed")
    require(products[NATIVE]["targets"] == ["TihuluNativeCLI"], "Native product changed")
    require("tihulu-engine" not in products, "Generic engine alias is not allowed")
    def names(target):
        result = set()
        for dependency in targets[target]["dependencies"]:
            require(len(dependency) == 1, "Unknown dependency shape")
            kind, value = next(iter(dependency.items()))
            require(kind in {"byName", "target"} and isinstance(value, list)
                    and isinstance(value[0], str), "Unexpected dependency kind")
            result.add(value[0])
        return result
    require(names("TihuluEngineCLI") == {"NoSpeakerCore"}, "CLI must not depend on native/UI code")
    require(names("TihuluNativeCLI") == {"NoSpeakerMac"}, "Native CLI must not depend on Studio")
    require(names(STUDIO) == {"NoSpeakerCore", "NoSpeakerMac"}, "App target dependencies changed")
    require(names("NoSpeakerMac") == {"NoSpeakerCore"}, "Native dependency boundary changed")
    require(not names("NoSpeakerCore"), "Core dependency boundary changed")
    installer = (ROOT / "install-studio.sh").read_text()
    builder = (ROOT / "studio/scripts/build-app.sh").read_text()
    require('APP_NAME="' + APP + '"' in installer, "Installer app name changed")
    require('CLI_DEST="$BIN_ROOT/tihulu-trackpad-instrument"' in installer, "App launcher changed")
    require('Contents/MacOS/NoSpeakerStudio' in installer, "App launcher target changed")
    require(ENGINE not in installer and NATIVE not in installer, "Installer references developer executable")
    require('swift build -c release --product NoSpeakerStudio' in builder, "App release build must select Studio only")
    require('BUNDLE_ID="com.tihulu.trackpadmmouseinstrument"' in builder, "Stable bundle ID changed")
    require('BUNDLE_ID="com.tihulu.trackpadmmouseinstrument.preview"' in builder, "Preview bundle ID changed")
    require('<key>CFBundleExecutable</key><string>NoSpeakerStudio</string>' in builder, "Bundle executable changed")
    print("App identity and SDK dependency boundary verified.")


def check_bundle(path):
    contents = path / "Contents"
    with (contents / "Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    channel = info["TIHULUBuildChannel"]
    require(channel in {"stable", "preview"}, "Unexpected app channel")
    expected = "com.tihulu.trackpadmmouseinstrument" + (".preview" if channel == "preview" else "")
    require(info["CFBundleIdentifier"] == expected, "Built bundle ID changed")
    require(info["CFBundleExecutable"] == STUDIO, "Built executable changed")
    require({p.name for p in (contents / "MacOS").iterdir()} == {STUDIO}, "Unexpected bundled executable")
    require((contents / "MacOS" / STUDIO).is_file(), "Missing application executable")
    require(not any(p.name in {ENGINE, NATIVE} for p in contents.rglob("*")), "Developer engine leaked into app bundle")
    print("Built application contains only its original executable and bundle identity.")


if __name__ == "__main__":
    check_sources()
    if len(sys.argv) == 3 and sys.argv[1] == "--bundle":
        check_bundle(Path(sys.argv[2]))
    elif len(sys.argv) != 1:
        raise SystemExit("Usage: test_app_engine_boundary.py [--bundle APP]")
