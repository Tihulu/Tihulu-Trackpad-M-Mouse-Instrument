# Isolated R9 preview acceptance package

Use the existing preview-only GitHub Actions artifact, not install-studio.sh, which replaces the stable app and stops processes named NoSpeakerStudio. No public release is created. Stable main is not modified. The candidate is a draft and has a separate bundle identifier and app display name; this separates the normal macOS preferences domain, not physical devices, MIDI endpoints, permissions or system-wide pointer capture. Quit stable normally before launching preview. Do not test both simultaneously. Do not bypass TLS, Gatekeeper or signature validation.

The CI checkout SHA may be a synthetic pull-request merge commit; PREVIEW-PROVENANCE.txt records both that checkout SHA and PR head SHA plus run identity. Verify the artifact from the matching successful run, not an older run or main release. PREVIEW-SHA256SUMS verifies file integrity, not publisher authenticity. The preview uses the existing ad-hoc/development signing path and is not a notarized public distribution.

New read-only verifier mounts the DMG temporarily, checks SHA-256, image verification, preview-only app name, bundle identity, channel, version, embedded checkout SHA, executable, icon and strict signature; never installs or launches. Usage from repository checkout on macOS:

```sh
sh studio/scripts/verify-preview-dmg.sh Tihulu-0.3.0-preview.dmg PREVIEW-SHA256SUMS EXPECTED_CHECKOUT_SHA
```

Use the exact checkout SHA from the trusted GitHub workflow record. After current-head CI success, download the preview artifact from that run; inspect and copy only the Preview.app into a separate test folder, never overwrite stable. Use a disposable DAW session, MIDI off initially. Run P01-P14 from REMOTE_R9_ACCEPTANCE_MATRIX.md. Quit and delete only the Preview.app to roll back the test. Do not run the stable installer or uninstaller for this preview. Keep user settings unless explicitly authorized to remove them.

Candidate comparison at #103: 120 commits ahead, one behind main, 231 changed paths according to GitHub compare. Not a complete independent review of the cumulative diff. Main's v0.2.3 capture/MIDI/icon reliability changes are visibly present in candidate sources, but exact semantic reconciliation and main integration remain separate gates. Manual release dispatch on non-main is blocked in the candidate workflow. No release workflow invoked. macOS execution of the new verifier requires CI; it has not run here.
