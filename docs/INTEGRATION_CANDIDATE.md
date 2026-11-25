# Isolated application + SDK integration baseline

Evidence-only draft candidate, not a release or a merge of either development PR.

- Application baseline: `15c04dcc8a1a95af374f0c6a210bf0a5b9ca8cee` (#167), CI 45706710999, both jobs passed.
- SDK baseline: `47e07fbb9839c00cb6e42f5a699281498f101dbe` (#166), CI 45707053397, both jobs passed, all 15 isolated native fixtures passed.
- Common ancestor: `4068d89580bc4e6f96167fd440d3a819122e8993`.
- 38 SDK-only paths copied by exact Git blob SHA from the frozen SDK head. The intermediate overlay tree is `37537f14ebb61f938b7ddf3133a0ac9eb6efe1e5`. Compare this tree with the application baseline and SDK head for exact blob provenance.
- Six overlapping paths reviewed: retain application MIDIHapticService and CustomTouchConfigurationTests (the SDK shared client changes and test are already present); identical VoiceRenderCancellation and VoiceProcessRunnerTests retained; combine both CI workflows and verify scripts.
- Preserve the application disk-image retry policy and group experimental compile gate; preserve all SDK tests, external consumer, native fixtures and CLI bundle boundary checks.
- This baseline deliberately excludes later commits on both original draft branches. Do not assume standalone CI proves integrated compatibility.
- No stable branch change, release, installer execution, physical permission request, or live CLI output change. Physical acceptance remains separate.

## Acceptance

All shared tests, native fixture inventory and each isolated fixture, CLI and consumer checks, experimental compile flags, app boundary and preview package checks must pass on this exact tree. Inspect actual logs. Any regression blocks integration. The original development PRs remain independent.

## First integration failure and remediation

Run 45709143202 used the initial main-target PR merge checkout (3365bf2, main base c504a8430e1a6d55573c8cd9f10f6a7465d3cbc6), before retargeting to the frozen QA base. The macOS compiler also exposed a real private-access mismatch in the integrated head: MIDIProcessClient was private while the SDK monitor and playback need module-internal access. The integrated source was re-read and corrected, with no widening to a public API. For this QA branch both jobs explicitly check out the event's exact PR head SHA and assert the checkout identity, then use it for bundle and DMG provenance. Original development branches and main are unaffected. Do not erase the failed run or classify the fix as passed before its own CI.

## First exact integrated PASS and successor overlay

The exact integration commit `b12317d102b52f97d6e63307cee203d3fef9797b` (tree `a0686a18418db75734b9a33ab41d3b973744b79c`) passed run 45709457115: 709 portable tests, 756 macOS general tests and all 15 isolated native fixtures, plus CLI, consumer, experimental compile and preview packaging. Both jobs recorded the exact checkout and tree. The previous failed integration run is retained.

The later standalone app head `a23d3d563bd61367f8fa1cda10bafeefdbf4ce99` passed CI 45708563510 (674 portable, 702 macOS general). The later standalone SDK head `fcda27b6d2d962d153d840f4063bd4a4c7d06d59` passed CI 45708478779 (519 portable, 560 macOS general, 16/16 isolated native fixtures). Their five application and seven non-workflow SDK changed paths are overlaid by exact blob SHA. The integration workflow retains exact checkout, experimental compile and preview provenance, and adds the sixteenth required fixture. This new tree is a successor, not covered by the earlier PASS. Do not advance either original draft or main, publish, install, or enable live CLI.

Two independent review tracks are proposed: integrated packaging/provenance and MIDI/input runtime regressions. Reviewers must work on frozen commits, report reproducible evidence and not modify the review head.
