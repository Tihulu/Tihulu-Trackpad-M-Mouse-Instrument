import json
import math
from collections import Counter
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
import rag_feature_probe
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
        self.assertEqual(result["development"]["legacy"]["cache_comparison"]["parity_cases"], 1)
        self.assertEqual(result["development"]["legacy"]["development_ranks"],
                         [{"id": "dev", "language": "en", "first_file_rank": 1}])
        self.assertNotIn("cache_comparison", result["evaluation"]["legacy"])
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

    def test_lexical_cache_preserves_verified_responses_and_reuses_tokens(self):
        self.build()
        args = SimpleNamespace(repo=self.repo, expect_ref=self.commit, index=self.index,
                               model_dir=None, hybrid=False, limit=5, query="sustain")
        prepared = prepare_search(args)
        cache = repo_index.prepare_lexical(prepared)
        self.assertIsNotNone(cache)
        self.assertEqual(cache.commit, self.commit)
        self.assertGreater(cache.entries, 0)
        self.assertGreater(cache.term_bytes, 0)
        for profile in ("legacy", "file-first"):
            args.lexical_profile = profile
            for query in ("sustain cleanup", "Router", "line 75", "absentkeyword"):
                args.query = query
                cold = search_prepared(prepared, args)
                with patch.object(repo_index, "tokens", wraps=repo_index.tokens) as calls:
                    warm = search_prepared(prepared, args, lexical_cache=cache)
                self.assertEqual(warm, cold)
                self.assertEqual(calls.call_count, 1)

    def test_lexical_cache_fails_closed_on_snapshot_changes_and_budget(self):
        self.build()
        args = SimpleNamespace(repo=self.repo, expect_ref=self.commit, index=self.index,
                               model_dir=None, hybrid=False, limit=5, query="sustain")
        prepared = prepare_search(args)
        meta, rows, verified, model, identity = prepared
        cache = repo_index.prepare_lexical(prepared)
        self.assertIsNone(repo_index.prepare_lexical(prepared, max_entries=1))
        self.assertIsNone(repo_index.prepare_lexical(prepared, max_term_bytes=1))
        with self.assertRaisesRegex(ValueError, "budget"):
            repo_index.prepare_lexical(prepared, max_entries=0)
        unverified = (meta, rows, False, model, identity)
        with self.assertRaisesRegex(ValueError, "verified lexical"):
            repo_index.prepare_lexical(unverified)
        with self.assertRaisesRegex(ValueError, "verified lexical"):
            search_prepared(unverified, args, lexical_cache=cache)
        for changed in (dict(meta, commit="f"*40), dict(meta, scope="docs")):
            with self.assertRaisesRegex(ValueError, "revision or scope"):
                search_prepared((changed, rows, verified, model, identity), args,
                                lexical_cache=cache)
        for altered in ([dict(rows[0], text="changed")] + rows[1:],
                        [dict(rows[0], blob="f"*40)] + rows[1:],
                        list(reversed(rows)), rows[:-1]):
            with self.assertRaisesRegex(ValueError, "snapshot differs"):
                search_prepared((meta, altered, verified, model, identity), args,
                                lexical_cache=cache)

    def test_lexical_refactor_preserves_reference_scoring(self):
        rows = [{"path":"docs/NoteRouter.md","blob":"a"*40,"start":1,"end":1,
                 "text":"note sustain sustain Müzik"},
                {"path":"docs/Other.md","blob":"b"*40,"start":1,"end":1,
                 "text":"note cleanup"},
                {"path":"docs/Sustain.md","blob":"c"*40,"start":1,"end":1,
                 "text":"Müzik"}]
        def reference(query):
            terms = set(tokens(query))
            stats = [(row, Counter(tokens(row["text"])),
                      set(tokens(Path(row["path"]).stem))) for row in rows]
            average = max(1, sum(sum(body.values()) for _, body, _ in stats)/len(rows))
            frequencies = Counter()
            for _, body, name in stats:
                frequencies.update(terms.intersection(body.keys() | name))
            expected = []
            for row, body, name in stats:
                score = 0.0
                for term in sorted(terms):
                    count = body[term]
                    weight = math.log1p((len(rows)-frequencies[term]+0.5) /
                                        (frequencies[term]+0.5))
                    denom = count + 1.2*(0.25+0.75*sum(body.values())/average)
                    score += weight*(count*2.2/denom+(1.5 if term in name else 0))
                if score > 0:
                    expected.append((score, row))
            return expected
        for query in ("note note sustain", "Müzik", "Router", "cleanup missing", "absent"):
            self.assertEqual(lexical_ranking(rows, query), reference(query))

    def test_multilingual_query_aliases_are_bounded_and_preserve_originals(self):
        weights = repo_index.query_weights("KALİBRASYON kalibrasyon Tiefenkamera camera", "multilingual")
        self.assertEqual(weights["camera"], 1.0)
        self.assertEqual(weights["calibration"], repo_index.QUERY_ALIAS_WEIGHT)
        self.assertEqual(weights["depth"], repo_index.QUERY_ALIAS_WEIGHT)
        self.assertEqual(weights["kalibrasyon"], 1.0)
        self.assertEqual(repo_index.query_weights("Tiefenkamera", "legacy"), {"tiefenkamera": 1.0})
        self.assertEqual(repo_index.query_weights("unlisted", "multilingual"), {"unlisted": 1.0})
        with patch.object(repo_index, "QUERY_ALIASES", {"test": tuple("alias" + str(i) for i in range(100))}):
            expanded = repo_index.query_weights("test", "multilingual")
            self.assertEqual(len(expanded), 1 + repo_index.MAX_QUERY_ALIASES)
            self.assertEqual(expanded["test"], 1.0)
        for query in ("", "!?"):
            with self.assertRaisesRegex(ValueError, "No searchable"):
                repo_index.query_weights(query, "multilingual")
        with self.assertRaisesRegex(ValueError, "Invalid lexical"):
            repo_index.query_weights("test", "unknown")

    def test_multilingual_profile_search_cache_and_scope_parity(self):
        self.build()
        args = SimpleNamespace(repo=self.repo, expect_ref=self.commit, index=self.index,
                               model_dir=None, hybrid=False, limit=5,
                               query="nota temizlik", lexical_profile="multilingual")
        prepared = prepare_search(args)
        cache = repo_index.prepare_lexical(prepared)
        self.assertIsNotNone(cache)
        expanded = search_prepared(prepared, args)
        self.assertTrue(expanded["results"])
        self.assertEqual(expanded["lexical_profile"], "multilingual")
        self.assertTrue(expanded["source_verified"])
        self.assertEqual(search_prepared(prepared, args, lexical_cache=cache), expanded)
        args.lexical_profile = "legacy"
        self.assertEqual(search_prepared(prepared, args)["results"], [])
        result = self.cli("context", "--repo", self.repo, "--expect-ref", self.commit,
                          "--index", self.index, "--query", "nota temizlik",
                          "--lexical-profile", "multilingual")
        self.assertEqual(result.returncode, 0, result.stderr)
        context = json.loads(result.stdout)
        self.assertTrue(context["sources"])
        self.assertEqual(context["lexical_profile"], "multilingual")

    def test_multilingual_matrix_preserves_separate_case_groups(self):
        path = self.repo / "README.md"
        path.write_text("# Camera depth calibration profile")
        self.git("add", "README.md")
        self.git("commit", "-qm", "multilingual fixture")
        rev = self.git("rev-parse", "HEAD").stdout.strip()
        index = self.root / "docs-index.json"
        repo_index.build(SimpleNamespace(repo=self.repo, ref=rev, scope="docs",
                                         out=index, model_dir=None))
        case = {"id": "de", "scope": "docs", "language": "de",
                "query": "Tiefenkamera", "expected_paths": ["README.md"]}
        dataset = self.root / "multilingual.json"
        dataset.write_text(json.dumps({"development": [case], "evaluation": [
            dict(case, id="tr", language="tr", query="kalibrasyon")]}))
        out = self.root / "multilingual"
        out.mkdir()
        comparison = rag_matrix.compare_lexical_profiles(self.repo, rev, index, "docs",
            SimpleNamespace(k=8, max_per_file=3), out, dataset,
            candidate="multilingual", prefix="multilingual-", compare_cache=False)
        for group in comparison.values():
            self.assertEqual(group["legacy"]["file_hit_rate"], 0)
            self.assertEqual(group["multilingual"]["file_hit_rate"], 1)
            self.assertEqual(group["legacy"]["cases_sha256"],
                             group["multilingual"]["cases_sha256"])
            self.assertNotIn("cache_comparison", group["legacy"])
        self.assertNotEqual(comparison["development"]["legacy"]["cases_sha256"],
                            comparison["evaluation"]["legacy"]["cases_sha256"])

    def test_contextual_aliases_require_phrase_and_preserve_prior_profile(self):
        old = repo_index.query_weights("geri", "multilingual")
        self.assertIn("feedback", old)
        for query in ("geri", "geri dönüş", "geri yükleme", "geri başka bildirim",
                      "bildirimi", "yeniden", "çubuk"):
            weights = repo_index.query_weights(query, "multilingual-context")
            self.assertNotIn("feedback", weights, query)
            self.assertNotIn("retry", weights, query)
            self.assertNotIn("bar", weights, query)
        for query, alias in (("GERİ BİLDİRİM", "feedback"), ("geri bildirimi", "feedback"),
                             ("geri yükleme", "restore"), ("geri dönüş", "return"),
                             ("yeniden deneme", "retry"), ("yeniden başlatma", "restart"),
                             ("dokunmatik çubuk", "bar"), ("letzte Zustellung", "delivered")):
            self.assertEqual(repo_index.query_weights(query, "multilingual-context")[alias],
                             repo_index.QUERY_ALIAS_WEIGHT, query)
        self.assertEqual(repo_index.query_weights("geri bildirim feedback",
                            "multilingual-context")["feedback"], 1.0)
        self.assertEqual(repo_index.query_weights("kalibrasyon", "multilingual-context"),
                         repo_index.query_weights("kalibrasyon", "multilingual"))

    def test_case_group_leakage_and_changed_snapshot_are_rejected(self):
        case = {"id": "dev", "scope": "docs", "language": "en", "query": "MIDI sustain",
                "expected_paths": ["README.md"]}
        dataset = self.root / "groups.json"
        def write(dev, evaluation):
            dataset.write_text(json.dumps({"development": dev, "evaluation": evaluation}))
        for other in (dict(case, id="eval", query="  ＭＩＤＩ   SUSTAIN "),
                      dict(case, query="different")):
            write([case], [other])
            with self.assertRaisesRegex(ValueError, "case overlap"):
                rag_benchmark.validate_case_groups(dataset)
        write([case, dict(case, id="duplicate", query="midi SUSTAIN")],
              [dict(case, id="eval", query="other")])
        with self.assertRaisesRegex(ValueError, "Duplicate normalized query"):
            rag_benchmark.validate_case_groups(dataset)
        write([case], [dict(case, id="eval", query="other")])
        digests = rag_benchmark.validate_case_groups(dataset)
        self.assertNotEqual(digests["development"], digests["evaluation"])
        fake_report = {"commit": self.commit, "scope": "docs", "mode": "lexical",
                       "source_verified": True, "model_sha256": None,
                       "lexical_profile": "legacy", "case_group": "development",
                       "cases_sha256": "0"*64}
        with patch.object(rag_benchmark, "run", return_value=fake_report):
            with self.assertRaisesRegex(ValueError, "identity mismatch"):
                rag_matrix.compare_lexical_profiles(self.repo, self.commit, self.index, "docs",
                    SimpleNamespace(k=8, max_per_file=3), self.root, dataset)
        self.assertFalse(list(self.root.glob("*-report.json")))

    def test_contextual_rankings_differ_only_for_ambiguous_expansion(self):
        rows = [{"path":"docs/Receiver.md", "blob":"a"*40, "start":1,"end":1,
                 "text":"feedback confirmed"},
                {"path":"docs/Restore.md", "blob":"b"*40, "start":1,"end":1,
                 "text":"restore previous setting"}]
        legacy = lexical_ranking(rows, "geri yükleme", profile="multilingual")
        contextual = lexical_ranking(rows, "geri yükleme", profile="multilingual-context")
        self.assertEqual([row["path"] for _, row in legacy], ["docs/Receiver.md"])
        self.assertEqual([row["path"] for _, row in contextual], ["docs/Restore.md"])
        self.assertEqual(lexical_ranking(rows, "feedback", profile="multilingual"),
                         lexical_ranking(rows, "feedback", profile="multilingual-context"))
        self.assertEqual(lexical_ranking(rows, "geri", profile="legacy"), [])
        self.assertEqual(lexical_ranking(rows, "geri", profile="multilingual-context"), [])

    def test_feature_probe_pins_source_and_reports_missing_feature(self):
        engine = self.repo / "studio/Sources/NoSpeakerCore/RelativeProbe.swift"
        engine.parent.mkdir(parents=True)
        engine.write_text("// reference watermark")
        doc = self.repo / "docs/RELATIVE_PROBE.md"
        doc.parent.mkdir()
        doc.write_text("# reference evidence")
        (self.repo / "README.md").write_text("# general help")
        self.git("add", str(engine.relative_to(self.repo)), str(doc.relative_to(self.repo)), "README.md")
        self.git("commit", "-qm", "feature fixture")
        feature = self.git("rev-parse", "HEAD").stdout.strip()
        cases = [{"id": "engine", "scope": "engine", "language": "en", "query": "watermark",
                  "expected_paths": [str(engine.relative_to(self.repo))]},
                 {"id": "docs", "scope": "docs", "language": "en", "query": "reference evidence",
                  "expected_paths": [str(doc.relative_to(self.repo))]}]
        cases_file = self.root / "feature.json"
        cases_file.write_text(json.dumps(cases))
        self.git("rm", str(doc.relative_to(self.repo)))
        self.git("commit", "-qm", "later tree without feature documentation")
        later = self.git("rev-parse", "HEAD").stdout.strip()
        engine.write_text("// dirty working copy")
        args = SimpleNamespace(repo=self.repo, ref=feature, cases_file=cases_file,
                               out_dir=self.root / "feature-old", lexical_profile="legacy",
                               k=8, max_per_file=3)
        result = rag_feature_probe.run(args)
        self.assertEqual(result["commit"], feature)
        self.assertEqual({cell["scope"] for cell in result["scopes"]}, {"engine", "docs"})
        self.assertTrue(all(cell["status"] == "MEASURED" and cell["file_hit_rate"] == 1
                            for cell in result["scopes"]))
        self.assertNotIn("dirty working copy", (args.out_dir / "engine-lexical.json").read_text())
        with self.assertRaises(FileExistsError):
            rag_feature_probe.run(args)
        args.ref = later
        args.out_dir = self.root / "feature-new"
        result = rag_feature_probe.run(args)
        self.assertEqual(result["commit"], later)
        docs = next(cell for cell in result["scopes"] if cell["scope"] == "docs")
        self.assertEqual(docs["status"], "COVERAGE_FAIL")
        self.assertEqual(docs["missing_paths"], 1)
        self.assertEqual(docs["missing_expected_files"], [str(doc.relative_to(self.repo))])
        self.assertTrue(docs["canonical_lexical_complete"])
        self.assertEqual(docs["file_hit_rate"], 0)
        result = subprocess.run([sys.executable, str(TOOL.with_name("rag_feature_probe.py")),
            "--repo", str(self.repo), "--ref", later, "--cases-file", str(cases_file),
            "--out-dir", str(self.root / "feature-cli")], capture_output=True, text=True)
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertEqual(json.loads(result.stdout)["commit"], later)

    def test_feature_probe_rejects_symbolic_ref_and_dataset_change(self):
        (self.repo / "README.md").write_text("# feature")
        self.git("add", "README.md")
        self.git("commit", "-qm", "probe source")
        revision = self.git("rev-parse", "HEAD").stdout.strip()
        cases_file = self.root / "feature.json"
        cases_file.write_text(json.dumps([{"id": "docs", "scope": "docs", "language": "en",
            "query": "feature", "expected_paths": ["README.md"]}]))
        args = SimpleNamespace(repo=self.repo, ref="HEAD", cases_file=cases_file,
            out_dir=self.root / "feature-probe", lexical_profile="legacy", k=8, max_per_file=3)
        with self.assertRaisesRegex(ValueError, "full commit SHA"):
            rag_feature_probe.run(args)
        self.assertFalse(args.out_dir.exists())
        args.ref = revision
        actual_run = rag_benchmark.run
        def wrong_digest(options):
            report = actual_run(options)
            report["cases_sha256"] = "0" * 64
            return report
        with patch.object(rag_benchmark, "run", side_effect=wrong_digest):
            with self.assertRaisesRegex(ValueError, "report identity mismatch"):
                rag_feature_probe.run(args)
        self.assertFalse((args.out_dir / "feature-probe.json").exists())

    def test_relative_reference_development_fixture_stays_out_of_index(self):
        fixture = TOOL.with_name("rag_relative_reference_development_cases.json")
        cases, digest = rag_benchmark.load_cases(fixture)
        self.assertEqual(len(cases), 9)
        self.assertEqual(len(digest), 64)
        self.assertEqual(Counter(case["scope"] for case in cases),
                         {"engine": 3, "app": 3, "docs": 3})
        for scope in ("engine", "app", "docs"):
            self.assertFalse(in_scope("tools/" + fixture.name, scope))

    def test_canonical_lexical_coverage_detects_missing_duplicate_and_skip_claims(self):
        self.build()
        original = json.loads(self.index.read_text())
        def check(document, message):
            self.index.write_text(json.dumps(document))
            normal = self.cli("verify", "--repo", self.repo, "--index", self.index)
            self.assertEqual(normal.returncode, 0, normal.stderr)
            strict = self.cli("verify", "--repo", self.repo, "--index", self.index,
                              "--require-complete-lexical")
            self.assertEqual(strict.returncode, 2)
            self.assertIn(message, strict.stderr)
        strict = self.cli("verify", "--repo", self.repo, "--index", self.index,
                          "--require-complete-lexical")
        self.assertEqual(strict.returncode, 0, strict.stderr)
        self.assertTrue(json.loads(strict.stdout)["canonical_lexical_complete"])
        self.assertEqual(json.loads(strict.stdout)["canonical_chunks"], 2)
        check(dict(original, chunks=original["chunks"][:1]), "missing=1")
        check(dict(original, chunks=original["chunks"] + original["chunks"][:1]), "unexpected=1")
        check(dict(original, metadata=dict(original["metadata"], skipped=[{"path": "invented"}])),
              "skip_inventory_matches=False")
        meta, rows = original["metadata"], original["chunks"]
        self.assertTrue(repo_index.verify_complete_lexical(self.repo, meta, list(reversed(rows)))
                        ["canonical_lexical_complete"])
        with self.assertRaisesRegex(ValueError, "requires a lexical"):
            repo_index.verify_complete_lexical(self.repo, dict(meta, mode="semantic"), rows)

    def test_matrix_wide_digest_rejects_replaced_group_between_scopes(self):
        case = {"id": "dev", "scope": "docs", "language": "en", "query": "test one",
                "expected_paths": ["README.md"]}
        dataset = self.root / "groups.json"
        evaluation = dict(case, id="eval", query="test two")
        dataset.write_text(json.dumps({"development": [case], "evaluation": [evaluation]}))
        digests = rag_benchmark.validate_case_groups(dataset)
        dataset.write_text(json.dumps({"development": [dict(case, query="changed")],
                                       "evaluation": [evaluation]}))
        with patch.object(rag_benchmark, "run") as run:
            with self.assertRaisesRegex(ValueError, "Matrix-wide ranking dataset changed"):
                rag_matrix.compare_lexical_profiles(self.repo, self.commit, self.index,
                    "docs", SimpleNamespace(k=8, max_per_file=3), self.root, dataset,
                    expected_digests=digests)
            run.assert_not_called()

    def test_git_replacement_refs_cannot_relabel_committed_source(self):
        original = self.commit
        source = "studio/Sources/Router.swift"
        self.git("add", source)
        self.git("commit", "-qm", "replacement commit fixture")
        replacement = self.git("rev-parse", "HEAD").stdout.strip()
        self.git("replace", original, replacement)
        try:
            self.assertEqual(self.git("rev-parse", original + "^{commit}").stdout.strip(),
                             original)
            self.assertIn("dirty working tree marker", self.git("show", original + ":" + source).stdout)
            self.build()
            meta, rows = repo_index.read_index(self.index)
            self.assertEqual(meta["commit"], original)
            self.assertIn("Sustain ownership", rows[0]["text"])
            self.assertNotIn("dirty working tree marker", self.index.read_text())
            self.assertTrue(repo_index.verify_complete_lexical(self.repo, meta, rows)
                            ["canonical_lexical_complete"])
        finally:
            self.git("replace", "-d", original)
        old_blob = self.git("rev-parse", original + ":" + source).stdout.strip()
        new_blob = self.git("rev-parse", replacement + ":" + source).stdout.strip()
        self.git("replace", old_blob, new_blob)
        try:
            self.assertIn("dirty working tree marker", self.git("cat-file", "blob", old_blob).stdout)
            self.assertTrue(repo_index.verify_complete_lexical(self.repo, meta, rows)
                            ["canonical_lexical_complete"])
            forged = [{"path": source, "blob": old_blob, "start": 1, "end": 1,
                       "text": "dirty working tree marker"}]
            with self.assertRaisesRegex(ValueError, "text/line mismatch"):
                repo_index.verify_sources(self.repo, meta, forged)
            self.assertIn("Sustain ownership", repo_index.git(self.repo, "cat-file", "blob", old_blob).decode())
        finally:
            self.git("replace", "-d", old_blob)

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
