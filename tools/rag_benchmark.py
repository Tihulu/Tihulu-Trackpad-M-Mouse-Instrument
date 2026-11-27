#!/usr/bin/env python3
"""Local file-retrieval benchmark. No LLM answers or hardware access."""
import argparse
import json
from pathlib import Path
import statistics
import subprocess
import sys
import time
from types import SimpleNamespace
import repo_index

CASES = Path(__file__).with_name("rag_benchmark_cases.json")


def run(args):
    cases = json.loads(CASES.read_text(encoding="utf-8"))
    selected = [case for case in cases if case["scope"] == args.scope]
    if not selected or not 1 <= args.k <= 50 or not 1 <= args.max_per_file <= 50:
        raise ValueError("Invalid scope or rank limit")
    if (args.mode == "lexical") != (args.model_dir is None):
        raise ValueError("Semantic and hybrid require --model-dir; lexical does not")
    options = SimpleNamespace(repo=args.repo, expect_ref=args.expect_ref,
                              index=args.index, model_dir=args.model_dir,
                              hybrid=args.mode == "hybrid", limit=args.k, max_per_file=args.max_per_file, query="")
    started = time.monotonic()
    prepared = repo_index.prepare_search(options)
    setup_ms = round((time.monotonic() - started) * 1000, 2)
    meta, rows, verified, _, _ = prepared
    if not verified or meta.get("scope", "all") != args.scope:
        raise ValueError("Benchmark requires a verified index of the requested scope")
    indexed = {row["path"] for row in rows}
    results = []
    for case in selected:
        expected = set(case["expected_paths"])
        missing = sorted(expected - indexed)
        options.query = case["query"]
        started = time.monotonic()
        response = repo_index.search_prepared(prepared, options)
        elapsed_ms = round((time.monotonic() - started) * 1000, 2)
        # Count distinct files, not repeated chunks of one file. The
        # retrieval cutoff itself remains k chunks, as in the SDK.
        paths = list(dict.fromkeys(row["path"] for row in response["results"]))
        rank = next((i for i, path in enumerate(paths, 1) if path in expected), None)
        results.append({"id": case["id"], "language": case["language"],
                        "expected_paths": case["expected_paths"], "missing_paths": missing,
                        "returned_paths": paths, "first_file_rank": rank,
                        "query_ms": elapsed_ms})
    count = len(results)
    return {"schema": 1, "commit": meta["commit"], "scope": args.scope,
            "mode": args.mode, "model_sha256": meta["model_sha256"] if args.model_dir else None,
            "source_verified": True, "k_chunks": args.k, "max_per_file": args.max_per_file, "cases": count,
            "setup_ms": setup_ms, "median_query_ms": statistics.median(r["query_ms"] for r in results),
            "file_hit_rate": sum(r["first_file_rank"] is not None for r in results) / count,
            "file_mrr": sum(1 / r["first_file_rank"] if r["first_file_rank"] else 0 for r in results) / count,
            "missing_paths": sum(len(r["missing_paths"]) for r in results),
            "notice": "Small curated file-level retrieval benchmark; not answer correctness or hardware acceptance.",
            "results": results}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", required=True)
    parser.add_argument("--expect-ref", required=True)
    parser.add_argument("--index", required=True)
    parser.add_argument("--scope", choices=("engine", "app", "docs"), required=True)
    parser.add_argument("--mode", choices=("lexical", "semantic", "hybrid"), default="lexical")
    parser.add_argument("--model-dir")
    parser.add_argument("--k", type=int, default=8)
    parser.add_argument("--max-per-file", type=int, default=3)
    args = parser.parse_args()
    try:
        report = run(args)
        print(json.dumps(report, ensure_ascii=True, allow_nan=False))
        # Coverage is mandatory; retrieval quality is reported, not silently
        # converted into a hardware or semantic acceptance result.
        return 2 if report["missing_paths"] else 0
    except (ValueError, OSError, KeyError, TypeError, OverflowError, subprocess.CalledProcessError) as exc:
        print("rag-benchmark: " + str(exc), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
