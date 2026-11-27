# Local RAG SDK — engine, application and documentation

Status: experimental developer tooling. No dependency in the real-time engine or Studio app. No answer generation, agent execution, native GUI or automatic indexing on launch. The index is a local JSON artifact containing source text and, optionally, real vectors. The scope is an inclusion filter, not a security sandbox.

## 1. Choose your corpus

| Scope | Included |
| --- | --- |
| engine | Core, macOS and mobile capture libraries, CLI, core/native tests, package and independent SDK example |
| app | SwiftUI Studio, native mobile projects, resources, packaging, CI, installer and web/remote directories if present |
| docs | Allowed Markdown and capability manifest |
| all | All allowlisted tracked files, including tools |

Scopes overlap deliberately at the package manifest and the native HTTPS server source (`RemoteLoopbackPageServer.swift`), which embeds the actual browser controller UI. Android Kotlin, XML and Gradle, iOS plist and project text are supported when tracked and allowlisted. Generated build directories, binaries, model files, private paths and symlinks are excluded; source is not scanned for secrets. Review source before sharing. The older schema-1 index without a scope is interpreted as all.

## 2. Start without dependencies

Run in a checked-out repository on a trusted machine. Use new paths each time:

```sh
work=$(mktemp -d)
rev=$(git rev-parse HEAD)
python3 tools/repo_index.py build --repo . --ref "$rev" --scope engine --out "$work/engine.json"
python3 tools/repo_index.py build --repo . --ref "$rev" --scope app --out "$work/app.json"
python3 tools/repo_index.py build --repo . --ref "$rev" --scope docs --out "$work/docs.json"
python3 tools/repo_index.py context --repo . --expect-ref "$rev" --index "$work/engine.json" --query "MIDI sustain ownership and cleanup" --limit 6
python3 tools/repo_index.py context --repo . --expect-ref "$rev" --index "$work/app.json" --query "custom pad editor and mobile mode selection" --limit 6
python3 tools/repo_index.py context --repo . --expect-ref "$rev" --index "$work/docs.json" --query "Logic Pro microtonal setup" --limit 6
```

This is **lexical** retrieval, not vectorization. Ranking uses Unicode and identifier-aware tokenization, bounded term-frequency/length normalization and rare filename-term weighting. By default at most three ranked chunks per file are returned in each search/context call; use `--max-per-file 1` for breadth or up to 50 for focused source inspection. Scores are ranking signals, not probabilities. Each context call verifies source path, blob and exact lines against Git and rejects a stale revision. It returns only whole chunks within a serialized JSON byte budget (default 32,000 bytes; 1,024–128,000), or an error when nothing fits. The newline on stdout is separate. Byte limits are not LLM token limits.

## 3. Real local embeddings and hybrid retrieval

Install sentence-transformers in a separately managed environment, and obtain a licensed, trusted local model directory with actual files (no symlinks). Choose a model suitable for code and the languages you need; do not assume all models rank equally. No downloads or remote model code are requested by the tool. CPU inference is the current backend. Offline library settings are not an OS sandbox.

```sh
model=/absolute/path/to/trusted-local-embedding-model
python3 tools/repo_index.py build --repo . --ref "$rev" --scope engine --model-dir "$model" --out "$work/engine-vector.json"
python3 tools/repo_index.py build --repo . --ref "$rev" --scope app --model-dir "$model" --out "$work/app-vector.json"
python3 tools/repo_index.py context --repo . --expect-ref "$rev" --index "$work/engine-vector.json" --model-dir "$model" --hybrid --query "How does a stopped source release MIDI notes?" --limit 8
python3 tools/repo_index.py context --repo . --expect-ref "$rev" --index "$work/app-vector.json" --model-dir "$model" --hybrid --query "Where does Studio display a mobile controller's connection state?" --limit 8
```

Semantic mode uses cosine similarity of normalized model vectors; hybrid uses reciprocal rank fusion of lexical and semantic rankings, not raw-score addition. Omit --hybrid for semantic-only mode. The model fingerprint must match; oversized token windows are split or reported skipped. No simulated embeddings. Corpus/chunk/vector limits are bounded; use scopes or smaller dimensions when the budget fails. Prompt-sensitive models may need model-specific query/document formatting in a future backend; quality is not certified. Real model execution and retrieval quality require separate evaluation.

## 4. SDK integration

Use the existing Swift libraries or offline JSON CLI for actual music operations; use RAG only to locate relevant implementation and documentation. See [SDK reference](DEVELOPER_SDK_AI_INDEX.md), [capability manifest](ENGINE_CAPABILITIES.json), and [external Swift consumer](../examples/EngineConsumer/README.md).

A trusted Python caller can retrieve a structured context without shell interpolation:

```python
import json
import subprocess
from pathlib import Path

repo = Path("/absolute/path/to/checkout")
index = Path("/absolute/path/to/engine.json")
revision = subprocess.check_output(
    ["git", "-C", str(repo), "rev-parse", "HEAD"], text=True
).strip()
cmd = ["python3", str(repo / "tools/repo_index.py"), "context",
       "--repo", str(repo), "--expect-ref", revision,
       "--index", str(index), "--query", "note ownership",
       "--limit", "5", "--max-bytes", "24000"]
evidence = json.loads(subprocess.check_output(cmd, text=True, timeout=120))
assert evidence["source_verified"] and evidence["commit"] == revision
for source in evidence["sources"]:
    print(source["citation"])
```

Pass only approved evidence to a local model or a separately authorized external model. Keep source text in a data field distinct from system instructions. Require the answer to cite path, line range and commit; inspect original files before changes. Reject missing or stale citations. Verification checks provenance, not completeness, embedding accuracy, authorization or whether a source instruction should be followed. A source can contain malicious prompt injection. No automatic execution or hardware access is granted.

For app work, retrieve the app corpus first and engine separately when a routing or ownership contract is needed. For SDK work, start with the engine and docs corpora and run the independent example. Use fresh indices on checkout changes; do not commit or expose these artifacts. Remove them when no longer needed.

## 5. Example retrieval tasks

| Task | First corpus | Follow-up corpus |
| --- | --- | --- |
| Where do held notes release on source loss? | engine | docs |
| How do I add a custom expression pad without breaking MIDI ownership? | app | engine |
| What does a mobile device need before it can send motion? | app | docs, engine |
| How do I export a microtonal MIDI file? | docs | engine |
| Where are native MIDI cleanup and timing bounds defined? | engine | docs |
| What is actually available in the published app? | docs | inspect exact release tag separately |

Retrieve each corpus at the same explicit revision. Keep the provenance on every result when merging context in your own SDK client. Do not infer release status from draft source or from retrieval rank. Compare queries in English, Turkish and German when evaluating model quality. A lexical Unicode tokenizer is not a translation system.

## 6. Measure retrieval quality on the actual repository

The local benchmark uses nine curated file-level targets across engine, app and docs, with English, Turkish and German queries. It verifies commit/source provenance once per scope, loads a selected local model once per run, and reports file hit rate, reciprocal rank, missing expected files, setup time and median query time. Top-k is a chunk limit, with the same per-file limit as search (default three); repeated files are deduplicated for file rank. Use the same k, per-file limit and cases when comparing modes. This curated set is useful for regression evidence, not an independent generalization test. These metrics are preliminary retrieval evidence, not answer accuracy or native acceptance.

```sh
python3 tools/rag_benchmark.py --repo . --expect-ref "$rev" --index "$work/engine.json" --scope engine
python3 tools/rag_benchmark.py --repo . --expect-ref "$rev" --index "$work/engine-vector.json" --scope engine --mode semantic --model-dir "$model"
python3 tools/rag_benchmark.py --repo . --expect-ref "$rev" --index "$work/app-vector.json" --scope app --mode hybrid --model-dir "$model"
```

The independent Linux RAG workflow runs the portable unit tests and builds/benchmarks actual commit-pinned lexical corpora. Missing target coverage fails; score reports are not a claim that a real model passed. No model download, GPU dependency, index upload or native build is required for this check. Compare semantic/hybrid results separately using an explicitly selected local model. Keep the benchmark revision and model fingerprint with any result.

## 7. Acceptance and follow-up

- Portable tests: `python3 tools/test_repo_index.py`; CI includes the suite.
- Verify scoped source inclusion, old index compatibility, stale revision refusal, bounded context, malformed metadata and forged source checks.
- Hybrid ranking fixture tests ranking math only. A real local model and representative engine/app/docs benchmark are still required.
- Future optional Studio help must be separated from the audio/MIDI path, offline-first, opt-in, cancellable and read-only by default. No native assistant has been added.
