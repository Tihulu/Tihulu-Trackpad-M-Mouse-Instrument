# MUSIC-UX-VERIFY checkpoint 1 — acceptance execution plan

Base: 34361977e4ae8754790194e6a95a6088e8b4eefc. Role is read-only production code, isolated report branch only. Follow AGENTS.md, master plan, original 53-row register and prior claims. No merge/release/install/hardware activation.

## Evidence and measures

P1_MATRIX.md and P2_MATRIX.md index all 53 findings. Seven independent report structure assertions executed against GitHub-read report blobs: 53 rows, unique IDs, contiguous 001–053, 15 P1, 38 P2, proposed reproduction present on each row, both reports carry exact base. All 7 PASS. This is report validation, not product execution. Static classification: 31 OPEN (includes partial source gaps), 14 CANDIDATE (includes partial changes), 8 NOT_RUN/inconclusive; 45/53 (84.91%) adjudicated at source-triage level, 8/53 (15.09%) still need more source work. 53/53 indexed; 0/53 independently closed; all 53 runtime acceptance checks NOT_RUN. P1 triage 15/15, no P1 closure. Do not equate source adjudication with full review or product implementation. Work-package planning estimate 45% (+45 pp from new slot's 0% baseline), remaining 55%; weighting judgment, not measured completion. No global estimate change: 69.20% / 30.80% (coordinator baseline).

## Five surface families / next executable work

| Family | Test bundle | Expected oracle |
|---|---|---|
| macOS | Compact transport, session inventory, independent custom pad drafts/active pair, Touch Bar base labels/velocity, sequencing frozen take, USB offline/native boundary, keyboard-only controls | Scoped stop vs global Panic; actual active owner and frozen plan, no automatic rearm, no fake DAW status |
| iPhone/iPad | Local vs paired touch, classic/linear geometry, touch-only denied-camera pairing, all Air modes and XYZ helper/instrument/hybrid, portrait/landscape/split, VoiceOver | Authorized slots only; geometry and lifecycle retirement, separate measured depth, trust and ACK preserved |
| Android | Paired 240dp vs local weighted stage, expanded/compact, TalkBack, DEPTH16/ARCore, custom calibration and role negotiation | Real support only; no fake depth; permission/rotation/background/stale data release |
| Live browser | Classic two-finger slide, modes/phrase readiness, Air Stick overlap, pedals, reconnect and focus | Actual edge ordering, scoped ownership, neutral ACK, explicit rearm; no auth/TLS weakening |
| GitHub Pages | Independently fetch separate documented revision; simulation monitor, keyboard, locale, responsive settings | Simulation clearly labeled, no inference about host/runtime; do not modify shared Pages branch |

Additional role matrix: instrument (notes), helper (continuous/binary controls), hybrid (notes + controls), each with unavailable/idle/draft/armed/held/releasing/debt/fault states. C/ MobileAirInstrument.swift:5–15 lists 11 Air modes; C/MobileLANCapabilities.swift:10–16 has explicit XYZ/hybrid lanes; S/InstrumentBuilderView.swift:73 displays draft source roles, not active receiver truth. Review these individually, not as one generic camera test. Accessibility: use real VoiceOver/TalkBack/keyboard and screen-size/contrast checks, no color-only status, explicit bounded press/release; no measured results here. All existing 50/100/150/220/350ms gates remain mandatory where applicable; no safety code changes. Tests proposed per matrix row, not run.

## Existing exact-base CI (observed, not executed by this agent)

- Product run 45930559440: shared core job 140281950671 PASS including browser lifecycle step; iOS compile/unsigned build job 140281950780 PASS; Android compile/unit job 140281950885 PASS. macOS job 140281950808 in progress at observation: unit tests, isolated native MIDI fixtures, Studio build, standalone verification, experimental compile, entrypoint mode checks all successful; installer/DMG steps unfinished. No exact test counts retrieved; do not reuse predecessor counts as current.
- RAG run 45930559400 job 140281950733 PASS, tracked script modes and lexical corpus/benchmark. Real semantic/hybrid cells not certified.
- Prior failure evidence preserved: coordinator comment #issuecomment-7208470646 records previous installer failure at 1c23577d despite tests and compilation. No physical acceptance or final package PASS.

Local git ls-remote blocked by DNS; no checkout, no execution of verify.sh, no browser/native UI or devices. GitHub reads succeeded, exact integration PR #173 head observed still at base before this report. No CI manually triggered to avoid duplicate runs; exact report-head CI not yet established. Review branch changes are docs only. Coordinator should retain existing product and RAG exact-head gates. Final integration diff to be checked after this commit.

Next: resolve 8 inconclusive source rows, including separate Pages revision, then run targeted offline and rendered platform tests in suitable environment. Preserve source and physical evidence separately; request coordinator review of candidate status before closure.
