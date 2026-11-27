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

## 8. Parallel development matrix

At each coherent product checkpoint, run the independent lexical matrix in CI. On your trusted local workstation, optionally run all nine cells with an explicitly selected model. The runner pins one revision, creates a fresh private output directory, builds each lexical/vector corpus once per scope, and reuses the vector index for semantic and hybrid benchmarks. It emits a completed matrix.json plus individual reports and local indices. Without a model, six semantic/hybrid cells are explicitly NOT_RUN. MEASURED is not a quality pass; missing expected source coverage is COVERAGE_FAIL and returns nonzero. A failed partial directory has no completed summary. Never reuse an existing output path.

```sh
work=$(mktemp -d)
python3 tools/rag_matrix.py --repo . --ref HEAD --out-dir "$work/lexical"
# Optional: genuine local vectors, on a trusted machine only.
python3 tools/rag_matrix.py --repo . --ref HEAD --out-dir "$work/full" --model-dir /absolute/path/to/trusted-model
```

Keep these private snapshots outside the checkout; do not publish indices, source chunks or vectors. Compare matrix.json at successive revisions; use the same model fingerprint, cases and ranking limits for comparisons. CI uses temporary lexical snapshots and deletes them after reporting, not persistent vector storage. A full run rebuilds vectors by default. Explicit incremental reuse is supported by the recipe-versioned local cache described below; independent held-out quality evaluation remains open. Keep product and RAG progress separate; continue development even if optional model execution is unavailable, but never label unrun vector cells as passed.

## 9. Incremental local vector checkpoints

Use only a trusted previous local semantic index generated by this recipe-aware version, or a completed full local matrix. A new index always reads the new committed tree, re-chunks it with the selected model, and verifies the old source text against its own commit. Only identical model input (path + text), scope, model fingerprint, dimension and versioned CPU/package recipe may be reused. New, edited or renamed input is encoded; deleted chunks are absent from the new index. A recipe mismatch or invalid old provenance fails rather than silently accepting stale vectors. Earlier semantic indices without recipe metadata must be rebuilt once. Source verification is not authentication of vector values; never reuse downloaded or untrusted indices. The same explicit model is required for retrieval. No old index is overwritten. Output indices are created exclusively with owner-only file permissions on supporting platforms.

```sh
python3 tools/repo_index.py build --repo . --ref HEAD --scope engine --model-dir "$model" --reuse-index "$previous/engine-semantic.json" --out "$work/engine-next.json"
python3 tools/rag_matrix.py --repo . --ref HEAD --model-dir "$model" --reuse-dir "$previous" --out-dir "$work/next-matrix"
```

Matrix cells report reused_embeddings and encoded_embeddings (semantic and hybrid share one build; do not sum those cells). No model download or inference is performed by the default lexical CI. Cache tests use a deterministic model double and validate reuse and provenance mechanics only. Real model speed, numerical equivalence and retrieval quality require local acceptance.


## Independent evaluation and matrix reuse consistency

The independent evaluation file `tools/rag_heldout_cases.json` contains a separate frozen set of nine EN/TR/DE file-retrieval targets (three per scope), authored before ranking was measured. The normal matrix CLI reports these separately from the original curated nine. The case files live in tools rather than the three evaluated corpora. Do not optimize on held-out outcomes and then claim independent quality; freeze a new evaluation set if tuning against these queries. Each report records the SHA-256 of the exact case-file bytes. Compare only like-for-like revision, dataset digest, ranking limits and model recipe. `--curated-only` reproduces the original benchmark format of three queries per scope (with added dataset fingerprint).

```sh
python3 tools/rag_matrix.py --repo . --ref HEAD --out-dir "$work/independent"
python3 tools/rag_matrix.py --repo . --ref HEAD --out-dir "$work/original" --curated-only
```

The second suite reopens the verified index for each measured mode; setup costs are separate from query timing. A missing expected source in either suite is COVERAGE_FAIL; a rank miss is measured quality evidence, not a coverage failure. Six vector cells remain NOT_RUN if no explicitly trusted local model is selected. No model is downloaded. The fixed suite is small, author-judged and file-level, not answer or hardware correctness.

For matrix reuse, the completed local manifest must declare all nine measured cells, the matching model fingerprint and one committed source revision. Each of the three semantic indices must match that revision, scope, mode and model before reuse; existing recipe, Git-source and unit-vector checks still apply during build. A syntactically valid index from a different matrix revision is refused. This is consistency checking, not a signature or proof that cached vector values are authentic; use only trusted local snapshots. Rebuild from scratch when incompatible. Do not publish indices or vectors.


## Experimental lexical file discovery profile (RAG-02)

The existing lexical score and ordering remain the default (`--lexical-profile legacy`). For file discovery, opt in to `--lexical-profile file-first`: the best ranked chunk from every distinct file precedes additional chunks, with existing deterministic tie breaking, total chunk and per-file bounds unchanged. Scores themselves are unchanged, so output order may not be descending by score in this profile. This is not a new embedding method or a default change; collecting multiple adjacent chunks from a known file may benefit from legacy ordering. Semantic and hybrid modes reject a nonlegacy lexical profile.

```sh
python3 tools/repo_index.py search --repo . --expect-ref HEAD --index "$work/engine.json" --query "MIDI owner cleanup" --lexical-profile file-first
python3 tools/rag_benchmark.py --repo . --expect-ref HEAD --index "$work/engine.json" --scope engine --cases-file tools/rag_ranking_cases.json --case-group development --lexical-profile file-first
```

The ordinary matrix runs paired legacy/file-first lexical comparisons for a distinct development group and a fresh evaluation group (nine queries each, three per scope; frozen before the candidate change). The original curated and first held-out measurements stay separate and use legacy ranking. Group fingerprints hash the selected canonical JSON array; standalone case-file fingerprints still hash exact bytes. Both profiles use the same pinned corpus, cases, cutoff and per-file cap. Reports are private; the CI summary contains aggregates only. Treat the small author-judged evaluation as evidence, not broad generalization. Do not select new parameters against evaluation outcomes and then call those results held-out. The optional `--curated-only` flag disables the extra evaluations.

Matrix cache reuse now carries the validated previous commit into the actual index read, rather than trusting only the earlier manifest check. Cache entries with the same path and exact text but conflicting vectors are rejected; rebuild without reuse on inconsistency, including possible nondeterministic model output. This is an additional fail-closed consistency check, not vector authenticity or real model equivalence. No model acquisition, source transfer, real-time inference or native behavior is introduced.


## Verified lexical session reuse (RAG-03)

For repeated queries over an already verified lexical session, call `prepare_lexical(prepared)` once after `prepare_search(args)`, then pass its result as `lexical_cache=cache` to `search_prepared(prepared, args, lexical_cache=cache)`. No disk cache or model is created. A None result means the retained-statistics budget was exceeded; use ordinary uncached retrieval. The optional cache is bound to the exact commit, scope and ordered source rows (including path, blob, line range and text). Changes require a new verified session and new cache. It is not a public trust boundary for arbitrary Python code or mutated private internals. Unverified sessions and model-backed searches cannot use this cache.

The retained term-entry budget is 300,000 and aggregate encoded term bytes are capped at 16 MiB, including filename terms. These are logical limits, not an RSS bound; the transient per-row tokenization and Python object overhead still exist. Ranking formulas, query validation, provenance, cutoffs, deterministic ordering and default one-shot behavior are unchanged. No embeddings, hardware or real-time code are involved.

```sh
python3 tools/rag_benchmark.py --repo . --expect-ref HEAD --index "$work/engine.json" --scope engine --cases-file tools/rag_ranking_cases.json --case-group development --compare-cache
```

The matrix includes paired cold/warm measurements on the existing development/legacy cases only. Exact equality of complete search responses is mandatory; discrepancies fail the benchmark. Cache setup, logical size, parity count and warm median are reported separately. Budget exhaustion is BUDGET_FALLBACK, not a warm pass. Timings run cold then warm in a single process, without randomized ordering, and exclude cache construction from per-query timing; do not infer a platform-independent speedup or memory profile. Development-only case IDs, languages and first-file ranks appear in the matrix summary; evaluation cases and source text are not logged as new diagnostics. The original curated and independent datasets are unchanged; this refactor does not attempt relevance tuning, so a new independent evaluation is deferred until a ranking change is proposed.


## Optional multilingual lexical queries (RAG-04)

`--lexical-profile multilingual` adds a small explicit Turkish/German-to-English technical glossary to existing lexical search. It preserves original tokens at weight 1, adds only distinct English aliases at weight 0.55, and caps additions at 64. Unicode decomposition/diacritic folding is for glossary lookup only; source text, provenance, original tokens, and the underlying BM25-style scoring remain intact. This is a deliberately limited, deterministic domain aid, not translation, stemming, semantic embeddings, or a language model. Ambiguity and missing inflections can reduce quality. The legacy default and file-first profile are unchanged. The same verified lexical statistics may serve either profile. Model-backed modes cannot use this experimental profile.

The new grouped fixture `tools/rag_multilingual_cases.json` contains separate, harder development and evaluation cases (nine each) frozen before implementing the profile. The default matrix reports paired legacy/multilingual metrics on each group separately, not blended with the previous held-out scores. Neither the glossary nor ranking should be tuned to the evaluation group after viewing results; further experiments require a fresh frozen evaluation. Tests are author-judged and small, not independent reviewer acceptance.

## Relative versus absolute control retrieval handoff (REL-RAG)

**Coordinator candidate only; not integrated into this branch.** At coordinator [revision 770cf9de](https://github.com/Tihulu/Tihulu-Trackpad-M-Mouse-Instrument/tree/770cf9defd3f18417113d740022a5365c5791659), the relevant source entry points are:

- [RelativeControlGesture.swift](https://github.com/Tihulu/Tihulu-Trackpad-M-Mouse-Instrument/blob/770cf9defd3f18417113d740022a5365c5791659/studio/Sources/NoSpeakerCore/RelativeControlGesture.swift): clutched signed displacement from the first valid input, manual reference, gain, range, smoothing, duplicate suppression; the first sample only anchors. A supplied manual value is not verified receiver feedback.
- [ContinuousResponse.swift](https://github.com/Tihulu/Tihulu-Trackpad-M-Mouse-Instrument/blob/770cf9defd3f18417113d740022a5365c5791659/studio/Sources/NoSpeakerCore/ContinuousResponse.swift): optional relative settings preserve legacy absolute default, restrict eligible continuous targets, reject duplicate relative target ownership, and retain the release policy.
- [SensorRouter.swift](https://github.com/Tihulu/Tihulu-Trackpad-M-Mouse-Instrument/blob/770cf9defd3f18417113d740022a5365c5791659/studio/Sources/NoSpeakerCore/SensorRouter.swift): coordinator-owned router integration and route/source lifecycle. [ContinuousResponsePanel.swift](https://github.com/Tihulu/Tihulu-Trackpad-M-Mouse-Instrument/blob/770cf9defd3f18417113d740022a5365c5791659/studio/Sources/NoSpeakerStudio/ContinuousResponsePanel.swift): explicit position mode and manual starting value.

The six separate development-only queries in `tools/rag_relative_development_cases.json` must be evaluated on a fresh verified index of a revision containing the above implementation, not on an older RAG-only tree. Run `tools/rag_benchmark.py` with that explicit case file and the engine/app scope (no docs cases). They are not part of either independent evaluation. Missing expected files are coverage failure, not retrieval success. Never construct an index by mixing source files from these two revisions. No inference of actual DAW feedback, universal hardware availability, or safe hold-last policy from this draft: receiver feedback provenance, target identity, re-anchor/loss, gyro wrapping, MPE composition, and hardware verification remain coordinator/assigned-agent responsibilities. See coordination PR #172 feature comment 7208806755.


## Context-aware lexical experiment and dataset independence (RAG-05)

The optional `multilingual-context` profile retains the earlier multilingual glossary and weights, except that ambiguous standalone forms (for example Turkish geri, bildirimi, yeniden and çubuk) do not inject aliases without a recognized adjacent-token phrase. Examples: geri bildirim → feedback; geri yükleme → restore; geri dönüş → return; yeniden başlatma → restart. This is deliberately a small rule set, not a translation engine. English terms, existing aliases, 64-alias cap, source verification and original token weights remain intact. Legacy and multilingual profiles are preserved unchanged. The separate `tools/rag_contextual_cases.json` grouped fixture compares multilingual against multilingual-context on six new development and six new evaluation queries. Do not interpret the development score as independent acceptance. Earlier evaluation outcomes remain historical, not tuning inputs. Exact normalized query/ID overlap between groups and repeated normalized queries within a group are now rejected before scoring; normalization is NFKC, casefold and whitespace collapse, not paraphrase detection. Every report must also match the initial group digest. This is a test-integrity guard, not proof of blind evaluation or semantic non-overlap.

## Relative reference evidence — successor handoff (REL-RAG-02)

The earlier 770cf9de record above remains a historical snapshot. The coordinator's [7e85ad90 candidate](https://github.com/Tihulu/Tihulu-Trackpad-M-Mouse-Instrument/tree/7e85ad90f5e63b66d088553ff6d53cbddf2667fe) extends it; the authoritative candidate contract is [studio/docs/RELATIVE_CONTINUOUS_CONTROL.md](https://github.com/Tihulu/Tihulu-Trackpad-M-Mouse-Instrument/blob/7e85ad90f5e63b66d088553ff6d53cbddf2667fe/studio/docs/RELATIVE_CONTINUOUS_CONTROL.md), not this RAG index note.

- [RelativeControlGesture.swift](https://github.com/Tihulu/Tihulu-Trackpad-M-Mouse-Instrument/blob/7e85ad90f5e63b66d088553ff6d53cbddf2667fe/studio/Sources/NoSpeakerCore/RelativeControlGesture.swift): explicit manual, lastDelivered and receiverConfirmed reference sources; host evidence maximum age 250 ms.
- [SensorRouter.swift](https://github.com/Tihulu/Tihulu-Trackpad-M-Mouse-Instrument/blob/7e85ad90f5e63b66d088553ff6d53cbddf2667fe/studio/Sources/NoSpeakerCore/SensorRouter.swift): host-only evidence admission, session/mapping/destination scope, one-shot consumption and watermark, missing evidence/contended gesture requires actual release; no manual fallback for requested live reference. Actual delivery/receiver and endpoint/channel/parameter identity must be verified by the host adapter, not inferred from transport ACK or output intent.
- [ContinuousResponsePanel.swift](https://github.com/Tihulu/Tihulu-Trackpad-M-Mouse-Instrument/blob/7e85ad90f5e63b66d088553ff6d53cbddf2667fe/studio/Sources/NoSpeakerStudio/ContinuousResponsePanel.swift) and [InstrumentBuilderView.swift](https://github.com/Tihulu/Tihulu-Trackpad-M-Mouse-Instrument/blob/7e85ad90f5e63b66d088553ff6d53cbddf2667fe/studio/Sources/NoSpeakerStudio/InstrumentBuilderView.swift): capability-aware editor, reference-range validation and accessibility candidate.

No actual feedback provider, negotiated client transform, angular seam resolution or physical acceptance is inferred. New source-specific retrieval queries belong to a separate development-only suite and must run on a single verified source tree containing the successor. Candidate-only paths remain NOT_RUN on this RAG branch; do not manufacture a combined index. The 250 ms reference evidence limit is distinct from all existing live source freshness, neutral and cleanup deadlines.
