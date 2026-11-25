# Independent group MPE — injected-sink candidate

## Evidence and boundary

Base: 6d73713e615cabd399ef3f2df2250871ac0f8e89, 502/502 shared-core tests in run 45604501205; native jobs pending at review. Earlier Studio Xbox-only integration passed native CI 45600781080. SDK #166 passed both platforms. This candidate is not connected to the Studio Start button or native port host. The existing standard-MIDI group path and legacy application settings are unchanged. No stable release, install, merge or physical activation.

## Model

PerformanceGroupTuningPlan accepts an explicit dictionary of group UUID to CustomScale/root specifications. A specification is separate from the saved profile in this slice, so older archives cannot silently activate tuning. Each tuned group must have a dedicated independent endpoint, one logical channel, 1–15 distinct mapped pitches and a valid microtonal scale. The note must be a member of that scale, without approximate fallback. The scale representation remains the existing octave-repeating pitch class model (offsets up to 49 cents); arbitrary tuning systems and quarter-tone ties remain outside it. The plan rejects unknown groups, endpoint identity collisions, unsupported master CCs, reserved setup selectors and noncentered master bend release. CC7/11 require explicit release values.

A fixed member channel for each logical note is allocated for the entire session. Each group independently uses a lower MPE zone, master channel 1 and member channels 2–16. The port is part of every command address. Master effects are translated to channel 1; note-on/off translate to the same member. Standard groups retain their configured channels and separate ports. The existing TunedMIDIClip.setup and CustomScale.mpePitch calculate setup and bends. This does not expand the 15-note per-group fixed pitch capacity or prove DAW MPE behavior.

## Setup and teardown

PerformanceGroupTunedDelivery wraps existing PerformanceGroupDelivery and its output ledger with an explicit one-shot prepare phase. No connect/frame is admitted before setup succeeds on every tuned port. If setup fails, admission is terminal; do not retry setup on the same state or fall back to nominal pitches. MIDISelectorCleanup records incomplete RPN selectors before attempting sends, attempts nulling on the same port, and retains debt if nulling fails. It does not reverse already-applied receiver configuration. Standard sibling groups are intentionally not admitted until all setup succeeds. After successful setup, a musical send fault retires only the affected group using existing ledger behavior. Cleanup translates logical notes to their original member channels. Member tuning is not reset during stop (release tails may still sound). Global Panic retires the session and retries selector cleanup.

The public pendingCleanup property includes both note/control and RPN selector debt. The musical Report's accepted count excludes selector-only sends. Its pendingCleanup now includes selector debt; the authoritative close gate remains the session's combined pendingCleanup. Any future native host must retain this object and the exact port mapping until combined debt is cleared. Setup requires explicit user activation and validated endpoint identity; no automatic registration or hardware access is introduced here. Existing live source watchdog deadlines must be preserved by the future adapter. No host should call this low-level injected-sink API directly from untrusted remote frames.

## New regression coverage

Five tests: independent group tuning and stable member mapping; strict capacity/scale/channel/CC rejection; setup gate and scoped stop/panic; partial setup failure and same-port selector debt; failed note-off retry on the original member. All five initial tests passed in shared-core run 45605963249 (507/507). No physical DAW sound or MPE receiver acceptance claimed.

Next gate: verify exact core/native builds, integrate the plan into the existing local adapter rather than creating a competing owner, define versioned profile tuning persistence with explicit migration and no fallback, expose accurate per-group DAW setup and test with a real MPE receiver. Mixed standard/MPE, endpoint replacement, cleanup failure and legacy regression must pass before enabling the UI.


## Shared local session and versioned configuration follow-up

The local session now selects the existing standard or tuned delivery implementation at construction, sharing all source admission, neutral rearm, camera tracking, frozen tokens and 350 ms watchdog/batch expiry logic. No second physical input owner is created. A tuned session rejects binding before explicit prepare. The native host accepts a nonempty tuning dictionary only through explicit startGamepads, registers independent ports, prepares all zones and retains the session even after partial setup failure so selector debt cannot be lost. No fallback. Retained tuned ports must be explicitly closed before another session; tuned start also requires no retained standard ports. Closing is blocked until musical/selector debt is cleared. DAW software may retain MPE/RPN state even after a port closes; reload/reset the receiving instrument and verify the correct zone before changing modes. No claim that closing rolls back receiver settings.

The separate PerformanceGroupTuningConfiguration document is bounded, versioned and has a distinct format identity from the legacy group archive. It validates the tuning plan and binds it to exact group UUIDs and patches; display-name changes and reorder preserve tuning, whereas changed mappings or group membership require explicit review. Unknown groups, duplicate entries, incompatible versions and stale mappings fail instead of silently becoming standard MIDI. No existing preference key or archive is overwritten. This is a core persistence API, not yet a Studio save/load feature.

Four further regressions authored: local tuned setup gate and mixed standard sibling with existing watchdog; selector failure and combined cleanup; archive rename/reorder and stale mapping; malformed versions/duplicate IDs/legacy format. Native host and archive changes are pending exact CI at time of writing. Studio Start still selects standard MIDI only; the explicit tuned UI, accurate physical channel DAW display and physical MPE receiver acceptance are remaining gates. No stable changes or physical activation.

## Offline editor and guarded Studio Start candidate

The offline editor imports and exports a separate bounded tuning document, allows explicit root-relative cent editing, and previews actual one-based MIDI wire channels from the same plan used by delivery. It does not persist or change the ordinary group profile. Edited text must be applied before export or Start. Invalid import or invalid apply preserves the previous configuration; changing mappings invalidates matching rather than silently reverting to standard MIDI.

The Studio Start path now has a pure PerformanceGroupActivationPlan check before hardware side effects, reuses the existing native host, source owner and unchanged 350 ms watchdog, and freezes the requested tuning document through port retirement. Standard MIDI is labeled separately. Tuned Start requires a matching saved profile, explicit confirmation, shared-input consent where needed, no retained ports and no cleanup/disposal debt. Failed setup does not fall back. Retained tuned ports must be closed before either mode can restart, and cleanup retries retain the original port identity. A close does not reverse receiver RPN or bend state. DAW guidance uses the frozen actual channel projection instead of logical channels.

**Default-off gate:** TIHULU_GROUP_MPE_LIVE is not defined in the package, CI or ordinary build. Only a separately authorized experimental acceptance build may define it. This is a candidate integration, not a claim of native or physical readiness. Do not activate it in the stable application or enable it in a release. Native compile, actual source ownership, receiver zone configuration, tuning and bend behavior remain acceptance gates. The fixed 15 distinct mapped-note limit and existing scale model are unchanged.

Added two activation regression functions for missing confirmation, stale mapping, retained ports, cleanup/disposal debt, standard-mode selection and layering consent. New exact-head CI is pending at authoring.

### Physical acceptance checklist for an authorized isolated candidate

1. With standard and two differently tuned groups, verify distinct port identities and correct master/member channels in an MPE-capable DAW instrument; verify receiver bend ranges and actual pitches independently. Do not claim acceptance from registration.
2. Start with held Xbox buttons and touching surfaces: no note before neutral. Test shared sustain, master pitch bend, scoped Stop, loss, 350 ms watchdog and global Panic; standard sibling and other tuned group must remain isolated except on global Stop.
3. Stop with sustained/releasing notes; verify explicit close before retune or standard restart. Reset/reload receiving instruments as required. Failed Note Off or selector cleanup must keep original port and refuse close until retry succeeds.
4. Test camera permission and controller disconnect, stale/changed profile, stale confirmation, active editor lock and DAW preview accuracy after view departure/reopen. Verify normal Builder and legacy Standard MIDI behavior after clean close.
5. Verify app identity and stable settings unchanged; report native build and physical test results separately. Dynamic channel allocation, mobile groups, haptics and measured latency remain open.
