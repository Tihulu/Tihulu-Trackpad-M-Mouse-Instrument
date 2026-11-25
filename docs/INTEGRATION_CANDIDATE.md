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
