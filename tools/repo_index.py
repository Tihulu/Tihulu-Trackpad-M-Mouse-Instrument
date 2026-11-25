#!/usr/bin/env python3
"""Commit-pinned, local-only repository retrieval index. No code execution."""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import re
import subprocess
import sys
from collections import Counter

SCHEMA = 1
MAX_FILE = 512 * 1024
MAX_SOURCE = 32 * 1024 * 1024
MAX_CHUNKS = 12000
MAX_INDEX = 256 * 1024 * 1024
EXTENSIONS = {".swift", ".md", ".py", ".sh", ".js", ".ts", ".html", ".css", ".json", ".yml", ".yaml", ".toml", ".c", ".h", ".m", ".mm"}
ROOTS = {"studio", "docs", "scripts", "tools", "web", "remote", "Sources", "Tests", "src"}
ROOT_FILES = {"README.md", "LICENSE", "NOTICE", "ATTRIBUTION.md", "CONTRIBUTING.md", "AGENTS.md", "Package.swift", "install-studio.sh", "uninstall-studio.sh"}
EXCLUDED = {".git", ".build", "node_modules", "vendor", "models", "recordings", "captures", "secrets", "private", "credentials", "fixtures-private", "__pycache__"}


def git(repo, *args):
    return subprocess.check_output(["git", "-C", str(repo), *args], stderr=subprocess.PIPE)


def allowed(path):
    p = Path(path)
    parts = p.parts
    if not parts or p.is_absolute() or ".." in parts:
        return False
    if any(part.lower() in EXCLUDED or part.startswith(".env") for part in parts):
        return False
    if re.search(r"(^|[._-])(secret|credentials?|token|private[_-]?key)([._-]|$)", p.name, re.I):
        return False
    if len(parts) == 1:
        return path in ROOT_FILES
    return (parts[0] in ROOTS or parts[:2] == (".github", "workflows")) and p.suffix.lower() in EXTENSIONS


def chunks(repo, commit):
    raw = git(repo, "ls-tree", "-r", "-z", "--full-tree", commit)
    total = 0
    result = []
    skipped = []
    for entry in raw.split(b"\0"):
        if not entry:
            continue
        meta, name = entry.split(b"\t", 1)
        mode, kind, oid = meta.decode("ascii").split()
        path = name.decode("utf-8", errors="strict")
        if mode not in {"100644", "100755"} or kind != "blob" or not allowed(path):
            continue
        size = int(git(repo, "cat-file", "-s", oid))
        if size > MAX_FILE:
            skipped.append({"path": path, "reason": "file-size"})
            continue
        total += size
        if total > MAX_SOURCE:
            raise ValueError("Source budget exceeded; split the index explicitly")
        data = git(repo, "cat-file", "blob", oid)
        try:
            text = data.decode("utf-8")
        except UnicodeDecodeError:
            skipped.append({"path": path, "reason": "non-utf8"})
            continue
        if "\0" in text:
            skipped.append({"path": path, "reason": "binary"})
            continue
        lines = text.splitlines()
        for first in range(0, len(lines), 70):
            last = min(first + 80, len(lines))
            body = "\n".join(lines[first:last])
            if not body.strip():
                continue
            # Explicitly omit oversized minified/generated windows rather than
            # silently misrepresenting their content or model token budget.
            if len(body.encode("utf-8")) > 24000:
                skipped.append({"path": path, "line": first + 1, "reason": "chunk-size"})
                continue
            result.append({"path": path, "blob": oid, "start": first + 1,
                           "end": last, "text": body})
            if len(result) > MAX_CHUNKS:
                raise ValueError("Chunk budget exceeded")
            if last == len(lines):
                break
    return result, skipped


def fingerprint(directory):
    root = Path(directory).resolve(strict=True)
    if not root.is_dir():
        raise ValueError("Model must be an existing local directory")
    digest = hashlib.sha256()
    count = 0
    for path in sorted(root.rglob("*")):
        if path.is_symlink():
            raise ValueError("Model directory must contain real files, not symlinks")
        if not path.is_file():
            continue
        count += 1
        digest.update(str(path.relative_to(root)).encode("utf-8") + b"\0")
        with path.open("rb") as stream:
            file_digest = hashlib.sha256()
            for block in iter(lambda: stream.read(1024 * 1024), b""):
                file_digest.update(block)
        digest.update(file_digest.digest())
    if not count:
        raise ValueError("Empty model directory")
    return root, digest.hexdigest()


def model_for(directory):
    root, identity = fingerprint(directory)
    os.environ["HF_HUB_OFFLINE"] = "1"
    os.environ["TRANSFORMERS_OFFLINE"] = "1"
    try:
        from sentence_transformers import SentenceTransformer
    except ImportError as exc:
        raise ValueError("Install sentence-transformers separately for local semantic indexing") from exc
    model = SentenceTransformer(str(root), device="cpu", local_files_only=True, trust_remote_code=False)
    return model, identity


def semantic_windows(rows, model, skipped):
    """Respect the selected model's input budget rather than silently truncate."""
    limit = int(model.max_seq_length) - 16
    if limit < 32:
        raise ValueError("Embedding model context is too small")
    result = []
    for row in rows:
        lines = row["text"].split("\n")
        first = 0
        pending = []
        def fits(candidate):
            text = row["path"] + "\n" + "\n".join(candidate)
            return len(model.tokenizer.encode(text, add_special_tokens=True, truncation=False)) <= limit
        def append():
            if pending:
                result.append({**row, "start": row["start"] + first,
                               "end": row["start"] + first + len(pending) - 1,
                               "text": "\n".join(pending)})
        for index, line in enumerate(lines):
            if fits(pending + [line]):
                if not pending:
                    first = index
                pending.append(line)
                continue
            append()
            pending = []
            if fits([line]):
                first = index
                pending = [line]
            else:
                skipped.append({"path": row["path"], "line": row["start"] + index,
                                "reason": "model-context"})
        append()
        if len(result) > MAX_CHUNKS:
            raise ValueError("Semantic chunk budget exceeded")
    if not result:
        raise ValueError("No chunks fit model context")
    return result


def normalized(vector):
    values = [float(x) for x in vector]
    if not 1 <= len(values) <= 4096 or not all(math.isfinite(x) for x in values):
        raise ValueError("Invalid embedding")
    length = math.sqrt(sum(x * x for x in values))
    if not math.isfinite(length) or length <= 0:
        raise ValueError("Invalid embedding norm")
    return [x / length for x in values]


def build(args):
    repo = Path(args.repo).resolve(strict=True)
    commit = git(repo, "rev-parse", "--verify", "--end-of-options", args.ref + "^{commit}").decode().strip()
    if not re.fullmatch(r"[0-9a-f]{40,64}", commit):
        raise ValueError("Invalid resolved commit")
    rows, skipped = chunks(repo, commit)
    if not rows:
        raise ValueError("No indexable content")
    metadata = {"schema": SCHEMA, "commit": commit, "mode": "lexical",
                "model_sha256": None, "dimension": None, "skipped": skipped}
    if args.model_dir:
        model, identity = model_for(args.model_dir)
        rows = semantic_windows(rows, model, skipped)
        dimension = None
        for first in range(0, len(rows), 16):
            batch = rows[first:first + 16]
            vectors = model.encode([r["path"] + "\n" + r["text"] for r in batch],
                                   show_progress_bar=False, convert_to_numpy=True)
            if len(vectors) != len(batch):
                raise ValueError("Embedding count mismatch")
            for row, vector in zip(batch, vectors):
                row["embedding"] = normalized(vector)
                dimension = dimension or len(row["embedding"])
                if len(rows) * dimension > 8000000:
                    raise ValueError("Embedding budget exceeded; use a smaller model or source scope")
                if len(row["embedding"]) != dimension:
                    raise ValueError("Embedding dimension mismatch")
        # Detect a model directory edited during the build.
        if fingerprint(args.model_dir)[1] != identity:
            raise ValueError("Model changed during indexing")
        metadata.update(mode="semantic", model_sha256=identity, dimension=dimension)
    payload = json.dumps({"metadata": metadata, "chunks": rows}, ensure_ascii=True, allow_nan=False)
    if len(payload.encode("utf-8")) > MAX_INDEX:
        raise ValueError("Index budget exceeded")
    output = Path(args.out)
    # Exclusive creation; no existing user index is overwritten.
    with output.open("x", encoding="utf-8") as stream:
        stream.write(payload)
    return {"commit": commit, "chunks": len(rows), "mode": metadata["mode"],
            "skipped": len(skipped), "index": str(output)}


def tokens(text):
    text = re.sub(r"([a-z0-9])([A-Z])", r"\1 \2", text)
    return re.findall(r"[a-z0-9_]+", text.lower())


def search(args):
    with Path(args.index).open("rb") as stream:
        data = stream.read(MAX_INDEX + 1)
    if len(data) > MAX_INDEX:
        raise ValueError("Index exceeds size limit")
    doc = json.loads(data)
    meta, rows = doc["metadata"], doc["chunks"]
    if meta["schema"] != SCHEMA or not 0 < len(rows) <= MAX_CHUNKS:
        raise ValueError("Unsupported or invalid index")
    if not 1 <= args.limit <= 50 or not args.query.strip() or len(args.query) > 4096:
        raise ValueError("Invalid query or result limit")
    ranked = []
    if args.model_dir:
        if meta["mode"] != "semantic":
            raise ValueError("This index has no embeddings; rebuild with a local model")
        model, identity = model_for(args.model_dir)
        if identity != meta["model_sha256"]:
            raise ValueError("Embedding model differs from index")
        query = normalized(model.encode([args.query], show_progress_bar=False, convert_to_numpy=True)[0])
        if fingerprint(args.model_dir)[1] != identity:
            raise ValueError("Model changed during query")
        if len(query) != meta["dimension"]:
            raise ValueError("Query dimension differs from index")
        for row in rows:
            vector = normalized(row["embedding"])
            if len(vector) != len(query):
                raise ValueError("Invalid stored vector dimension")
            ranked.append((sum(a * b for a, b in zip(query, vector)), row))
        mode = "semantic"
    else:
        terms = set(tokens(args.query))
        if not terms:
            raise ValueError("No searchable terms")
        for row in rows:
            words = Counter(tokens(row["path"] + "\n" + row["text"]))
            score = sum(math.log1p(words[t]) for t in terms)
            if score > 0:
                ranked.append((score, row))
        mode = "lexical"
    ranked.sort(key=lambda item: (-item[0], item[1]["path"], item[1]["start"]))
    return {"commit": meta["commit"], "mode": mode, "results": [
        {**{k: row[k] for k in ("path", "blob", "start", "end", "text")}, "score": round(score, 6)}
        for score, row in ranked[:args.limit]]}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    b = sub.add_parser("build")
    b.add_argument("--repo", default=".")
    b.add_argument("--ref", default="HEAD")
    b.add_argument("--out", required=True)
    b.add_argument("--model-dir")
    q = sub.add_parser("search")
    q.add_argument("--index", required=True)
    q.add_argument("--query", required=True)
    q.add_argument("--limit", type=int, default=8)
    q.add_argument("--model-dir")
    args = parser.parse_args(argv)
    try:
        result = build(args) if args.command == "build" else search(args)
        print(json.dumps(result, ensure_ascii=True, allow_nan=False))
        return 0
    except (ValueError, OSError, KeyError, TypeError, subprocess.CalledProcessError) as exc:
        print("repo-index: " + str(exc), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
