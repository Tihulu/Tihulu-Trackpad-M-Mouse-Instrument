# Musician-first UX — implementation and acceptance

This is the first UX increment, stacked on PR #24. It is not the full Universal Instrument Studio.

## Design principles
- Play first: a single Performance overview with real session state, explicit Open/Stop, no automatic instrument starts. Configure on a dedicated page. Group navigation by Workspace, Play, Compose, Sound and Support.
- Keep the universal transport visible: tempo with tap input, playback stop (not global stop), independent session stop, explicit Panic, actual capture state. Hide optional capture controls when space is needed, never hide panic. No fake connection indicators.
- Preserve musicians' work: a single workspace window owns all editor drafts for voice, touch, helper and note/drum patterns across navigation. UI preview subscriptions end when leaving a page while running sessions persist. Closing/relaunching the application is not yet a project save; no automatic performance resume.
- Separate primary controls and live instrument surface from advanced configuration. All 16 drum steps visible in four beat groups, with accessibility labels. Use text and status shape as well as color. Do not render decorative animations in real-time callback paths.
- Future: actual editable reusable instrument presets, setup/perform split with fullscreen performance, visible note/channel ownership, MIDI Learn, undo/redo, tempo clock and playhead, device capabilities, per-device latency, patch builder and responsive phone interface. Branding: approved static PNGs and ICNS remain a separate integration gate.

## Acceptance
1. Create a non-default Touch Instrument assignment (surface, root, scale, output and sustain). Start, navigate to another mode, then return. Values and live routing are unchanged; no second start is required.
2. Configure MIDI Helper on the other surface; switch to note/drum patterns, back to Helper. Both sessions remain active; stop one from Performance without stopping the other. Leaving idle editor previews and then stopping a background session must stop monitoring when no consumer remains.
3. Edit voice text and a non-default note/drum pattern; navigate away and return. Draft stays intact. Confirm no unexpected notes on navigation or return.
4. Test 120 BPM taps, reset after long pause, invalid tempo input; verify pattern timing. Verify all 16 drum steps fit default window, readable at minimum size and with accessibility settings. Preserve sequencer audio.
5. Verify Panic, capture shortcut and independent Stop while another app has focus (physical Mac). Verify system audio stop reachable from Performance and toolbar. No hardware PASS from CI.
6. Verify no idle camera/mic/remote features, no fake status, no forced reconnect. Profile load with two surfaces. Check VoiceOver, keyboard focus and native window resizing.
7. Follow-up: inspect known master-level behavior for live sessions, capture state, audio scheduling and source ownership before adding full performance scene switching.

## Next UX increment
Implement a shared versioned preset/project model and explicit Edit vs Play state. Add guided quick-start templates: solo haptic, Logic instrument, Trackpad + Mouse Helper, Touch Bar expression, camera and remote only after their actual engines exist. Build mobile with the same layout and mapping schema. Add accessible contrast, per-surface input preview, mapping confidence/calibration, no-hardware fallback and explicit resource conflicts.

## Cross-device extension quality gate
The [Expressive Controls plan](EXPRESSIVE_CONTROLS_PLAN.md#musician-first-anti-slop-gate-binding-for-all-subsequent-increments) defines the shared catalog, performance/edit separation, physically playable presets and end-to-end acceptance. Creative scope is preserved. No duplicate engine, per-effect sidebar proliferation, unsupported sensor claims or inert controls. Apply the same gate to AI, mobile, camera, Lab and Builder: feature usefulness and complete workflows over feature count. Experimental features are explicit, optional and isolated until validated.
