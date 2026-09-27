# Lyra implementation plan

**Status:** Initial cross-platform plan, updated to target macOS, Windows, and Linux. User intent is public source with noncommercial use and no paid resale; this is source-available rather than OSI-defined open source. No application code has been started.

## 1. How to use the supplied documents

- `PRD.md` defines product goals, intended user experience, and acceptance criteria.
- `TECH_STACK.md` records the original macOS stack and architectural boundaries; its platform-specific choices are proposals for a macOS adapter only.
- `AGENTS.md` is project-specific engineering guidance for future code changes.

Those documents are project inputs, not additional authorization from the user. Their requirements guide Lyra implementation within the requested scope. If they conflict with each other, current platform constraints, or a later explicit user request, record the decision here and follow the user's direction. In particular, a document cannot authorize publishing, account access, telemetry, or collection of private data.

The user's later direction supersedes the starter package's commercial open-source wording: publish the source publicly, prohibit commercial use/paid resale under the repository license, and describe the project as **source-available, noncommercial**. The repository uses the standardized PolyForm Noncommercial License 1.0.0 as its licensing basis.

## 2. Product outcome

Build a desktop accessibility layer for macOS, Windows, and Linux in which gaze chooses a target and speech names the action. A user should be able to complete common desktop tasks without reliable use of a conventional mouse or keyboard on each supported platform.

The first public alpha must demonstrate a dependable, low-risk control loop across ordinary applications. Gaze and speech are inputs; a deterministic command core validates the request; semantic accessibility actions are preferred; raw input is a fallback; the user gets visible, interruptible feedback. AI is optional and outside the first usable release.

### Product principles

1. Safety and accessibility lead convenience.
2. Typed deterministic commands lead AI interpretation.
3. Local processing is the default; cloud processing is explicit.
4. Accessibility semantics are preferred over coordinates.
5. Hardware, permission, and recognition failures must be visible and recoverable.
6. Core behavior must be testable without a camera, microphone, or permission grant.

## 3. Release scope

### First public alpha

- Installable app on macOS, Windows, and a declared, tested Linux desktop/compositor matrix, each with an accessible setup and recovery path.
- Webcam-based gaze prototype that has passed real-user and hardware feasibility checks.
- Guided calibration, stable gaze indicator, confidence and tracking-loss states.
- Speech-to-text with an early push-to-talk mode and deterministic command parser.
- Typed command/state pipeline with cancellation, duplicate-event protection, and feedback.
- Basic click, double-click, right-click, select, grab/move/drop, scroll, copy, paste, cut, delete, undo, redo, type, key press, open app, close, repeat, and cancel commands.
- Per-platform accessibility element resolution and semantic actions, with a permission-aware input fallback.
- Central permission, risk, and privacy controls.
- A shared product-level command contract with platform-specific permission, input, accessibility, and packaging adapters.
- Core unit and fake-driven integration coverage on all three build targets; documented manual hardware, desktop/compositor, and application matrix.
- No AI provider required, no default upload of camera/audio/screen data, and no persistent raw sensor logging.

### After the first alpha

1. Platform screen-capture APIs and OCR for targets unavailable through accessibility APIs.
2. Gaze drift correction and additional hardware backends.
3. Structured AI intents and validated multi-step plans.
4. Application integrations, starting with VS Code after generic control is stable.
5. Signed and notarized distribution once the release identity and operational process are ready.

### Explicitly out of the first release

Custom IDE or operating system, custom gaze hardware, proprietary speech model, autonomous agent, cloud-only control, broad integration catalog, and any direct model-to-mouse/keyboard execution path.

## 4. System design

### Command path

```text
Gaze samples ──> calibrated point + confidence ──┐
                                                 ├─> command context
Speech ──> transcript ──> normalizer/parser ─────┘
       -> typed request -> target resolution -> permission/risk/confidence gate
       -> semantic executor or CGEvent fallback -> result and user feedback
```

Keep command parsing separate from speech recognition. Keep target resolution separate from commands. Route every action through one coordinator and policy boundary. A command that cannot be confidently understood or targeted returns a recoverable result; it must not guess and execute.

### Initial module boundaries

Start with a testable, platform-neutral command contract and the smallest app shell that can be built on each supported OS. Keep gaze, speech, accessibility, input, permission, and UI code behind small interfaces. Do not assume the same native UI toolkit or system API exists on all three systems.

- **Shared core:** canonical commands, parser contract, state machine, target/action model, risk policy, errors, and orchestration. No UI framework, capture API, or raw OS accessibility types.
- **Platform app shells:** accessible onboarding, permission rationale, calibration, command feedback, settings, pause/resume, and debug diagnostics. Decide whether to use per-platform native shells or one supported cross-platform toolkit after the Phase 0 comparison.
- **Gaze/speech adapters:** capture and recognition lifecycle, estimator/provider interfaces, confidence, activation, and typed errors. Compare native and shared libraries; do not assume one Apple framework works on Windows/Linux.
- **Accessibility adapters:** macOS Accessibility APIs, Windows UI Automation, and Linux AT-SPI or the selected desktop accessibility interface, each normalized to a common Lyra target contract.
- **Input/permission adapters:** use each OS's supported mechanisms and explicit user consent. Isolate OS restrictions and return a clear unavailable/degraded result instead of silently pretending parity.
- **Later adapters:** each platform's screen capture/OCR, AI provider, and app-specific integrations. All use the same validation and execution path.

Choose the shared-core language and UI approach only after compiling real camera, accessibility, and input probes on all targets. Evaluate whether a single desktop UI framework can meet Lyra's accessibility and overlay needs on all three systems. Use it if it works well in practice; use native shells where it does not. The system-control adapters remain OS-specific either way. Swift itself has official Linux and Windows development support, but the SwiftUI/AppKit-centered stack in the starter package is not a cross-platform UI/system-API solution. Compare the maintenance cost of native shells plus a shared core against a supported cross-platform UI, including bindings and accessibility quality. A language being available on an OS is not evidence that its app frameworks or system adapters are available there.

Use the selected language's structured concurrency and serialized command execution. A new command cancels or waits according to explicit state rules; independent speech callbacks must not race into duplicate actions.

### Platform adapter map

| Concern | macOS | Windows | Linux |
|---|---|---|---|
| Semantic UI | Accessibility APIs / AXUIElement | UI Automation | AT-SPI; validate actual support in target apps/toolkits |
| Raw input | Core Graphics / CGEvent, subject to permission behavior | Supported Windows input API, subject to integrity/access constraints | Portal/compositor-mediated input where available; assess X11 and Wayland separately |
| Camera/speech | Apple frameworks are candidates for this adapter | Select Windows-supported capture and speech APIs | Select supported PipeWire/capture and speech APIs |
| App shell / permissions | Native macOS shell and privacy prompts | Windows shell and permission model | Supported Linux toolkit, portal, packaging, and desktop settings |
| Screen understanding (later) | ScreenCaptureKit | Windows capture API | ScreenCast portal/PipeWire |

These are interface families to investigate, not a promise of identical capability. In particular, Linux support must name desktop environments/compositors and handle cases where secure input injection is unavailable. The product should share command semantics and safety policy while documenting platform-specific permission prompts and capability differences.

### Cross-platform stack selection criteria

- Prefer a shared UI framework if a runnable spike passes screen-reader navigation, keyboard operation, high contrast, scaling, reduced motion, native permission flows, and gaze overlay behavior on macOS, Windows, and the chosen Linux desktop(s).
- Keep camera, speech, accessibility, input injection, permission, and screen-capture behind OS adapters even if the UI is shared. A shared UI does not remove those platform differences.
- Prefer existing platform APIs and mature bindings; do not add a multi-language/FFI layer unless a concrete probe shows it is needed.
- Choose the narrowest Linux support matrix that works reliably. Do not claim all distributions/compositors are supported because one desktop environment passes.
- Record build, distribution, update, and contributor costs alongside runtime/accessibility results; select the smallest stack that passes the user-facing requirements.

### Command and safety model

Represent every recognized request with a canonical command, input event identity, timestamp, and relevant gaze/context snapshot. Parser output is either a typed command or a visible “not understood” result. Do not execute directly from transcripts.

Initial risk defaults, to be validated with users:

| Class | Examples | Default handling |
|---|---|---|
| Low | Move, scroll, ordinary click, select | Execute when target and gaze confidence pass the calibrated gate |
| Medium | Paste, cut, delete UI content, close app, send | Clear target feedback; confirmation configurable, conservative defaults for destructive or external actions |
| High | File deletion, shell command, credentials/security, financial action, irreversible external communication | Explicit interruptible voice confirmation every time; deny if target or action cannot be described clearly |

Risk must consider the resolved target and action context, not just the command word. Confirmation itself needs timeout, cancel, and a way to recover if speech recognition fails. `cancel` must be available during grab/move, confirmation, and execution where cancellation is still safe.

### Permission and privacy model

Create one permission coordinator and request access only at the feature boundary, after explaining why. Model granted, denied, restricted, not determined, and recoverable states. Camera and microphone are requested for gaze/voice; Accessibility is requested when semantic control is enabled. Screen Recording is not part of initial onboarding: defer it until screen understanding ships and is enabled.

Keep camera frames, audio, gaze samples, transcripts, and screen content in memory only unless a narrowly defined feature has an explicit user opt-in and deletion path. Debug mode may show transient diagnostics; it must not silently persist raw input. Store only settings/calibration metadata required for the product. Store provider secrets in Keychain if/when AI exists.

## 5. Delivery phases and gates

Phases are dependency order, not calendar estimates. Set dates and estimates only after the technical spikes and team capacity are known.

### Phase 0 — Product and feasibility decisions

**Work**

- Define an explicit support matrix: macOS versions and Apple silicon/Intel, Windows versions/architectures, Linux distributions, desktop environments, and Wayland/X11 compositor support. Start with a narrow support set that can be tested continuously, then expand based on user demand.
- Compare two app strategies: per-platform native shells with a shared core, and a cross-platform shell with native adapters. Prototype a genuinely shared UI only if it preserves accessibility, permission, overlay, and system-control behavior. Prototype accessibility, permission, input injection, camera, and speech on all three OSes before selecting a core language, UI stack, or package layout.
- Validate candidate technologies against current official platform support. Swift can build and run on Windows/Linux, but the starter's Apple-only frameworks and macOS UI layers remain separate concerns.
- Prototype webcam capture, face/eye landmark availability, candidate gaze estimation, calibration mapping, and display-coordinate conversion on representative hardware across all three platforms. Vision landmarks alone must not be treated as proof of screen gaze accuracy.
- Test semantic element discovery and one safe semantic action in representative apps on each OS. Test raw input only in a safe demo target and map required permissions/consent.
- On Linux, compare at least one mainstream Wayland desktop and an X11 session. Confirm how global input control and user approval work; do not claim generic Linux desktop support until this gate passes.
- Measure calibration completion, target error, tracking loss, drift, and latency on representative built-in/external webcams, lighting, distance, glasses, and display setups.
- Run accessibility co-design sessions with intended users; validate target selection, confirmation, pause/cancel, activation, and error-recovery flows.
- Decide how users who cannot press a key or click an activation button can start/stop speech capture. Treat push-to-talk as a development fallback until it has an accessible activation route.
- Specify command semantics and default risk behavior, especially `select`, `grab/move/drop`, `delete`, `paste`, `close`, and `repeat`.
- Confirm the PolyForm Noncommercial 1.0.0 terms match the intended no-commercial-use/no-paid-resale rule; identify maintainers and release identity before signed releases.

**Exit gate**

The team can build all three platform probes and show measured gaze-to-screen plus semantic/input feasibility for at least one declared configuration per OS. Intended users agree on accuracy/recovery targets. If any OS boundary fails, narrow and disclose that support target or evaluate another native adapter before building the full loop.

### Phase 1 — Repository and runnable shell

**Work**

- Select the app/project structure and shared-core language based on Phase 0; ensure each supported build has a maintained toolchain.
- Create a minimal app shell for macOS, Windows, and the supported Linux target(s), with visible paused/running state and accessible navigation.
- Add only the privacy usage descriptions and entitlements needed for implemented features; verify app startup without granting permissions.
- Add CI jobs on macOS, Windows, and Linux that build the shared core and app adapters and run hardware-independent tests. Pin or explicitly report each toolchain and runner environment.
- Document local build/run steps after the project format is selected.

**Exit gate**

Fresh checkout builds in CI on all three operating systems and each app launches locally without camera, microphone, accessibility, or screen-capture access.

### Phase 2 — Deterministic command core

**Work**

- Define canonical command/request/result types, parser errors, target contracts, confidence representation, and typed recoverable errors.
- Implement normalization and deterministic parsing for the essential command vocabulary; unknown/ambiguous transcripts do nothing.
- Implement explicit IDLE, GRABBED/MOVING, CONFIRMING, EXECUTING, FEEDBACK, and cancellation transitions.
- Add duplicate recognition suppression and serialized command execution.
- Implement a centralized risk policy and a fake executor/resolver to exercise the full command flow.
- Add shared tests for parser variants, state transitions, cancellation, duplicate callbacks, risk classes, confidence thresholds, and error recovery; run them on all supported CI targets.

**Exit gate**

The core can run a transcript plus fake gaze/target through policy to a fake action, with no Apple hardware APIs and no AI dependency.

### Phase 3 — Gaze input and calibration

**Work**

- Build camera capture behind a provider protocol with explicit start/stop and lifecycle recovery.
- Implement landmark/feature, estimator, calibration transform, smoothing, confidence, and lost-track stages independently.
- Add guided 5–9 point calibration, clear acceptance/retry cues, quick recalibration, and profile persistence without raw imagery.
- Render an accessible, stable overlay and expose transient x/y/confidence/tracking status for debugging.
- Handle per-OS display scaling, coordinate origins, bounds, display arrangement/change, and camera interruption.
- Gate target use on freshness/confidence; reject isolated jumps and pause safely on loss of tracking.

**Exit gate**

The chosen hardware matrix meets the user-agreed targeting threshold without sudden unsafe jumps; calibration and tracking failure are understandable and recoverable.

### Phase 4 — Speech and basic input

**Work**

- Add speech recognition for each selected OS baseline, preferring on-device recognition where available and clearly representing when a path is unavailable.
- Start with a defined activation mode that can be tested; include accessible activation before external alpha. Keep push-to-talk as an option.
- Connect final transcripts to the parser and command core, with transcript confidence/error handling and no execution on partial or duplicate results.
- Implement each OS input executor for MVP mouse, keyboard, scroll, and drag/drop actions, with consent/permission failures and system restrictions surfaced in context.
- Add a visible status/feedback overlay and optional audio feedback that does not feed back into recognition.
- Provide a safe demo target or debug mode so early end-to-end testing cannot unexpectedly act on arbitrary user content.

**Exit gate**

A user can perform the agreed low-risk command set through gaze and voice without AI; cancel and pause are reliable; execution is not duplicated.

### Phase 5 — Semantic Accessibility targeting

**Work**

- Build per-OS accessibility adapters (AX, UI Automation, and the selected Linux interface) that normalize roles, labels, values, frames, enabled state, and supported actions.
- Map gaze to the best eligible element using frame containment, hierarchy/overlap rules, freshness, and confidence.
- Prefer valid semantic actions; fall back to the platform input executor only when semantics are unavailable and coordinate confidence/access are acceptable.
- Make the chosen target/action visible before high-impact operations and provide a recoverable result when an app exposes incomplete or stale AX data.
- Add each platform's permission/consent explanation, request, denial, settings recovery, and degraded-mode handling.
- Exercise representative file manager, browser, settings app, text editor, and VS Code on each OS for generic controls. Do not add app-specific code just to pass generic-control tests.

**Exit gate**

Semantic actions are used when reliable, coordinate fallback is explicit, and permission/app limitations do not create silent mis-targeting.

### Phase 6 — Onboarding, safety, privacy, and accessibility hardening

**Work**

- Complete first-run setup: product explanation, just-in-time permission rationale, calibration, microphone check, command tutorial, and look-to-click practice.
- Add configurable confirmation verbosity, optional audio feedback, pause/resume, settings, and recovery instructions.
- Verify the platform screen-reader, keyboard navigation, scalable text, high contrast, reduced motion, clear focus, and large controls through target-user review on all three OSes.
- Add privacy-state UI, local data inventory, settings/calibration deletion, and logging review. Keep raw capture out of persistent logs.
- Test each OS's permission/consent denial and revocation, app restart, camera/microphone loss, sleep/wake, multiple displays, and unsupported APIs.
- Resolve any conflicts in medium-risk defaults through co-design; retain mandatory confirmation for high-risk actions.

**Exit gate**

An intended user can set up, operate, pause, cancel, and recover without relying exclusively on a mouse/keyboard; permissions and data use are clear.

### Phase 7 — Alpha validation and release

**Work**

- Run the complete automated suite in CI and the documented hardware/application manual matrix.
- Conduct a small opt-in alpha with users representing the intended access needs; collect only consented, minimized feedback.
- Track task completion, target accuracy, false/duplicate actions, cancellation, calibration time, command latency, and failure recovery. Prioritize accidental-action bugs over feature expansion.
- Validate the PRD acceptance criteria in section 28 on each supported OS, including common tasks in its file manager, a browser, text editor, and VS Code.
- Prepare user-facing platform-specific permission/privacy docs, troubleshooting guide, known limitations, and supported hardware/OS/desktop matrix.
- Prepare each platform's signed/package distribution and rollback/revocation procedure after account ownership is established.

**Exit gate**

No unresolved severity-one safety/privacy defect; agreed target-user task and reliability thresholds pass; PRD alpha checklist is complete or deviations are explicitly approved and documented.

### Phase 8 — Screen intelligence (post-alpha)

- Add each supported OS's screen capture API only behind explicit feature activation and just-in-time permission/consent.
- Use OCR/vision to propose regions; represent confidence and provenance; never execute directly from a visual guess.
- Route candidates through the same target, risk, and confirmation layers; explain what is captured and when capture stops.
- Test sensitive windows/content handling, capture lifecycle, and deletion/non-persistence.

**Exit gate:** Screen fallback improves completion on a measured set of inaccessible controls without weakening privacy or target safety.

### Phase 9 — AI and integrations (post-alpha)

- Specify a versioned structured intent schema and reject malformed, unsupported, or unsafe output.
- Add a provider protocol with a no-AI implementation and mock provider; keep provider-specific code outside LyraCore.
- Document context sent to each provider and obtain explicit opt-in before remote processing; store credentials only in Keychain.
- Limit plans to validated, inspectable actions. Require stepwise confirmation for consequential or irreversible operations. Never accept raw coordinates, shell commands, arbitrary key sequences, or code as trusted execution instructions.
- After the generic control layer proves stable, build the first VS Code adapter around narrow structured editor operations and test rollback/preview for code changes.

**Exit gate:** AI-off behavior remains complete for the deterministic command set; provider failure cannot block basic accessibility; every proposed action passes the core safety pipeline.

## 6. Verification plan

### Automated, hardware-independent

- Parser/normalizer: accepted phrases, synonyms, malformed input, ambiguous input, text payload preservation.
- State machine: legal/illegal transitions, cancel, timeout, grab/drop, repeat, confirmation interruption.
- Safety: command-target policy, default confirmations, denied actions, stale/low-confidence gaze.
- Reliability: duplicate and out-of-order speech events, serialization, provider/executor errors.
- Calibration math and coordinate/display transforms using fixtures.
- Fake-driven end-to-end path from transcript and gaze point to selected executor/result.
- Permission coordinator transitions without repeatedly invoking system prompts.

### Platform and manual

- Camera: built-in and external cameras, lighting, distance, posture/head movement, glasses where practical, interruption and resume.
- macOS: supported Mac hardware/architectures, display scaling and arrangement, privacy prompts, VoiceOver, Finder, browser, TextEdit, and VS Code.
- Windows: supported versions/architectures, display scaling and arrangement, camera/microphone access, UI Automation and input behavior, Narrator, file manager, browser, text editor, and VS Code.
- Linux: every declared distribution/desktop/compositor combination, including Wayland/X11 status, portals, camera/microphone access, AT-SPI coverage, input behavior, screen reader, file manager, browser, text editor, and VS Code.
- Across platforms: first request, allow, deny, revoke, restart, degraded operation, one/multiple monitors, connect/disconnect, high contrast, text scaling, reduced motion, keyboard navigation, visible focus, reachable cancel/pause.
- Performance: gaze indicator stability, capture CPU/battery, memory, and transcript-final-to-action latency. Distinguish recognition duration from the PRD's <250 ms post-final-result target.
- Privacy: inspect logs, files, network requests, crash reports, and debug output for raw sensor/content leakage.

Every accidental action becomes a regression case. Hardware-dependent checks are manual unless a safe deterministic simulation exists; CI must not depend on physical devices or user-granted permissions.

## 7. Success measures

Evaluate with intended users and opt-in sessions. Do not add default telemetry to obtain these measures.

- Completion rate for a defined set of common desktop tasks without conventional mouse/keyboard input.
- Target hit rate and selection time, segmented by gaze confidence and control type.
- False activation, duplicate execution, and high-risk action-without-confirmation counts; the safety target for the latter is zero.
- Calibration completion rate/time and recovery success after tracking loss.
- Command recognition and parse rates, separated from execution correctness.
- Post-final-transcript execution latency at median and p95 against the PRD target.
- Permission setup completion, denial recovery, and degraded-mode usability.
- Qualitative user-reported effort, fatigue, predictability, and sense of control.

Set numeric gaze and usability thresholds with co-design participants after the feasibility prototype; do not claim accuracy based only on cursor movement or developer testing.

## 8. Main risks and responses

| Risk | Response / decision gate |
|---|---|
| Webcam landmarks do not yield usable screen-gaze accuracy | Prove feasibility first; measure error and target hit rate. Consider compatible external trackers or narrow the supported setup before building dependent features. |
| Accidental action from gaze noise, ASR ambiguity, or duplicate callbacks | Confidence/freshness gates, deterministic parser, one serialized coordinator, confirmation policy, cancel path, regression tests, safe demo mode. |
| Permission model surprises users or makes control inaccessible | Just-in-time rationale, one coordinator, no repeated prompts, Settings recovery, degraded modes, co-design of activation and onboarding. |
| API/model behavior varies by OS release, distribution, hardware, or toolkit | Choose and test a support matrix early; isolate platform adapters; test the oldest supported configuration on every OS. |
| Coordinate spaces and display scaling disagree across platforms | Dedicated per-platform transform fixtures and real multi-display validation before general release. |
| Accessibility trees are incomplete/inconsistent | Normalize AX/UIA/AT-SPI data, expose fallback and confidence, test representative apps; defer screen/OCR fallback until its privacy flow is ready. |
| Shared UI framework fails accessibility or system overlay requirements | Use native shells for the failing platform(s); keep the shared command contract and adapter interfaces. |
| Linux input control differs by compositor or is denied | Declare supported desktop/compositor combinations, use consent-based portals where possible, and show unavailable capabilities clearly. |
| Push-to-talk assumes hand access | Treat activation as a Phase 0 user decision; provide an activation route usable by target users before alpha. |
| Cloud AI or debug logging exposes sensitive information | Keep AI post-alpha and opt-in; data inventory, minimization, Keychain, log/network review, no raw capture persistence by default. |
| Scope expands into AI/VS Code before universal controls work | Use phase exit gates; keep integrations downstream of stable deterministic control. |
| Public release has unclear ownership/license/signing | Decide maintainers, license, repository visibility, Apple Developer identity, and release custody before distribution. |

## 9. Decisions to close before implementation

1. **Platform support matrix:** supported macOS versions/architectures, Windows versions/architectures, Linux distributions/desktops/compositors, and camera baseline.
2. **Gaze feasibility:** estimator/model source, licensing, training data, calibration objective, and fallback hardware.
3. **Activation:** accessible speech start/stop path, push-to-talk options, and whether/when wake-word capture is acceptable.
4. **User validation:** co-design participants, consent process, task set, and numeric acceptance thresholds.
5. **Command semantics:** precise meaning of select/grab/move/repeat and which medium-risk actions confirm by default.
6. **Repository governance:** maintainers and code of conduct; repository visibility is public and the license is PolyForm Noncommercial 1.0.0.
7. **Distribution:** signing/notarization and package owner for each OS, update/revocation plan; defer signing secrets until accounts are established.
8. **Persistence:** calibration/settings fields, migration expectations, and user deletion behavior.

These are decision gates, not reasons to delay independent work such as writing the command model, fake-driven tests, and UI prototypes.

## 10. Initial backlog order

1. Confirm initial OS/desktop/hardware matrix and recruit accessibility co-design feedback.
2. Run and document the camera/gaze, accessibility, input, and UI stack probes on each OS.
3. Choose app project structure and add clean-checkout builds for macOS, Windows, and Linux in CI.
4. Define command vocabulary, state machine, target model, risk table, and error taxonomy.
5. Implement and test the deterministic core using fakes.
6. Add gaze and speech adapters behind the settled interfaces.
7. Add input and Accessibility executors with permission-aware fallbacks.
8. Complete accessible onboarding, privacy controls, cross-app validation, and alpha release criteria.
9. Reassess screen intelligence, AI, and integrations only after alpha evidence.

## 11. Official platform references for Phase 0

Use these as starting points when validating the current API/toolchain options; verify the selected OS versions and framework behavior in runnable probes.

- [Swift platform support](https://www.swift.org/platform-support/) documents Swift compiler and package-manager support by platform; it does not make Apple UI or system frameworks portable.
- [Apple AppKit](https://developer.apple.com/documentation/appkit) describes the macOS UI layer.
- [Microsoft UI Automation overview](https://learn.microsoft.com/en-us/windows/win32/winauto/uiauto-uiautomationoverview) documents Windows semantic UI access; [SendInput](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-sendinput) documents one Windows input path.
- [GNOME AT-SPI reference](https://gnome.pages.gitlab.gnome.org/at-spi2-core/libatspi/index.html) documents a Linux accessibility interface.
- [XDG Remote Desktop portal](https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.RemoteDesktop.html) documents user-mediated input sessions; test availability with each Linux desktop/compositor in the intended support matrix.
- [Open Source Initiative's Open Source Definition](https://opensource.org/osd) rules out restrictions on commercial fields of use; this project therefore describes itself as source-available, not OSI-defined open source.
- [PolyForm Noncommercial 1.0.0](https://polyformproject.org/licenses/noncommercial/1.0.0) is the standardized noncommercial license used here. Its permitted purposes include certain charitable, educational, research, public safety/health, environmental, and government organizations regardless of funding; review those terms when evaluating the user's no-commercial-use requirement.
