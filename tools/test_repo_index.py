import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from repo_index import normalized, semantic_windows

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

    def test_verify_detects_forged_content_and_blob(self):
        self.build()
        verified = self.cli("verify", "--repo", self.repo, "--index", self.index)
        self.assertEqual(verified.returncode, 0, verified.stderr)
        self.assertTrue(json.loads(verified.stdout)["source_verified"])
        search = self.cli("search", "--index", self.index, "--repo", self.repo,
                          "--query", "sustain")
        self.assertEqual(search.returncode, 0, search.stderr)
        self.assertTrue(json.loads(search.stdout)["source_verified"])
        original = json.loads(self.index.read_text())
        document = json.loads(self.index.read_text())
        document["chunks"][0]["text"] = document["chunks"][0]["text"].replace("Sustain", "Forged")
        self.index.write_text(json.dumps(document))
        failure = self.cli("verify", "--repo", self.repo, "--index", self.index)
        self.assertEqual(failure.returncode, 2)
        self.assertIn("text/line mismatch", failure.stderr)
        original["chunks"][0]["blob"] = "0" * 40
        self.index.write_text(json.dumps(original))
        failure = self.cli("search", "--index", self.index, "--repo", self.repo,
                           "--query", "sustain")
        self.assertEqual(failure.returncode, 2)
        self.assertIn("path/blob mismatch", failure.stderr)

    def test_malformed_index_metadata_is_rejected(self):
        self.build()
        document = json.loads(self.index.read_text())
        document["chunks"][0]["start"] = True
        self.index.write_text(json.dumps(document))
        failure = self.cli("search", "--index", self.index, "--query", "sustain")
        self.assertEqual(failure.returncode, 2)
        self.assertIn("Invalid source row", failure.stderr)

    def test_semantic_not_faked_and_query_limits(self):
        self.build()
        semantic = self.cli("search", "--index", self.index, "--query", "sustain",
                            "--model-dir", self.root)
        self.assertEqual(semantic.returncode, 2)
        self.assertIn("no embeddings", semantic.stderr)
        result = self.cli("search", "--index", self.index, "--query", "sustain", "--limit", "51")
        self.assertEqual(result.returncode, 2)


class SemanticContractTests(unittest.TestCase):
    # Deterministic tokenizer fixture only. This does not test or pretend
    # to generate semantic vectors from a pretrained model.
    class Tokenizer:
        def encode(self, text, **kwargs):
            return text.split() + ["start", "end"]

    class Model:
        max_seq_length = 48
        tokenizer = None

    def test_semantic_windows_keep_exact_source_lines(self):
        model = self.Model()
        model.tokenizer = self.Tokenizer()
        lines = ["alpha beta gamma"] * 15 + [" ".join(["long"] * 50)] + ["last line"]
        row = {"path":"studio/Router.swift", "blob":"a"*40, "start":5,
               "end":5+len(lines)-1, "text":"\n".join(lines)}
        skipped = []
        rows = semantic_windows([row], model, skipped)
        self.assertGreater(len(rows), 1)
        self.assertEqual(skipped, [{"path":row["path"],"line":20,"reason":"model-context"}])
        for part in rows:
            self.assertEqual(part["text"], "\n".join(lines[part["start"]-5:part["end"]-4]))
            self.assertLessEqual(len(model.tokenizer.encode(part["path"]+"\n"+part["text"])),32)
        self.assertEqual(rows[-1]["end"],21)

    def test_invalid_embedding_norms_and_finite_values(self):
        self.assertEqual(normalized([3,4]),[0.6,0.8])
        for vector in ([], [0,0], [float("nan")], [float("inf")], [1e308,1e308]):
            with self.assertRaises(ValueError):
                normalized(vector)


if __name__ == "__main__":
    unittest.main()
