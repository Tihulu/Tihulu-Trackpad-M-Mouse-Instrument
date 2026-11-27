import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from repo_index import normalized, semantic_windows, fuse_rankings, in_scope, tokens, prepare_search, search_prepared, lexical_ranking, diverse_results
from types import SimpleNamespace
from unittest.mock import patch
import rag_benchmark
import rag_matrix
import repo_index

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

    def test_scoped_indices_and_context_revision_guard(self):
        app = self.repo / "studio/mobile-android/src/main/java/Pad.kt"
        app.parent.mkdir(parents=True)
        app.write_text("// MIDI pad controller")
        (self.repo / "studio/Sources/NoSpeakerCore").mkdir()
        (self.repo / "studio/Sources/NoSpeakerCore/Engine.swift").write_text("// MIDI ownership")
        (self.repo / "README.md").write_text("# MIDI help")
        self.git("add", "studio/mobile-android", "studio/Sources/NoSpeakerCore", "README.md")
        self.git("commit", "-qm", "scopes")
        for scope, expected in (("engine", "studio/Sources/NoSpeakerCore/Engine.swift"),
                                ("app", "studio/mobile-android/src/main/java/Pad.kt"),
                                ("docs", "README.md")):
            index = self.root / (scope + ".json")
            built = self.cli("build", "--repo", self.repo, "--scope", scope, "--out", index)
            self.assertEqual(built.returncode, 0, built.stderr)
            doc = json.loads(index.read_text())
            self.assertEqual({row["path"] for row in doc["chunks"]}, {expected})
            self.assertEqual(doc["metadata"]["scope"], scope)
            result = self.cli("context", "--repo", self.repo, "--expect-ref", "HEAD",
                              "--index", index, "--query", "MIDI", "--max-bytes", "1024")
            self.assertEqual(result.returncode, 0, result.stderr)
            data = json.loads(result.stdout)
            self.assertTrue(data["source_verified"])
            self.assertIn(expected + ":1-1@", data["sources"][0]["citation"])
            self.assertLessEqual(len(result.stdout.strip().encode()), 1024)
            stale = self.cli("context", "--repo", self.repo, "--expect-ref", self.commit,
                             "--index", index, "--query", "MIDI")
            self.assertEqual(stale.returncode, 2)
            self.assertIn("differs from expected revision", stale.stderr)
            self.assertEqual(self.cli("search", "--index", index, "--query", "MIDI",
                                      "--hybrid").returncode, 2)

    def test_context_rejects_forged_source_and_insufficient_budget(self):
        self.build()
        document = json.loads(self.index.read_text())
        original = self.index.read_bytes()
        document["chunks"][0]["text"] = document["chunks"][0]["text"].replace("Sustain", "Forged")
        self.index.write_text(json.dumps(document))
        args = ("context", "--repo", self.repo, "--expect-ref", self.commit,
                "--index", self.index, "--query", "Sustain")
        failure = self.cli(*args)
        self.assertEqual(failure.returncode, 2)
        self.assertFalse(failure.stdout)
        self.assertIn("text/line mismatch", failure.stderr)
        self.index.write_bytes(original)
        self.assertEqual(self.cli(*args, "--max-bytes", "100").returncode, 2)
        missing = self.cli("context", "--repo", self.repo, "--expect-ref", self.commit,
                           "--index", self.index, "--query", "noresultzzzz")
        self.assertEqual(missing.returncode, 2)
        self.assertFalse(missing.stdout)
        self.assertIn("No complete retrieved source", missing.stderr)

    def test_legacy_scope_and_declared_scope_mismatch(self):
        self.build()
        doc = json.loads(self.index.read_text())
        del doc["metadata"]["scope"]
        self.index.write_text(json.dumps(doc))
        result = self.cli("search", "--index", self.index, "--query", "sustain")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["scope"], "all")
        doc["metadata"]["scope"] = "app"
        self.index.write_text(json.dumps(doc))
        result = self.cli("verify", "--repo", self.repo, "--index", self.index)
        self.assertEqual(result.returncode, 2)
        self.assertIn("Invalid source row", result.stderr)

    def test_incremental_embeddings_reuse_only_identical_verified_inputs(self):
        # Deterministic test double for cache mechanics only. Not model evidence.
        class Tokenizer:
            def encode(self, text, **kwargs):
                return text.split()
        class Model:
            tokenizer = Tokenizer()
            max_seq_length = 1024
            def __init__(self):
                self.inputs = []
            def encode(self, texts, **kwargs):
                self.inputs.extend(texts)
                return [[3.0, 4.0] for _ in texts]
        model = Model()
        identity = "a" * 64
        recipe = {"version": 1, "dimension": 2}
        args = SimpleNamespace(repo=self.repo, ref=self.commit, scope="all",
                               out=self.index, model_dir=self.root, reuse_index=None)
        with patch.object(repo_index, "model_for", return_value=(model, identity)), \
             patch.object(repo_index, "embedding_recipe", return_value=recipe), \
             patch.object(repo_index, "fingerprint", return_value=(self.root, identity)):
            first = repo_index.build(args)
            self.assertEqual(first["encoded_embeddings"], 2)
            self.assertEqual(first["reused_embeddings"], 0)
            original = self.index.read_bytes()
            relative = "studio/Sources/Router.swift"
            old = self.git("show", self.commit + ":" + relative).stdout
            (self.repo / relative).write_text(old.replace("Sustain ownership", "Updated ownership"))
            self.git("add", relative)
            self.git("commit", "-qm", "change first chunk only")
            args.ref = "HEAD"
            args.reuse_index = self.index
            args.out = self.root / "next.json"
            model.inputs.clear()
            updated = repo_index.build(args)
            self.assertEqual(updated["encoded_embeddings"], 1)
            self.assertEqual(updated["reused_embeddings"], 1)
            self.assertEqual(len(model.inputs), 1)
            self.assertIn("Updated ownership", model.inputs[0])
            self.assertEqual(self.index.read_bytes(), original)
            metadata, rows = repo_index.read_index(args.out)
            self.assertTrue(repo_index.verify_sources(self.repo, metadata, rows)["source_verified"])
            # Changed recipe and forged old source cannot produce a new index.
            args.out = self.root / "rejected.json"
            with patch.object(repo_index, "embedding_recipe", return_value={"version": 2, "dimension": 2}):
                with self.assertRaisesRegex(ValueError, "recipe differs"):
                    repo_index.build(args)
            forged = json.loads(original)
            forged["chunks"][0]["text"] = forged["chunks"][0]["text"].replace("Sustain", "Forged")
            self.index.write_text(json.dumps(forged))
            with self.assertRaisesRegex(ValueError, "text/line mismatch"):
                repo_index.build(args)
            self.assertFalse(args.out.exists())

    def test_benchmark_case_identity_and_rejection(self):
        fixture = self.root / "cases.json"
        case = {"id": "unique", "scope": "docs", "language": "en",
                "query": "offline guide", "expected_paths": ["README.md"]}
        fixture.write_text(json.dumps([case]))
        cases, digest = rag_benchmark.load_cases(fixture)
        self.assertEqual(cases, [case])
        self.assertEqual(len(digest), 64)
        fixture.write_text(json.dumps([case], indent=2))
        self.assertNotEqual(rag_benchmark.load_cases(fixture)[1], digest)
        for invalid in ([case, case], [dict(case, query=" ")],
                        [dict(case, expected_paths=["../README.md"])],
                        [dict(case, scope="engine")],
                        [dict(case, expected_paths=["README.md", "README.md"])]):
            fixture.write_text(json.dumps(invalid))
            with self.assertRaises(ValueError):
                rag_benchmark.load_cases(fixture)

    def test_reuse_matrix_rejects_mixed_revision_and_unrun_cells(self):
        identity = "a" * 64
        previous = self.root / "previous"
        previous.mkdir()
        manifest = {"schema": 1, "commit": self.commit, "model_sha256": identity,
                    "cells": [{"scope": scope, "mode": mode, "status": "MEASURED",
                               "model_sha256": None if mode == "lexical" else identity}
                              for scope in rag_matrix.SCOPES for mode in rag_matrix.MODES]}
        def save():
            (previous / "matrix.json").write_text(json.dumps(manifest))
        def index(path):
            scope = path.name.split("-")[0]
            return ({"commit": self.commit, "scope": scope, "mode": "semantic",
                     "model_sha256": identity}, [])
        save()
        with patch.object(repo_index, "read_index", side_effect=index):
            rag_matrix.validate_reuse_matrix(self.repo, previous, identity)
            manifest["cells"][1]["status"] = "NOT_RUN"
            save()
            with self.assertRaisesRegex(ValueError, "nine measured cells"):
                rag_matrix.validate_reuse_matrix(self.repo, previous, identity)
            manifest["cells"][1]["status"] = "MEASURED"
            manifest["cells"][1]["model_sha256"] = "b" * 64
            save()
            with self.assertRaisesRegex(ValueError, "cell model mismatch"):
                rag_matrix.validate_reuse_matrix(self.repo, previous, identity)
            manifest["cells"][1]["model_sha256"] = identity
            self.git("commit", "--allow-empty", "-qm", "new revision")
            manifest["commit"] = self.git("rev-parse", "HEAD").stdout.strip()
            save()
            with self.assertRaisesRegex(ValueError, "matrix/index identity mismatch"):
                rag_matrix.validate_reuse_matrix(self.repo, previous, identity)

    def test_cache_rejects_replaced_revision_and_conflicting_input_vectors(self):
        self.build()
        doc = json.loads(self.index.read_text())
        identity, recipe = "a" * 64, {"version": 1, "dimension": 2}
        doc["metadata"].update(mode="semantic", model_sha256=identity,
                               dimension=2, embedding_recipe=recipe)
        for row in doc["chunks"]:
            row["embedding"] = [0.6, 0.8]
        duplicate = dict(doc["chunks"][0])
        doc["chunks"].append(duplicate)
        self.index.write_text(json.dumps(doc))
        # Actual committed fixture, not a mocked source verification.
        self.assertEqual(len(repo_index.reuse_vectors(self.repo, self.index, "all",
                                                      identity, recipe, self.commit)), 2)
        self.git("commit", "--allow-empty", "-qm", "other valid revision")
        newer = self.git("rev-parse", "HEAD").stdout.strip()
        with self.assertRaisesRegex(ValueError, "commit differs"):
            repo_index.reuse_vectors(self.repo, self.index, "all", identity, recipe, newer)
        duplicate["embedding"] = [0.8, 0.6]
        self.index.write_text(json.dumps(doc))
        with self.assertRaisesRegex(ValueError, "Conflicting embeddings"):
            repo_index.reuse_vectors(self.repo, self.index, "all", identity, recipe, self.commit)

    def test_rank_profiles_compare_frozen_case_groups(self):
        path = self.repo / "README.md"
        path.write_text("# MIDI sustain\n")
        self.git("add", "README.md")
        self.git("commit", "-qm", "ranking fixture")
        rev = self.git("rev-parse", "HEAD").stdout.strip()
        index = self.root / "docs.json"
        repo_index.build(SimpleNamespace(repo=self.repo, ref=rev, scope="docs",
                                         out=index, model_dir=None))
        case = {"id": "dev", "scope": "docs", "language": "en",
                "query": "MIDI", "expected_paths": ["README.md"]}
        other = dict(case, id="eval", query="sustain")
        dataset = self.root / "ranking.json"
        dataset.write_text(json.dumps({"development": [case], "evaluation": [other]}))
        out = self.root / "ranking"
        out.mkdir()
        args = SimpleNamespace(k=8, max_per_file=3)
        result = rag_matrix.compare_lexical_profiles(self.repo, rev, index, "docs",
                                                     args, out, dataset)
        self.assertEqual(set(result), {"development", "evaluation"})
        self.assertNotEqual(result["development"]["legacy"]["cases_sha256"],
                            result["evaluation"]["legacy"]["cases_sha256"])
        for group in result.values():
            self.assertEqual(group["legacy"]["cases_sha256"], group["file-first"]["cases_sha256"])
            self.assertEqual(group["file-first"]["file_hit_rate"], 1)
            self.assertTrue((out / group["file-first"]["report"]).is_file())
        with self.assertRaises(ValueError):
            rag_benchmark.load_cases(dataset, "unknown")

    def test_matrix_pins_revision_and_reports_unrun_vector_cells(self):
        cases = []
        for scope, relative in (("engine","studio/Sources/NoSpeakerCore/Engine.swift"),
                                ("app","studio/Sources/NoSpeakerStudio/View.swift"),
                                ("docs","README.md")):
            target = self.repo / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text("MIDI sustain")
            cases.append({"id":scope,"scope":scope,"language":"en","query":"MIDI",
                          "expected_paths":[relative]})
            self.git("add", relative)
        self.git("commit", "-qm", "matrix fixture")
        revision = self.git("rev-parse", "HEAD").stdout.strip()
        fixture = self.root / "cases.json"
        fixture.write_text(json.dumps(cases))
        heldout = self.root / "heldout.json"
        heldout.write_text(json.dumps([dict(case, id="heldout-" + case["id"], query="sustain") for case in cases]))
        out = self.root / "matrix"
        args = SimpleNamespace(repo=self.repo, ref=revision, out_dir=out,
                               model_dir=None, k=8, max_per_file=3, heldout_cases=heldout)
        with patch.object(rag_benchmark, "CASES", fixture):
            report = rag_matrix.run(args)
            self.assertEqual(report["commit"], revision)
            self.assertEqual(len(report["cells"]), 9)
            self.assertEqual(sum(c["status"] == "MEASURED" for c in report["cells"]), 3)
            self.assertEqual(sum(c["status"] == "NOT_RUN" for c in report["cells"]), 6)
            for cell in report["cells"]:
                if cell["status"] == "MEASURED":
                    self.assertNotEqual(cell["cases_sha256"], cell["heldout"]["cases_sha256"])
                    self.assertEqual(cell["heldout"]["cases"], 1)
                    self.assertTrue((out / cell["heldout"]["report"]).is_file())
                else:
                    self.assertNotIn("heldout", cell)
            self.assertEqual(json.loads((out / "matrix.json").read_text()), report)
            self.assertEqual({path.name for path in out.glob("*-report.json")},
                             {scope + "-lexical" + suffix + "-report.json"
                              for scope in rag_matrix.SCOPES for suffix in ("", "-heldout")})
            with self.assertRaises(FileExistsError):
                rag_matrix.run(args)

    def test_prepared_lexical_session_reuses_verified_rows(self):
        self.build()
        args = SimpleNamespace(repo=self.repo, expect_ref=self.commit, index=self.index,
                               model_dir=None, hybrid=False, limit=5, query="sustain")
        prepared = prepare_search(args)
        first = search_prepared(prepared, args)
        args.query = "cleanup"
        second = search_prepared(prepared, args)
        self.assertTrue(first["source_verified"] and second["source_verified"])
        self.assertEqual(first["commit"], self.commit)
        self.assertTrue(second["results"])
        args.hybrid = True
        with self.assertRaisesRegex(ValueError, "genuine local"):
            search_prepared(prepared, args)

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

    def test_lexical_identifier_ranking_and_file_diversity(self):
        def row(path, start, text):
            return {"path":path,"blob":"a"*40,"start":start,"end":start,"text":text}
        target = row("docs/MAC_HARDWARE_ACCEPTANCE.md",1,"Verify hardware and Logic Pro.")
        noise = row("docs/overview.md",1,"MIDI " * 500 + "hardware")
        ranks = sorted(lexical_ranking([target, noise], "Mac hardware acceptance"),
                       key=lambda item: -item[0])
        self.assertEqual(ranks[0][1], target)
        self.assertIn("midi", tokens("TunedMIDIClip"))
        self.assertIn("clip", tokens("TunedMIDIClip"))
        other = row("docs/overview.md",2,"MIDI")
        ranked = [(5,noise),(4,noise),(3,other),(2,target)]
        self.assertEqual([r["path"] for _,r in diverse_results(ranked,3,1)],
                         ["docs/overview.md","docs/MAC_HARDWARE_ACCEPTANCE.md"])
        self.assertEqual(len(diverse_results(ranked,3,2)),3)

    def test_file_first_preserves_best_chunks_and_caps(self):
        def row(path, start):
            return {"path":path, "blob":"a"*40, "start":start, "end":start}
        a, a2, a3 = row("a.swift", 1), row("a.swift", 2), row("a.swift", 3)
        b, c = row("b.swift", 1), row("c.swift", 1)
        ranked = [(10,a), (9,a), (8,a2), (7,a3), (6,b), (5,c)]
        legacy = diverse_results(ranked, 3, 3)
        candidate = diverse_results(ranked, 3, 3, file_first=True)
        self.assertEqual([r["path"] for _,r in legacy], ["a.swift"] * 3)
        self.assertEqual(candidate, [(10,a), (6,b), (5,c)])
        self.assertEqual(diverse_results(ranked, 5, 2, file_first=True),
                         [(10,a), (6,b), (5,c), (8,a2)])
        self.assertEqual(diverse_results(ranked[:4], 8, 2, file_first=True),
                         [(10,a), (8,a2)])

    def test_rank_fusion_uses_ranks_and_deduplicates(self):
        a = {"path":"a.swift","blob":"a"*40,"start":1,"end":1}
        b = {"path":"b.swift","blob":"b"*40,"start":1,"end":1}
        c = {"path":"c.swift","blob":"c"*40,"start":1,"end":1}
        fused = fuse_rankings([(0.8,a),(0.7,b),(0.7,b),(0.6,c)],[(200,b),(100,c)])
        scores = {row["path"]:score for score,row in fused}
        self.assertGreater(scores["b.swift"], scores["a.swift"])
        self.assertAlmostEqual(scores["b.swift"], 1/62+1/61)
        self.assertTrue(in_scope("studio/mobile-ios/Pad.swift", "app"))
        browser = "studio/Sources/NoSpeakerMac/RemoteLoopbackPageServer.swift"
        self.assertTrue(in_scope(browser, "app"))
        self.assertTrue(in_scope(browser, "engine"))
        self.assertFalse(in_scope("studio/mobile-ios/Pad.swift", "engine"))
        self.assertIn("müzik", tokens("Müzik"))

    def test_invalid_embedding_norms_and_finite_values(self):
        self.assertEqual(normalized([3,4]),[0.6,0.8])
        for vector in ([], [0,0], [float("nan")], [float("inf")], [1e308,1e308]):
            with self.assertRaises(ValueError):
                normalized(vector)


if __name__ == "__main__":
    unittest.main()
