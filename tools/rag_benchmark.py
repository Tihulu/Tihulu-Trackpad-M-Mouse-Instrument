#!/usr/bin/env python3
"""Local file-retrieval benchmark. No LLM answers or hardware access."""
import argparse
import hashlib
import json
from pathlib import Path
import statistics
import subprocess
import sys
import time
import unicodedata
from types import SimpleNamespace
import repo_index

CASES = Path(__file__).with_name("rag_benchmark_cases.json")
HELDOUT_CASES = Path(__file__).with_name("rag_heldout_cases.json")
RANKING_CASES = Path(__file__).with_name("rag_ranking_cases.json")
MULTILINGUAL_CASES = Path(__file__).with_name("rag_multilingual_cases.json")
CONTEXTUAL_CASES = Path(__file__).with_name("rag_contextual_cases.json")
DOMAIN_CASES = Path(__file__).with_name("rag_domain_cases.json")


def load_cases(path, group=None):
    with Path(path).open("rb") as stream:
        data = stream.read(65537)
    if len(data) > 65536:
        raise ValueError("Case set exceeds size limit")
    cases = json.loads(data)
    if group is not None:
        if group not in ("development", "evaluation") or not isinstance(cases, dict):
            raise ValueError("Invalid ranking case group")
        cases = cases.get(group)
        # Fingerprint the selected group independently of the other group.
        data = json.dumps(cases, ensure_ascii=True, sort_keys=True,
                          separators=(",", ":"), allow_nan=False).encode("utf-8")
    if not isinstance(cases, list) or not 1 <= len(cases) <= 256:
        raise ValueError("Invalid case set size")
    seen = set()
    for case in cases:
        if not isinstance(case, dict):
            raise ValueError("Invalid benchmark case")
        identifier = case.get("id")
        scope = case.get("scope")
        query = case.get("query")
        language = case.get("language")
        paths = case.get("expected_paths")
        if (not isinstance(identifier, str) or not identifier or identifier in seen
                or scope not in ("engine", "app", "docs")
                or not isinstance(language, str) or not language
                or not isinstance(query, str) or not query.strip() or len(query) > 4096
                or not isinstance(paths, list) or not paths
                or any(not isinstance(p, str) or not repo_index.allowed(p)
                       or not repo_index.in_scope(p, scope) for p in paths)
                or len(set(paths)) != len(paths)):
            raise ValueError("Invalid or duplicate benchmark case")
        seen.add(identifier)
    return cases, hashlib.sha256(data).hexdigest()


def validate_case_groups(path):
    """Reject exact query/ID leakage even when different JSON yields different digests."""
    dev, dev_digest = load_cases(path, "development")
    evaluation, eval_digest = load_cases(path, "evaluation")
    def normalized_query(case):
        return " ".join(unicodedata.normalize("NFKC", case["query"]).casefold().split())
    for cases in (dev, evaluation):
        if len({normalized_query(case) for case in cases}) != len(cases):
            raise ValueError("Duplicate normalized query within benchmark group")
    if ({case["id"] for case in dev} & {case["id"] for case in evaluation}
            or {normalized_query(case) for case in dev} &
               {normalized_query(case) for case in evaluation}):
        raise ValueError("Development/evaluation case overlap")
    return {"development": dev_digest, "evaluation": eval_digest}


def diagnose_lexical(rows, query, expected, response, profile, limit, per_file, cache=None):
    """Explain development-only retrieval misses without changing ranking."""
    indexed = {row["path"] for row in rows}
    ranked = repo_index.lexical_ranking(rows, query, cache, profile=profile)
    ranked.sort(key=lambda item: (-item[0], item[1]["path"], item[1]["start"], item[1]["end"]))
    selected = repo_index.diverse_results(ranked, limit, per_file, file_first=profile == "file-first")
    # The diagnostic must describe the very same results, not a second ranking.
    def key(row):
        return (row["path"], row["blob"], row["start"], row["end"])
    if [(key(row), round(score, 6)) for score, row in selected] != [
            (key(row), row["score"]) for row in response["results"]]:
        raise ValueError("Development diagnostic ranking differs from response")
    positive = {row["path"] for _, row in ranked}
    returned = {row["path"] for row in response["results"]}
    missing = expected - indexed
    hit = expected & returned
    status = ("COVERAGE_FAIL" if missing else "HIT" if hit else
              "CUTOFF" if expected & positive else "NO_POSITIVE_MATCH")
    def first(paths):
        return next((i for i, path in enumerate(paths, 1) if path in expected), None)
    return {"status": status, "expected_files": len(expected),
            "expected_indexed": len(expected & indexed),
            "expected_positive": len(expected & positive),
            "expected_returned": len(hit),
            "positive_chunks": len(ranked), "positive_files": len(positive),
            "returned_chunks": len(selected), "returned_unique_files": len(returned),
            "raw_first_chunk_rank": first(row["path"] for _, row in ranked),
            "returned_first_chunk_rank": first(row["path"] for row in response["results"])}


def run(args):
    cases, cases_sha256 = load_cases(getattr(args, "cases_file", None) or CASES,
                                     getattr(args, "case_group", None))
    diagnose = getattr(args, "diagnose_development", False)
    if diagnose and (args.mode != "lexical" or getattr(args, "case_group", None) != "development"):
        raise ValueError("Diagnostics require lexical development cases only")
    selected = [case for case in cases if case["scope"] == args.scope]
    if not selected or not 1 <= args.k <= 50 or not 1 <= args.max_per_file <= 50:
        raise ValueError("Invalid scope or rank limit")
    if (args.mode == "lexical") != (args.model_dir is None):
        raise ValueError("Semantic and hybrid require --model-dir; lexical does not")
    options = SimpleNamespace(repo=args.repo, expect_ref=args.expect_ref,
                              index=args.index, model_dir=args.model_dir,
                              hybrid=args.mode == "hybrid", limit=args.k, max_per_file=args.max_per_file, query="",
                              lexical_profile=getattr(args, "lexical_profile", "legacy"))
    started = time.monotonic()
    prepared = repo_index.prepare_search(options)
    setup_ms = round((time.monotonic() - started) * 1000, 2)
    meta, rows, verified, _, _ = prepared
    if not verified or meta.get("scope", "all") != args.scope:
        raise ValueError("Benchmark requires a verified index of the requested scope")
    compare_cache = getattr(args, "compare_cache", False)
    cache = None
    cache_setup_ms = None
    if compare_cache:
        if args.mode != "lexical":
            raise ValueError("Cache comparison requires lexical mode")
        started = time.monotonic()
        cache = repo_index.prepare_lexical(prepared)
        cache_setup_ms = round((time.monotonic() - started) * 1000, 2)
    indexed = {row["path"] for row in rows}
    results = []
    for case in selected:
        expected = set(case["expected_paths"])
        missing = sorted(expected - indexed)
        options.query = case["query"]
        started = time.monotonic()
        response = repo_index.search_prepared(prepared, options)
        elapsed_ms = round((time.monotonic() - started) * 1000, 2)
        warm_ms = None
        if cache is not None:
            started = time.monotonic()
            warm_response = repo_index.search_prepared(prepared, options, lexical_cache=cache)
            warm_ms = round((time.monotonic() - started) * 1000, 2)
            if warm_response != response:
                raise ValueError("Prepared lexical ranking differs from uncached search: " + case["id"])
        if response["lexical_profile"] != (options.lexical_profile if args.mode == "lexical" else None):
            raise ValueError("Benchmark ranking profile mismatch")
        # Count distinct files, not repeated chunks of one file. The
        # retrieval cutoff itself remains k chunks, as in the SDK.
        paths = list(dict.fromkeys(row["path"] for row in response["results"]))
        rank = next((i for i, path in enumerate(paths, 1) if path in expected), None)
        results.append({"id": case["id"], "language": case["language"],
                        "expected_paths": case["expected_paths"], "missing_paths": missing,
                        "returned_paths": paths, "first_file_rank": rank,
                        "query_ms": elapsed_ms, **({"warm_query_ms": warm_ms} if compare_cache else {})})
        if diagnose:
            results[-1]["development_diagnostic"] = diagnose_lexical(
                rows, options.query, expected, response, options.lexical_profile,
                args.k, args.max_per_file, cache)
    count = len(results)
    report = {"schema": 1, "commit": meta["commit"], "scope": args.scope,
            "mode": args.mode, "model_sha256": meta["model_sha256"] if args.model_dir else None,
            "source_verified": True, "lexical_profile": options.lexical_profile if args.mode == "lexical" else None,
            "case_group": getattr(args, "case_group", None), "cases_sha256": cases_sha256, "k_chunks": args.k, "max_per_file": args.max_per_file, "cases": count,
            "setup_ms": setup_ms, "median_query_ms": statistics.median(r["query_ms"] for r in results),
            "file_hit_rate": sum(r["first_file_rank"] is not None for r in results) / count,
            "file_mrr": sum(1 / r["first_file_rank"] if r["first_file_rank"] else 0 for r in results) / count,
            "missing_paths": sum(len(r["missing_paths"]) for r in results),
            "notice": "Small curated file-level retrieval benchmark; not answer correctness or hardware acceptance.",
            "results": results}
    if compare_cache:
        report["cache_comparison"] = {
            "status": "MEASURED" if cache is not None else "BUDGET_FALLBACK",
            "setup_ms": cache_setup_ms, "entries": cache.entries if cache is not None else None,
            "term_bytes": cache.term_bytes if cache is not None else None,
            "parity_cases": count if cache is not None else 0,
            "warm_median_query_ms": statistics.median(r["warm_query_ms"] for r in results)
            if cache is not None else None,
            "notice": "Paired cold-then-warm process timings; setup excluded from query medians; no RSS or speed guarantee."}
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", required=True)
    parser.add_argument("--expect-ref", required=True)
    parser.add_argument("--index", required=True)
    parser.add_argument("--scope", choices=("engine", "app", "docs"), required=True)
    parser.add_argument("--mode", choices=("lexical", "semantic", "hybrid"), default="lexical")
    parser.add_argument("--model-dir")
    parser.add_argument("--cases-file", help="Explicit independent JSON case set; default curated cases")
    parser.add_argument("--case-group", choices=("development", "evaluation"))
    parser.add_argument("--lexical-profile", choices=repo_index.LEXICAL_PROFILES, default="legacy")
    parser.add_argument("--compare-cache", action="store_true", help="Measure verified lexical cache and require exact result parity")
    parser.add_argument("--diagnose-development", action="store_true",
                        help="Explain lexical development misses; never allowed for evaluation cases")
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
