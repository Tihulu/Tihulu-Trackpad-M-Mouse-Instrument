# Offline CI receipt audit — review candidate

Independent tool for checking normalized TIHULU product CI receipts. No network calls, secrets, dependencies, workflow edits, native activation, release, or approval actions. Python 3 standard library only.

From repository root:

```sh
(cd tools/ci_receipt_audit && python3 -m unittest -v)
python3 tools/ci_receipt_audit/ci_gate.py SNAPSHOT.json --pins PINS.json
python3 tools/ci_receipt_audit/receipt_gate.py SNAPSHOT.json PINS.json RUNS.json EXCERPTS.json
```

Exit 0 all supplied candidates satisfy the selected checker, 1 HOLD, 2 invalid input. `ci_gate` is a normalized job/step/checkout classifier, not a release gate. Provide independently pinned PR/head/tree/run identities. `receipt_gate` additionally requires matching log excerpts, exact checkout, successful overall run and matching explicit run, job and excerpt attempt IDs. Missing attempts remain unknown, conflicts HOLD; never infer attempt 1. A mobile SHA-only excerpt cannot prove a different commit's tree. For mobile exact SHA, the workflow's checkout step and `EXPECTED_SHA` must match. See synthetic fixtures in tests for schemas and named required steps. Logs and metadata must come from separately trusted acquisition. Hashes are local integrity checks, not authentication, signed attestations or proof of earlier attempts. Physical acceptance and RAG quality remain separate. Do not add these scripts to mandatory workflows until independent review. Historical capture files are deliberately not bundled in repository patch; CLI tests are hermetic.

The optional `Offline CI receipt audit review` workflow runs only on same-repository PRs whose head branch starts with `agents/ci-receipt-audit-` and whose changes touch the audit directory or its review workflow. It checks out the PR head SHA, runs the hermetic regression suite, and records its own run attempt. This review job is not a product CI receipt, release gate, or replacement for the product/RAG workflows. It does not grant acceptance to another commit or authenticate historical logs. Do not mark it required until independent review.
