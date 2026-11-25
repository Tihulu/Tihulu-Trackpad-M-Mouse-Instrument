"""Fail CI when an opt-in native fixture lacks a mandatory isolated run.

Static inventory only; no MIDI access, no test execution, no dependencies.
The fixture annotation is deliberately standardized. Changing its spelling
requires updating the inventory contract rather than silently skipping it.
"""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
TESTS = ROOT / "studio" / "Tests" / "NoSpeakerMacTests"
WORKFLOW = ROOT / ".github" / "workflows" / "nospeaker-studio.yml"
MARKER = 'environment["TIHULU_NATIVE_OBSERVER_FIXTURE"]'
PATTERN = re.compile(
    r'@Test\(\.enabled\(if:ProcessInfo\.processInfo\.environment'
    r'\["TIHULU_NATIVE_OBSERVER_FIXTURE"\]\s*==\s*"1"\s*&&\s*'
    r'ProcessInfo\.processInfo\.environment\["CI"\]\s*==\s*"true"\)\)\s*'
    r'@MainActor\s+func\s+(native\w+)\s*\('
)

def inventory():
    names = []
    for path in sorted(TESTS.rglob("*.swift")):
        source = path.read_text(encoding="utf-8")
        found = PATTERN.findall(source)
        assert source.count(MARKER) == len(found), (
            f"Unrecognized native fixture annotation: {path.name}"
        )
        names.extend(found)
    assert names and len(set(names)) == len(names), "Empty or duplicate native fixture declarations"
    return set(names)

def scheduled():
    workflow = WORKFLOW.read_text(encoding="utf-8")
    blocks = re.findall(r"(?m)^\s*for fixture in \\\n([\s\S]*?)^\s*do\s*$", workflow)
    assert len(blocks) == 1, "Expected one isolated fixture loop"
    names = blocks[0].replace("\\", " ").split()
    assert names and len(set(names)) == len(names), "Empty or duplicate scheduled fixtures"
    assert all(re.fullmatch(r"native\w+", name) for name in names), "Unexpected fixture filter"
    return set(names)

if __name__ == "__main__":
    declared, actual = inventory(), scheduled()
    assert actual == declared, (
        f"Missing isolated fixtures: {sorted(declared - actual)}; "
        f"Unknown scheduled fixtures: {sorted(actual - declared)}"
    )
    print(f"Native fixture inventory: {len(declared)} declared, all individually scheduled.")
