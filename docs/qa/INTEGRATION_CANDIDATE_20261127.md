# Combined validation candidate — 2026-11-27

This draft is a source-tree validation candidate, not a release or accepted merge. Parent #215 `b87e5fa4aeced10675b81e92765bbbf7fe24667f` (four platform CI success at run 45936475470). Original common comparison base #173 `34361977e4ae8754790194e6a95a6088e8b4eefc`.

All source changes were selected from exact frozen agent trees and verified against full recursive leaf tree diffs and previously checked GitHub compare counts. Every changed blob and mode is carried unchanged, with no path overlap across the selected agent and coordinator changes. Original branches and commits remain the source of authorship and review history; the copy commit is not a count of new independent implementation commits.

| Stream | Draft PR | Exact source commit | Tree | Original commits | Paths |
| --- | --- | --- | --- | ---: | ---: |
| WEB | #209 | `1f07fb80cf01cce74a3d250763152a7ab2ada47c` | `af84f58ca3d915e40bcf1f73c5dceb6588dfe25b` | 23 | 3 |
| UX | #214 | `59e2d8dc3846788b4d9c12844d5f1e77727e259b` | `0e15f8aa4b90a4e8f3f790a4e3f13a911b2b9f0c` | 32 | 32 |
| MOBILE | #208 | `2b8219865d59e3e28884570262b9788c4c7dfcc5` | `4c465a035abd65239cda9655ff380390abe69d07` | 33 | 31 |
| SEQUENCER | #211 | `56747ddebc28ef96c1985d4a52fea42be50dc776` | `dcf2e54750469271ce49b25ae9960bf708c0f7fb` | 25 | 11 |
| RAG | #213 | `7e160bf11e67296c89c18e7fe175506b53b1a784` | `6545310736b3ff68017f19e25676235b3d65a12c` | 55 | 15 |
| TUNING | #204 | `d80b59ea858d75949ebb9b39c7a01623d261690c` | `af2dd6d4f676c51cf16da54bed99ab7cff3a0a13` | 33 | 18 |

Total imported paths: 110. All selected agent product core/RAG checks succeeded where applicable (UX is documentation-only). Individual native results do not transfer to this tree. The combined corpus and cross-module behavior can change results; previous evaluation measurements are not proof of this candidate's quality. Preserve every earlier failed run and all safety deadlines. Native mobile validation must execute rather than skip. No live hardware activation, stable writes, merge, release, or automatic installation. New relative owner interlock is intentionally not included; its own candidate requires independent review and CI first.

Acceptance: exact checkout and tree; four platform jobs; local RAG checks and evaluation provenance; verify imported source blob/mode equality and no source overlap; explicit regression analysis if any failure. Physical Trackpad, Magic Mouse, Touch Bar, mobile, accessibility and Logic receiver acceptance remain separate.
