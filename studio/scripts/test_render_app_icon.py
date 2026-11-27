"""Exercise icon scratch cleanup without invoking macOS tools."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

HELPER = Path(__file__).resolve().with_name("render-app-icon.sh")
MOCK = '''#!/bin/sh
name=${0##*/}
[ "$FAIL_TOOL" != "$name" ] || exit 7
case "$name" in
    rsvg-convert) printf 'png' ;;
    sips) printf 'png' > "$6" ;;
    iconutil)
        [ "$EMPTY_ICON" = 1 ] && exit 0
        [ -s "$3/icon_512x512@2x.png" ] || exit 8
        [ "$(find "$3" -name '*.png' | wc -l)" -eq 10 ] || exit 8
        printf 'icns' > "$5" ;;
esac
'''


class RenderAppIconTests(unittest.TestCase):
    def run_render(self, fail_tool="", empty_icon="0"):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            tools = root / "bin"
            scratch = root / "scratch space"
            tools.mkdir()
            scratch.mkdir()
            for tool in ("rsvg-convert", "sips", "iconutil"):
                script = tools / tool
                script.write_text(MOCK)
                script.chmod(0o755)
            source = root / "source logo.svg"
            source.write_text("<svg/>")
            output = root / "output icon.icns"
            env = dict(os.environ, PATH=f"{tools}:{os.environ['PATH']}",
                       TMPDIR=str(scratch), FAIL_TOOL=fail_tool, EMPTY_ICON=empty_icon)
            result = subprocess.run(
                ["sh", "-c", '. "$1"; render_app_icon "$2" "$3"', "test",
                 str(HELPER), str(source), str(output)], env=env,
                capture_output=True, text=True)
            self.assertEqual(list(scratch.iterdir()), [], result.stderr)
            if fail_tool or empty_icon == "1":
                self.assertNotEqual(result.returncode, 0, result.stderr)
            else:
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(output.read_text(), "icns")

    def test_success(self):
        self.run_render()

    def test_renderer_failure(self):
        self.run_render(fail_tool="rsvg-convert")

    def test_resize_failure(self):
        self.run_render(fail_tool="sips")

    def test_iconutil_failure(self):
        self.run_render(fail_tool="iconutil")

    def test_missing_output(self):
        self.run_render(empty_icon="1")


if __name__ == "__main__":
    unittest.main()
