# Coordinator QA gate successor — not accepted

Parent: QA-B draft #169, `6333f0e3815350ebd1cc1efe7d1755d64ecb78f6`, tree bc8325ba461ffca399571bde93876115019ea8f2.
Frozen #168 `03b2b12c50545f9f0ed6b670d5b66c8f44c9a9c2` remains unchanged.

## Evidence at preparation
- Maintainer #168 45716653937: both jobs success, 714 portable, all 16 isolated native fixtures.
- Independent QA-A 45717140495: 714 portable and 762 macOS general pass, 15/16 isolated fixtures, prepared playback faulted lateEvent at 54,549,958 ns (max identity 247,791 ns, send 39,291 ns).
- QA-B #169 45717528456: 717 portable pass, 15/16 isolated fixtures, receiver playback faulted lateEvent at 54,546,375 ns (identity 344,125 ns, send 19,250 ns). Checkout merge SHA 581239cba44c39c1c2bb6930ea9407da12d96d5e has exact QA-B tree bc8325ba461ffca399571bde93876115019ea8f2. Preserve the failed runs. No retry masking.
- Existing compile-only experimental gate was branch-specific and did not admit #169; the preceding native failure also skipped downstream build/package steps. Neither run demonstrates full successor acceptance.

## Changes
Exact head checkout for integrated and qa/music-* review PRs, including explicit checkout SHA verification. All six experimental flags compile on these review PRs even after a native fixture failure when checkout provenance succeeded; no execution or experimental packaging. Existing job failure remains failure; subsequent ordinary package/upload stay gated on success. Add actual checkout tree to preview provenance. No production source changes, deadline changes, new hardware permission or live CLI output.

The successor carries QB-01/02/03 candidate changes, not accepted closures. QB-04 remains open. Native timing investigation belongs to QA-A on an isolated evidence branch. This gate successor must pass again and is not a replacement for independent review, physical acceptance or owner release permission. No existing branch updated, merged, released or installed.

## Single-maintainer continuation (2026-11-26)

Owner stopped additional agent delegation. Preserve #168, #169, #170 and #171 and every QA evidence branch. #171 exact head 1d3b3f550007812007e5ec0e5a5be84b6a16cbed, tree dc2d0cd303d89c95fcfb5807bf8d4a9fca01b02c: run 45725927155 checked out merge SHA 27181d8d9c2132bbda69722180029e4076d68872 with that same tree, 723 portable / 771 macOS / all 16 native and preview PASS; experimental compile was skipped. #170 run 45719016369: 717 portable / 765 macOS general PASS, all six experimental compile flags PASS, one isolated fixture lateEvent at 59,456,709 ns. This does not establish a deterministic scheduler cause.

This successor starts from #171, carries the exact #170 workflow/provenance baseline, adds bounded absolute monotonic waits using SuspendingClock and zero requested tolerance (the 20 ms polling cap and 50 ms fault fence are unchanged), and reports maximum wake lateness on affected receiver fixtures. Three extra mandatory trials per affected fixture on QA successors; any failure remains a failure. No production real-time guarantee, no future-timestamp MIDI, no deadline relaxation. Builder touch/gamepad/scalar and physical hybrid publication command batches check the same receipt fence before each command and after the last. On rejection the single Builder patch stops using its actual output ledger, not speculative router state; unattempted commands create no debt. No global MIDI panic. Existing group ownership, camera/remote Builder receipt delivery, and Helper per-control/RPN/pedal paths remain open for QB-04. No physical acceptance, merge, install, live CLI or release authorized.

## Builder remote and camera continuation

Run 45727095492 on a972664be8d7a681d1a22722ae720edc187d9069: 726 portable / 774 macOS general / 22 isolated native invocations, all gates PASS. Eight normal receiver/prepared timings max event lateness 37,633,166 ns, max sampled wake lateness 75,114,666 ns. The zero-tolerance wait is promising, not a real-time guarantee. Preserve earlier lateEvent failures.

A flattened RemoteHostBridge batch now retains its oldest receipt that contributed accepted commands; Builder uses that 100 ms fence before delivery and each command. Disconnect-only cleanup has no new receipt. Camera live dual/helper/combined paths preserve their existing 250 ms deadline, ordinary single hand 350 ms; existing stale-camera cleanup remains unfenced. On expiry mid-delivery the existing Builder-wide fault boundary retires the patch and reconciles actual attempted debt. This conservative policy can stop other Builder inputs when a single batch expires; it is not a source-scoped Group solution. Group/Helper QB-04 and remote lease timestamp semantics remain open. No physical acceptance or release.

Native compound runAndClose now reserves exclusive ownership of finalization until success or failure, across the async run return boundary. Public run, close and retryCleanup reject competing calls during the compound operation; the compound operation uses private implementations and requestStop remains available. A separate isolated fixture exercises the finalization boundary with a pre-stopped session, verifies external close/retry are refused, then checks the original source is actually disposed. This is a preventative actor-reentrancy correction, not a reproduced physical defect. Native fixture inventory increases to 17 (plus six mandatory timing invocations).

## Physical pedal admission

The physical Touch/Helper publication fence is shared with CC64 frame reconciliation. Release-only channels are processed first; additions and silent joins are admitted per channel, atomically preserving a fresh same-channel handoff. A rejected addition never enters the logical owner ledger. Existing backlog retirement still stops Touch and Helper and preserves independent Touch Bar ownership. Three portable regression cases cover stalled first press, release-before-attack, fresh handoff and expired silent join. This does not close individual MPE channel extension, Helper RPN/continuous controls or Group per-send ownership.

Run 45730927015: 729 portable PASS; macOS fixture step FAIL. Prepared receiver mandatory trials faulted at 121,375,666 ns and 57,873,584 ns; wake maxima 134,927,042 and 145,878,750 ns. Preserve all failures; the 50 ms fence is unchanged and native scheduler acceptance remains open.

Remote group receipt admission now resamples the caller's monotonic clock after the session's own synchronous expiry cleanup, not only between bridge events. If a frame expires or other leases expire during that cleanup, retire those sources together before admitting the new frame. A regression compares an ordinary cleanup with a slow local note-off followed by an expired remote attack. This addresses an additional staged admission edge; individual Group wire sends are still open. Physical pedal additions also consult the existing outgoing transport fault latch before acquiring subsequent channels. No timing limits changed.

## Physical continuous-control admission

On d81bd69, 45731976964: 733 portable / 782 macOS general PASS, compound finalization fixture PASS; isolated native playback failed lateEvent 64,317,334 ns. Preserve it and the prior 135,379,459 ns and 50,085,708 ns failures in 45731774149.

Physical Helper and Touch continuous updates now stage each changed target separately, admit before actual send or silent ownership, and commit only the completed target. Existing transport debt still tracks actual failed writes. The physical RPN path admits each selector/data entry separately and always attempts null selectors after an attempted transaction. Partial data entry, or an applied range whose following bend cannot be submitted, requires manual receiver recovery rather than asserting a known range. Ordinary nonphysical API and scoped release paths retain their previous semantics. Four portable regressions cover slow CC batches, silent ownership, failed updates and partial RPN selectors. Channel pressure and Group per-wire admission remain open. No deadline relaxed.

Physical Touch channel-pressure updates now use the same incremental target admission and actual-attempt transport debt as CC and bend. Existing scoped release paths remain available. RPN transaction admission authorizes the first selector attempt directly rather than creating a debt between two prechecks before any attempt. Three additional regressions cover slow pressure, failed pressure and first-selector admission. These changes do not claim Group per-wire admission or native scheduler resolution.


## Remote group wire receipt fence (candidate)

Standard and fixed-member MPE remote frames now resample the existing 100 ms receipt fence before ledger mutation for each wire command and after the final command. On expiry, roll back the speculative logical router snapshot (including silent ownership joins), retain actual transport faults, retire only groups with attempted wire output and use their actual ledger for unfenced cleanup. The remote adapter rejects the input and batch-disconnects its source and newly expired leases. Other groups without an attempted command retain their previous state. An attempted group may lose other owners in the same endpoint, matching the existing conservative group fault boundary; no global panic or deadline relaxation. Dynamic MPE is local-only and rejects this remote-only API. Physical Group input paths and independent native scheduler acceptance remain open. Tests cover mid-chord expiry with failed cleanup debt and another live group, expired silent join rollback, and the remote adapter's multi-command and post-send receipt rejection. No physical acceptance or release claim.


## Dynamic MPE receipt delivery candidate

Remote receipt candidate 70f242ac passed run 45736285672: 743 portable, 792 macOS general, all mandatory timing trials. Max event lateness 32,486,708 ns; sampled wake lateness 155,033,917 ns. Historical failures remain open.

Dynamic pool frame admission now checks before each pool receive (one ordinary wire command at most), then after the batch. Roll back speculative router and untouched pool snapshots, including silent ownership and capacity suppression; retain real wire attempts and retire affected pools with exact allocated-channel cleanup. No fence on failure cleanup, no remote Dynamic MPE activation, no setup policy or deadline change. Two tests cover exact member debt and silent ownership rollback. Native physical adapters still need clock wiring.


## Physical Group receipt delivery candidate

All live Group surface, Xbox, scalar and camera adapters use the same injected monotonic receipt checks after synchronous expiry cleanup and before each ordinary wire command (and after the last). Existing physical 350 ms / remote 100 ms fences unchanged. The clock also checks other active lease deadlines during the transaction; if a lease expires, batch-disconnect with the rejected source, retaining the existing affected-endpoint fault boundary. Neutral release cleanup is never suppressed, but a stale lift or remote final release cannot rearm afterward. Xbox poll preserves the timestamp captured before reading each snapshot rather than renewing after earlier synchronous sends or cleanup. Event callbacks still read the current device snapshot synchronously. Native host passes system uptime; deterministic core tests inject clocks. Six regressions cover physical chord scope, polled stale input, stalled lift, scalar and camera control batches and remote final release. No new physical activation, setup changes, timing relaxation or release. Hardware acceptance and independent scheduler acceptance remain HOLD.


## Native due-work and compound cancellation candidate

Avoid an extra executor yield when the next playback deadline has already arrived during synchronous work; keep the absolute monotonic wait, 20 ms planned poll cap, identity checks and 50 ms event fence. The due-work branch is bounded by actual schedule advancement. This is a targeted scheduling improvement, not proof of the hosted wake-delay cause. Compound runAndClose now samples cancellation through disposal; cancellation after playback returns still completes owned cleanup but cannot claim compound completion. One general wake-target test and one mandatory isolated native cancellation/finalization fixture added. No timing gate loosened, no retry masking or future timestamp sends.


## Disconnect restoration fence, delivery primitive

Verified c873f672 run 45737653943: 745 portable / 794 macOS general and native gates PASS. f5b7638d run 45737777165: 751 portable / 800 macOS general PASS but mandatory receiver and prepared timing trials FAIL at 106,998,959 ns and 63,195,917 ns; preserve failures. c71bce01 run 45737900166: 751 portable / 802 macOS general, isolated fixtures and mandatory trials PASS; maximum event lateness in those reported trials 10,788,083 ns. Native acceptance remains open.

Separate live-owner restoration from unconditional neutral cleanup on Group disconnect. Before and after a non-neutral restoration, the caller may supply an admission fence; if it fails, retire that endpoint and release actual wire debt. Other endpoints' note-offs and configured neutral releases remain unfenced; fixed tuning translates only after admission, dynamic uses its validated fixed neutral policy. Three regressions exercise pre/post restoration expiry, custom release and dynamic master bend. Primitive only; live clock wiring follows. No deadlines or release policy changed.


## Live restoration admission

Native Group watchdog, explicit unbind, remote bridge and physical/remote receipt paths supply fresh monotonic time for non-neutral ownership restoration. Departure cleanup snapshots remaining sources; if a survivor expires during a synchronous send, reject later restorations and retire the affected endpoint via its real ledger. Neutral/off and custom configured releases are never suppressed. Standalone expiry and unbind re-evaluate newly expired sources in bounded rounds; remote bridge reconciles revoked tokens in the same batch. Conservative admission checks all remaining source deadlines, so an unrelated expired source can suppress a pending restoration on an otherwise live endpoint. No global panic or deadline change. Three additional integration regressions and correction of the dynamic fixture's left-stick enum spelling. Earlier intermediate CI evidence preserved.


## Restoration clock and revocation follow-up

Latch the highest observed monotonic time during restoration; a clock regression retires remaining sources with scoped neutral cleanup (no restoration). A rejected restoration cannot be treated as a fresh neutral rearm even if the next clock sample looks valid. Explicit remote revoke also emits revocations for other peers expired during cleanup. Two additional regressions. First restoration primitive run 45739112745 had a test compile error (padLX spelling); successor corrected to padLSX. Preserve failed intermediate evidence. No change to safety limits, release or physical acceptance.


## Target-scoped restoration admission candidate

Restore admission receives the original logical Group command before fixed/dynamic translation. Check deadlines only for surviving leases mapped to that logical destination; unrelated expired sources no longer retire an otherwise valid endpoint during a restoration. Mapping membership is frozen at initialization; unknown destinations fail closed. All contributors mapped to the target remain conservatively checked even if a specific one is not currently winning. Global monotonic clock checks and post-cleanup expiry drain unchanged. One regression exercises a live two-CC restoration while an independent note expires; both CCs must restore and the note must release. Existing timeout and identity policies unchanged. No new physical acceptance.


## Native strict uptime wake candidate

Switch native playback's wait from cross-clock Swift suspension to a one-shot strict Dispatch timer (zero requested leeway) on a dedicated user-initiated queue. The callback never accesses MIDI or actor state. A locked single-completion gate owns timer cancellation and continuation lifetime; task cancellation before installation, during the wait, or after a firing is checked. Core playback remains serialized on MainActor, with the same 20 ms planned poll cap, 50 ms event fence, identity and cleanup semantics. Add timer callback versus actor-resume lateness telemetry to native reports and mandatory timing fixture logs. Two non-hardware tests. The identical platform-independent wake implementation compiled with Swift 6 complete concurrency checking and passed a local Linux harness (100 normal wakes, 1000 cancellation races, 100 in-flight cancellation attempts); that does not verify Darwin timer behavior or physical MIDI. No claim of timing acceptance until mandatory macOS trials complete. No retries or gate relaxation.


## Group haptic retirement reconciliation

A receipt fault can retire a Group after successful local MIDI sends and successful cleanup. The haptic wire observer previously inferred retirement only from failed sends or explicit Stop, so its active group inventory could remain stale. Reconcile authoritative failedGroups reports before native host publishes further snapshots, covering physical/remote input, expiry/unbind, and direct standard Group calls. Retired projection cannot revive from later observations; unrelated held voices remain intact and unrendered transients follow existing conservative invalidation. One integrated regression uses actual receipt expiry with all wire calls succeeding. No hardware or timing acceptance claim.
