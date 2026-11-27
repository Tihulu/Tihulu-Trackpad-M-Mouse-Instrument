#!/usr/bin/env python3
"""Repeatable revision-pinned local retrieval matrix; no model downloads."""
import argparse
import json
from pathlib import Path
import re
import subprocess
import sys
from types import SimpleNamespace
from collections import Counter

import rag_benchmark
import repo_index

SCOPES = ("engine", "app", "docs")
MODES = ("lexical", "semantic", "hybrid")


def validate_reuse_matrix(repo, previous, identity):
    """Require a completed, consistent local matrix before reading cache rows."""
    with (previous / "matrix.json").open("rb") as stream:
        data = stream.read(1048577)
    if len(data) > 1048576:
        raise ValueError("Reuse matrix exceeds size limit")
    manifest = json.loads(data)
    if not isinstance(manifest, dict) or manifest.get("schema") != 1:
        raise ValueError("Invalid reuse matrix manifest")
    commit = manifest.get("commit")
    cells = manifest.get("cells")
    if (not isinstance(commit, str)
            or not re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", commit)
            or manifest.get("model_sha256") != identity
            or not isinstance(cells, list) or len(cells) != 9):
        raise ValueError("Reuse matrix identity mismatch")
    expected = {(scope, mode) for scope in SCOPES for mode in MODES}
    for cell in cells:
        if not isinstance(cell, dict):
            raise ValueError("Invalid reuse matrix cell")
        key = (cell.get("scope"), cell.get("mode"))
        if key not in expected or cell.get("status") not in ("MEASURED", "COVERAGE_FAIL"):
            raise ValueError("Reuse matrix requires nine measured cells")
        expected.remove(key)
        if cell.get("model_sha256") != (None if key[1] == "lexical" else identity):
            raise ValueError("Reuse matrix cell model mismatch")
    if repo_index.git(repo, "rev-parse", "--verify", "--end-of-options",
                      commit + "^{commit}").decode().strip() != commit:
        raise ValueError("Reuse matrix commit mismatch")
    for scope in SCOPES:
        meta, _ = repo_index.read_index(previous / (scope + "-semantic.json"))
        if (meta["commit"] != commit or meta.get("scope") != scope
                or meta["mode"] != "semantic" or meta["model_sha256"] != identity):
            raise ValueError("Reuse matrix/index identity mismatch: " + scope)
    # build() still checks the embedding recipe, source rows and vector norms.
    # This is consistency checking, not authentication of untrusted vectors.
    return commit


def compare_lexical_profiles(repo, revision, index, scope, args, out, cases_file,
                             candidate="file-first", prefix="", compare_cache=True,
                             baseline="legacy", expected_digests=None):
    """Same corpus/cutoff for paired, explicitly separate development/evaluation."""
    if baseline == candidate or any(p not in repo_index.LEXICAL_PROFILES for p in (baseline, candidate)):
        raise ValueError("Invalid comparison profiles")
    actual_digests = rag_benchmark.validate_case_groups(cases_file)
    if expected_digests is not None and actual_digests != expected_digests:
        raise ValueError("Matrix-wide ranking dataset changed")
    expected_digests = actual_digests
    comparison = {}
    for group in ("development", "evaluation"):
        comparison[group] = {}
        for profile in (baseline, candidate):
            report = rag_benchmark.run(SimpleNamespace(repo=repo, expect_ref=revision,
                index=index, scope=scope, mode="lexical", k=args.k,
                max_per_file=args.max_per_file, model_dir=None, cases_file=cases_file,
                case_group=group, lexical_profile=profile,
                compare_cache=compare_cache and group == "development" and profile == "legacy",
                diagnose_development=group == "development"))
            if (report["commit"] != revision or report["scope"] != scope
                    or report["mode"] != "lexical" or not report["source_verified"]
                    or report["model_sha256"] is not None
                    or report["lexical_profile"] != profile or report["case_group"] != group
                    or report["cases_sha256"] != expected_digests[group]):
                raise ValueError("Ranking comparison identity mismatch")
            name = scope + "-lexical-" + prefix + group + "-" + profile + "-report.json"
            with (out / name).open("x", encoding="utf-8") as stream:
                json.dump(report, stream, ensure_ascii=True, allow_nan=False)
            comparison[group][profile] = {key: report[key] for key in
                ("cases", "cases_sha256", "file_hit_rate", "file_mrr",
                 "missing_paths", "median_query_ms")}
            comparison[group][profile]["report"] = name
            if group == "development":
                diagnostics = [row["development_diagnostic"] for row in report["results"]]
                comparison[group][profile]["development_diagnostics"] = {
                    "statuses": dict(sorted(Counter(row["status"] for row in diagnostics).items())),
                    "expected_files": sum(row["expected_files"] for row in diagnostics),
                    "expected_returned": sum(row["expected_returned"] for row in diagnostics),
                    "returned_chunks": sum(row["returned_chunks"] for row in diagnostics),
                    "returned_unique_files": sum(row["returned_unique_files"] for row in diagnostics)}
            if group == "development" and profile == "legacy":
                if compare_cache:
                    comparison[group][profile]["cache_comparison"] = report["cache_comparison"]
                comparison[group][profile]["development_ranks"] = [
                    {"id": row["id"], "language": row["language"],
                     "first_file_rank": row["first_file_rank"]} for row in report["results"]]
        if (comparison[group][baseline]["cases_sha256"]
                != comparison[group][candidate]["cases_sha256"]):
            raise ValueError("Ranking comparison dataset changed")
    if (comparison["development"][baseline]["cases_sha256"]
            == comparison["evaluation"][baseline]["cases_sha256"]):
        raise ValueError("Development and evaluation datasets must differ")
    return comparison


def run(args):
    if not 1 <= args.k <= 50 or not 1 <= args.max_per_file <= 50:
        raise ValueError("Invalid ranking limits")
    repo = Path(args.repo).resolve(strict=True)
    revision = repo_index.git(repo, "rev-parse", "--verify", "--end-of-options",
                              args.ref + "^{commit}").decode().strip()
    if not re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", revision):
        raise ValueError("Invalid resolved revision")
    identity = repo_index.fingerprint(args.model_dir)[1] if args.model_dir else None
    reuse_dir = getattr(args, "reuse_dir", None)
    if reuse_dir and identity is None:
        raise ValueError("--reuse-dir requires an explicit local embedding model")
    previous = Path(reuse_dir).resolve(strict=True) if reuse_dir else None
    previous_commit = validate_reuse_matrix(repo, previous, identity) if previous else None
    heldout_cases = getattr(args, "heldout_cases", None)
    ranking_cases = getattr(args, "ranking_cases", None)
    multilingual_cases = getattr(args, "multilingual_cases", None)
    contextual_cases = getattr(args, "contextual_cases", None)
    domain_cases = getattr(args, "domain_cases", None)
    # Freeze all input digests before building any scope; pairwise checks alone
    # cannot detect a replaced fixture between otherwise consistent scopes.
    curated_digest = rag_benchmark.load_cases(rag_benchmark.CASES)[1]
    heldout_digest = rag_benchmark.load_cases(heldout_cases)[1] if heldout_cases else None
    ranking_digests = rag_benchmark.validate_case_groups(ranking_cases) if ranking_cases else None
    multilingual_digests = rag_benchmark.validate_case_groups(multilingual_cases) if multilingual_cases else None
    contextual_digests = rag_benchmark.validate_case_groups(contextual_cases) if contextual_cases else None
    domain_digests = rag_benchmark.validate_case_groups(domain_cases) if domain_cases else None
    out = Path(args.out_dir).resolve()
    # A matrix contains source text and possibly vectors. Never overwrite
    # previous evidence or create a public/shared directory by default.
    out.mkdir(mode=0o700, parents=False, exist_ok=False)
    cells = []
    for scope in SCOPES:
        built = {}
        for mode in MODES:
            if mode != "lexical" and identity is None:
                cells.append({"scope": scope, "mode": mode, "status": "NOT_RUN",
                              "reason": "No explicit trusted local embedding model"})
                continue
            family = "lexical" if mode == "lexical" else "semantic"
            if family not in built:
                index = out / (scope + "-" + family + ".json")
                info = repo_index.build(SimpleNamespace(repo=repo, ref=revision,
                    scope=scope, out=index,
                    model_dir=args.model_dir if family == "semantic" else None,
                    reuse_index=(previous / (scope + "-semantic.json"))
                    if previous and family == "semantic" else None,
                    reuse_expected_commit=previous_commit if family == "semantic" else None))
                if info["commit"] != revision or info["mode"] != family:
                    raise ValueError("Build identity mismatch")
                built[family] = (index, info)
            index, info = built[family]
            report = rag_benchmark.run(SimpleNamespace(repo=repo, expect_ref=revision,
                index=index, scope=scope, mode=mode, k=args.k,
                max_per_file=args.max_per_file,
                model_dir=args.model_dir if mode != "lexical" else None))
            if (report["commit"] != revision or report["scope"] != scope
                    or report["mode"] != mode or not report["source_verified"]
                    or report["cases_sha256"] != curated_digest
                    or report["model_sha256"] != (identity if mode != "lexical" else None)):
                raise ValueError("Benchmark identity mismatch")
            name = scope + "-" + mode + "-report.json"
            with (out / name).open("x", encoding="utf-8") as stream:
                json.dump(report, stream, ensure_ascii=True, allow_nan=False)
            cell = {"scope": scope, "mode": mode,
                          "status": "COVERAGE_FAIL" if report["missing_paths"] else "MEASURED",
                          "chunks": info["chunks"], "skipped": info["skipped"],
                          "reused_embeddings": info["reused_embeddings"],
                          "encoded_embeddings": info["encoded_embeddings"],
                          "cases": report["cases"], "file_hit_rate": report["file_hit_rate"],
                          "file_mrr": report["file_mrr"], "missing_paths": report["missing_paths"],
                          "median_query_ms": report["median_query_ms"],
                          "model_sha256": report["model_sha256"], "report": name,
                          "cases_sha256": report["cases_sha256"]}
            if heldout_cases:
                heldout = rag_benchmark.run(SimpleNamespace(repo=repo, expect_ref=revision,
                    index=index, scope=scope, mode=mode, k=args.k,
                    max_per_file=args.max_per_file, cases_file=heldout_cases,
                    model_dir=args.model_dir if mode != "lexical" else None))
                if (heldout["cases_sha256"] != heldout_digest or any(heldout[key] != report[key] for key in
                       ("commit", "scope", "mode", "source_verified", "model_sha256"))):
                    raise ValueError("Held-out benchmark identity mismatch")
                heldout_name = scope + "-" + mode + "-heldout-report.json"
                with (out / heldout_name).open("x", encoding="utf-8") as stream:
                    json.dump(heldout, stream, ensure_ascii=True, allow_nan=False)
                cell["heldout"] = {key: heldout[key] for key in
                    ("cases", "cases_sha256", "file_hit_rate", "file_mrr",
                     "missing_paths", "median_query_ms")}
                cell["heldout"]["report"] = heldout_name
                if heldout["missing_paths"]:
                    cell["status"] = "COVERAGE_FAIL"
            if ranking_cases and mode == "lexical":
                cell["ranking_comparison"] = compare_lexical_profiles(
                    repo, revision, index, scope, args, out, ranking_cases,
                    expected_digests=ranking_digests)
                if any(result["missing_paths"] for group in cell["ranking_comparison"].values()
                       for result in group.values()):
                    cell["status"] = "COVERAGE_FAIL"
            if multilingual_cases and mode == "lexical":
                cell["multilingual_comparison"] = compare_lexical_profiles(
                    repo, revision, index, scope, args, out, multilingual_cases,
                    candidate="multilingual", prefix="multilingual-", compare_cache=False,
                    expected_digests=multilingual_digests)
                if any(result["missing_paths"] for group in cell["multilingual_comparison"].values()
                       for result in group.values()):
                    cell["status"] = "COVERAGE_FAIL"
            if contextual_cases and mode == "lexical":
                cell["contextual_comparison"] = compare_lexical_profiles(
                    repo, revision, index, scope, args, out, contextual_cases,
                    baseline="multilingual", candidate="multilingual-context",
                    prefix="contextual-", compare_cache=False,
                    expected_digests=contextual_digests)
                if any(result["missing_paths"] for group in cell["contextual_comparison"].values()
                       for result in group.values()):
                    cell["status"] = "COVERAGE_FAIL"
            if domain_cases and mode == "lexical":
                cell["domain_comparison"] = compare_lexical_profiles(
                    repo, revision, index, scope, args, out, domain_cases,
                    baseline="multilingual-context", candidate="multilingual-domain",
                    prefix="domain-", compare_cache=False,
                    expected_digests=domain_digests)
                if any(result["missing_paths"] for group in cell["domain_comparison"].values()
                       for result in group.values()):
                    cell["status"] = "COVERAGE_FAIL"
            cells.append(cell)
    if identity and repo_index.fingerprint(args.model_dir)[1] != identity:
        raise ValueError("Model changed during matrix")
    summary = {"schema": 1, "commit": revision, "k_chunks": args.k,
               "max_per_file": args.max_per_file, "model_sha256": identity,
               "notice": "Measured means retrieval ran, not a quality or hardware pass. NOT_RUN is not success.",
               "cells": cells}
    # Only a completed matrix gets a summary. Failed partial directories
    # must not be interpreted as successful snapshots.
    with (out / "matrix.json").open("x", encoding="utf-8") as stream:
        json.dump(summary, stream, ensure_ascii=True, allow_nan=False)
    return summary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", default=".")
    parser.add_argument("--ref", default="HEAD")
    parser.add_argument("--out-dir", required=True, help="New private directory, never overwritten")
    parser.add_argument("--model-dir", help="Explicit trusted local model; omitted means lexical only")
    parser.add_argument("--reuse-dir", help="Trusted completed local semantic matrix; fresh output still required")
    parser.add_argument("--k", type=int, default=8)
    parser.add_argument("--max-per-file", type=int, default=3)
    parser.add_argument("--curated-only", action="store_true", help="Reproduce the original nine-case benchmark only")
    args = parser.parse_args()
    args.heldout_cases = None if args.curated_only else rag_benchmark.HELDOUT_CASES
    args.ranking_cases = None if args.curated_only else rag_benchmark.RANKING_CASES
    args.multilingual_cases = None if args.curated_only else rag_benchmark.MULTILINGUAL_CASES
    args.contextual_cases = None if args.curated_only else rag_benchmark.CONTEXTUAL_CASES
    args.domain_cases = None if args.curated_only else rag_benchmark.DOMAIN_CASES
    try:
        result = run(args)
        print(json.dumps(result, ensure_ascii=True, allow_nan=False))
        return 2 if any(c["status"] == "COVERAGE_FAIL" for c in result["cells"]) else 0
    except (ValueError, OSError, KeyError, TypeError, OverflowError, subprocess.CalledProcessError) as exc:
        print("rag-matrix: " + str(exc), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
