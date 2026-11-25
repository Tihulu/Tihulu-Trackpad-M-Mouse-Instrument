import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

TOOL = Path(__file__).resolve().with_name("repo_index.py")


class RepositoryIndexTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.repo = self.root / "repo"
        self.repo.mkdir()
        self.git("init", "-q")
        self.git("config", "user.email", "test@example.invalid")
        self.git("config", "user.name", "Index test")
        (self.repo / "studio" / "Sources").mkdir(parents=True)
        (self.repo / "studio" / "Sources" / "Router.swift").write_text(
            "// Sustain ownership and note cleanup\n" + "\n".join("// line " + str(i) for i in range(95)),
            encoding="utf-8")
        (self.repo / "studio" / "credentials.json").write_text('{"excluded":"secret fixture"}')
        (self.repo / "studio" / "linked.swift").symlink_to(self.root / "outside.swift")
        (self.root / "outside.swift").write_text("outside-only marker")
        self.git("add", ".")
        self.git("commit", "-qm", "fixture")
        self.commit = self.git("rev-parse", "HEAD").stdout.strip()
        (self.repo / "studio" / "Sources" / "Router.swift").write_text("dirty working tree marker")
        (self.repo / "studio" / "Sources" / "Untracked.swift").write_text("untracked marker")
        self.index = self.root / "index.json"

    def tearDown(self):
        self.tmp.cleanup()

    def git(self, *args):
        return subprocess.run(["git", "-C", str(self.repo), *args], check=True,
                              capture_output=True, text=True)

    def cli(self, *args):
        return subprocess.run([sys.executable, str(TOOL), *map(str, args)],
                              capture_output=True, text=True)

    def build(self):
        result = self.cli("build", "--repo", self.repo, "--ref", self.commit, "--out", self.index)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def test_commit_pinned_and_safe_scope(self):
        result = self.build()
        self.assertEqual(result["mode"], "lexical")
        self.assertEqual(result["commit"], self.commit)
        document = json.loads(self.index.read_text())
        rows = document["chunks"]
        self.assertEqual(len(rows), 2)
        self.assertEqual(rows[0]["start"], 1)
        self.assertEqual(rows[0]["end"], 80)
        self.assertEqual(rows[1]["start"], 71)
        self.assertEqual({r["path"] for r in rows}, {"studio/Sources/Router.swift"})
        self.assertIn("Sustain ownership", rows[0]["text"])
        self.assertNotIn("dirty working", self.index.read_text())
        self.assertNotIn("untracked", self.index.read_text())
        self.assertNotIn("outside-only", self.index.read_text())
        self.assertNotIn("secret fixture", self.index.read_text())

    def test_search_provenance_and_no_overwrite(self):
        self.build()
        original = self.index.read_bytes()
        again = self.cli("build", "--repo", self.repo, "--out", self.index)
        self.assertEqual(again.returncode, 2)
        self.assertEqual(original, self.index.read_bytes())
        query = self.cli("search", "--index", self.index, "--query", "sustain cleanup")
        self.assertEqual(query.returncode, 0, query.stderr)
        result = json.loads(query.stdout)
        self.assertEqual(result["commit"], self.commit)
        self.assertEqual(result["mode"], "lexical")
        self.assertEqual(result["results"][0]["path"], "studio/Sources/Router.swift")
        self.assertIn("blob", result["results"][0])
        self.assertEqual(result["results"][0]["start"], 1)

    def test_semantic_not_faked_and_query_limits(self):
        self.build()
        semantic = self.cli("search", "--index", self.index, "--query", "sustain",
                            "--model-dir", self.root)
        self.assertEqual(semantic.returncode, 2)
        self.assertIn("no embeddings", semantic.stderr)
        result = self.cli("search", "--index", self.index, "--query", "sustain", "--limit", "51")
        self.assertEqual(result.returncode, 2)


if __name__ == "__main__":
    unittest.main()
