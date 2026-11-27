#!/usr/bin/env python3
"""Local development-only feature retrieval on one explicit Git commit."""
import argparse
import json
from pathlib import Path
import re
import subprocess
import sys
from types import SimpleNamespace

import rag_benchmark
import repo_index


def run(args):
    if (not isinstance(args.ref, str) or not re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", args.ref)
            or args.lexical_profile not in repo_index.LEXICAL_PROFILES
            or not 1 <= args.k <= 50 or not 1 <= args.max_per_file <= 50):
        raise ValueError("Feature probe requires a full commit SHA and valid lexical limits")
    repo = Path(args.repo).resolve(strict=True)
    revision = repo_index.git(repo, "rev-parse", "--verify", "--end-of-options",
                              args.ref + "^{commit}").decode().strip()
    if revision != args.ref:
        raise ValueError("Feature probe commit identity mismatch")
    cases_file = Path(args.cases_file).resolve(strict=True)
    cases, digest = rag_benchmark.load_cases(cases_file)
    scopes = sorted({case["scope"] for case in cases})
    out = Path(args.out_dir).resolve()
    out.mkdir(mode=0o700, parents=False, exist_ok=False)
    results = []
    for scope in scopes:
        selected = [case for case in cases if case["scope"] == scope]
        index = out / (scope + "-lexical.json")
        info = repo_index.build(SimpleNamespace(repo=repo, ref=revision, scope=scope,
                                                 out=index, model_dir=None))
        if info["commit"] != revision or info["scope"] != scope or info["mode"] != "lexical":
            raise ValueError("Feature probe build identity mismatch")
        meta, rows = repo_index.read_index(index)
        coverage = repo_index.verify_complete_lexical(repo, meta, rows)
        if coverage["commit"] != revision or coverage["scope"] != scope:
            raise ValueError("Feature probe canonical coverage identity mismatch")
        report = rag_benchmark.run(SimpleNamespace(repo=repo, expect_ref=revision,
            index=index, scope=scope, mode="lexical", model_dir=None,
            cases_file=cases_file, k=args.k, max_per_file=args.max_per_file,
            lexical_profile=args.lexical_profile))
        if (report["commit"] != revision or report["scope"] != scope
                or report["mode"] != "lexical" or report["model_sha256"] is not None
                or not report["source_verified"] or report["cases_sha256"] != digest
                or report["cases"] != len(selected) or report["case_group"] is not None
                or report["lexical_profile"] != args.lexical_profile
                or report["k_chunks"] != args.k or report["max_per_file"] != args.max_per_file):
            raise ValueError("Feature probe report identity mismatch")
        name = scope + "-feature-report.json"
        with (out / name).open("x", encoding="utf-8") as stream:
            json.dump(report, stream, ensure_ascii=True, allow_nan=False)
        results.append({"scope": scope,
                        "status": "COVERAGE_FAIL" if report["missing_paths"] else "MEASURED",
                        "canonical_lexical_complete": coverage["canonical_lexical_complete"],
                        "cases": report["cases"], "chunks": info["chunks"],
                        "skipped": info["skipped"], "missing_paths": report["missing_paths"],
                        "missing_expected_files": sorted({path for row in report["results"]
                                                          for path in row["missing_paths"]}),
                        "file_hit_rate": report["file_hit_rate"], "file_mrr": report["file_mrr"],
                        "median_query_ms": report["median_query_ms"], "report": name})
    summary = {"schema": 1, "commit": revision, "mode": "lexical",
               "lexical_profile": args.lexical_profile, "cases_sha256": digest,
               "k_chunks": args.k, "max_per_file": args.max_per_file,
               "notice": "Development-only file retrieval. No model, native, hardware or independent acceptance.",
               "scopes": results}
    # Never label a partial run a completed probe, or overwrite earlier evidence.
    with (out / "feature-probe.json").open("x", encoding="utf-8") as stream:
        json.dump(summary, stream, ensure_ascii=True, allow_nan=False)
    return summary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", required=True)
    parser.add_argument("--ref", required=True, help="Full existing local commit SHA; no branch aliases")
    parser.add_argument("--cases-file", required=True, help="Explicit development-only JSON case list")
    parser.add_argument("--out-dir", required=True, help="New private output directory")
    parser.add_argument("--lexical-profile", choices=repo_index.LEXICAL_PROFILES, default="legacy")
    parser.add_argument("--k", type=int, default=8)
    parser.add_argument("--max-per-file", type=int, default=3)
    args = parser.parse_args()
    try:
        report = run(args)
        print(json.dumps(report, ensure_ascii=True, allow_nan=False))
        return 2 if any(cell["status"] == "COVERAGE_FAIL" for cell in report["scopes"]) else 0
    except (ValueError, OSError, KeyError, TypeError, OverflowError, subprocess.CalledProcessError) as exc:
        print("rag-feature-probe: " + str(exc), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
