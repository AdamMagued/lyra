# Lyra — Product Requirements Document

> **Scope update (2026-09-27):** Lyra targets macOS, Windows, and Linux. This supersedes the macOS-only product scope in the initial engineering package. The user requires public source with commercial use and paid resale prohibited; this is source-available, not OSI-defined open source. See the repository [LICENSE](../LICENSE). Cross-platform requirements and platform decision gates in [the implementation plan](IMPLEMENTATION_PLAN.md) are current; Apple-specific APIs below describe only the macOS adapter unless a later decision says otherwise.

## 1. Product

**Lyra** is a public, source-available desktop accessibility layer for macOS, Windows, and Linux that lets users control their computer with **gaze + voice**. Commercial use and paid resale are prohibited by the repository license. Lyra should use platform-appropriate application, permission, accessibility, and input APIs behind shared product behavior.

### Core interaction model

> **Eyes = WHERE**
> **Voice = WHAT**

The user looks at a target and speaks a command. Lyra resolves the target, interprets the command, validates it, and executes the safest appropriate action through supported operating-system APIs.

Examples:

- Look at a button → “click”
- Look at text → “select”
- Look at a window → “move” → look elsewhere → “drop”
- Look at a text field → “type hello world”
- Look at an item → “copy”
- Look at VS Code → “run”

Lyra is designed as a **computer-wide control layer**, not as a replacement IDE. VS Code is the first high-value developer integration; the long-term product should work across ordinary macOS applications.

---

## 2. Vision

Build an accessibility layer that makes ordinary Mac interfaces operable for people who cannot reliably use a conventional keyboard, mouse, or trackpad.

The long-term loop is:

```text
Gaze + Voice
      ↓
Context + Intent
      ↓
Target Resolution
      ↓
Safety / Validation
      ↓
Action
      ↓
macOS / App
```

Lyra should progressively move from:

1. deterministic gaze + voice commands,
2. to semantic UI understanding,
3. to AI-assisted multi-step workflows,
4. to AI-assisted coding and application-specific control,

without making AI a hard dependency for basic accessibility.

---

## 3. Problem

Conventional desktop interaction assumes reliable access to physical pointing and typing devices. Existing assistive technologies can solve individual pieces of the interaction problem, but Lyra aims to combine gaze, voice, application semantics, and safe computer control into one coherent layer.

The central product insight is **not** “eye tracking as a mouse.” It is:

> **Gaze identifies the target; voice specifies the action.**

This makes commands expressive while reducing the need for precise physical input.

---

## 4. Goals

### MVP goals

Lyra must:

1. Run as an installable desktop application on macOS, Windows, and Linux.
2. Obtain explicit camera, microphone, Accessibility, and Screen Recording permissions only when needed.
3. Calibrate gaze to a screen coordinate system.
4. Display a stable gaze indicator.
5. Convert speech into deterministic commands.
6. Resolve the gaze target using coordinates and, when possible, the macOS Accessibility tree.
7. Execute basic computer actions without requiring an LLM on every supported platform.
8. Provide immediate visual feedback and optional audio confirmation.
9. Include an explicit safety model for destructive/high-risk actions.
10. Keep the base interaction path local and privacy-first where practical on every supported platform.
11. Work across applications without modifying them.
12. Provide a debug/telemetry view for development without collecting user data by default.

### Post-MVP goals

1. Screen-content/OCR fallback for weakly accessible applications.
2. Better gaze calibration and drift correction.
3. Application-aware integrations, starting with VS Code.
4. Natural-language intent parsing via pluggable AI providers.
5. Multi-step action planning with validation and confirmations.
6. AI-assisted coding and semantic code manipulation.
7. Plugin/integration APIs for additional applications.

---

## 5. Non-goals for MVP

Do not build these first:

- A custom IDE.
- A VS Code fork.
- A custom operating system.
- A fully autonomous computer agent.
- A proprietary speech model from scratch.
- A proprietary eye-tracking hardware device.
- Dozens of application-specific adapters.
- Cloud-only speech or gaze processing.
- An LLM-controlled raw mouse/keyboard loop.

---

## 6. Target users

### Primary

People with motor disabilities who can reliably use some combination of visual attention and speech but cannot reliably use conventional mouse/keyboard input.

### Secondary

- Users with temporary motor limitations.
- Hands-busy users.
- Accessibility researchers.
- Developers experimenting with multimodal computer interaction.
- Community contributors building assistive technology.

The product must never assume a user's physical capabilities beyond what they explicitly configure.

---

## 7. MVP user experience

### 7.1 First-run onboarding

The onboarding flow should:

1. Explain Lyra in one sentence.
2. Explain each permission before requesting it.
3. Run a short gaze calibration.
4. Offer a microphone test.
5. Run a short command tutorial.
6. Let the user test “look → click.”
7. Let the user configure confirmation verbosity.
8. Keep all configuration reversible.

### 7.2 Core interaction

The default interaction flow is:

```text
User looks at target
        ↓
Lyra estimates gaze
        ↓
Target becomes visually indicated
        ↓
User speaks command
        ↓
Speech → typed command
        ↓
Command parser → typed intent
        ↓
Target resolver
        ↓
Risk / permission validation
        ↓
Execute
        ↓
Feedback
```

### 7.3 Essential commands

MVP command vocabulary:

- click
- double click
- right click
- select
- grab
- drop
- move
- drag
- scroll up
- scroll down
- copy
- paste
- cut
- delete
- undo
- redo
- type `<text>`
- press `<key>`
- open `<application>`
- close
- cancel
- repeat

Synonyms may be added, but they must normalize into the same deterministic command types.

---

## 8. Interaction state machine

Basic actions must be explicit and deterministic.

```text
IDLE
 │
 ├─ command(targeted action) ─→ EXECUTING
 │
 ├─ grab ─→ GRABBED
 │             │
 │             ├─ gaze moves ─→ MOVING
 │             └─ drop ────────→ EXECUTING
 │
 └─ cancel ─→ IDLE

EXECUTING ─→ FEEDBACK ─→ IDLE
```

The system must avoid ambiguous state whenever possible.

### Safety rule

If a command is destructive, privacy-sensitive, or externally consequential, the state machine must require a confirmation according to the configured risk policy.

---

## 9. Gaze subsystem

### 9.1 Input pipeline

```text
Camera frames
   ↓
Face/eye landmarks
   ↓
Gaze estimation
   ↓
Calibration mapping
   ↓
Noise filtering
   ↓
Confidence estimation
   ↓
Screen coordinate
```

### 9.2 Requirements

- Support built-in webcams where usable.
- Isolate gaze estimation behind a protocol so dedicated eye trackers can be added later.
- Expose confidence with every gaze sample.
- Support calibration profiles.
- Detect when the user's face/eyes are not trackable.
- Avoid sudden cursor jumps from isolated bad samples.
- Support configurable smoothing/latency tradeoffs.

### 9.3 Gaze data contract

```swift
struct GazePoint {
    let screenPoint: CGPoint
    let confidence: Double
    let timestamp: ContinuousClock.Instant
}
```

### 9.4 Calibration

MVP target:

- 5–9 point guided calibration.
- Under ~30 seconds for a normal session.
- Clear indication when a point has been accepted.
- Ability to recalibrate quickly.
- Ability to store multiple profiles later.

### 9.5 Drift

The system must treat gaze as probabilistic input, not pixel-perfect truth. Drift correction should be incremental and never silently produce large control jumps.

---

## 10. Voice subsystem

### Pipeline

```text
Microphone
   ↓
Speech recognizer
   ↓
Transcript
   ↓
Normalizer
   ↓
Deterministic command parser
   ↓
LyraCommand
```

### Requirements

- Prefer on-device speech recognition where available.
- Provide push-to-talk during early development as a reliable fallback.
- Support a wake/activation strategy later.
- Show the recognized transcript for debugging and optional user feedback.
- Separate speech recognition from command interpretation.
- Never let an unvalidated transcript directly execute arbitrary computer input.

---

## 11. Command model

All actions pass through a typed command representation.

Example:

```swift
enum LyraCommand {
    case click
    case doubleClick
    case rightClick
    case select
    case grab
    case drop
    case scroll(direction: ScrollDirection)
    case copy
    case paste
    case cut
    case delete
    case undo
    case redo
    case type(text: String)
    case press(key: Key)
    case openApplication(name: String)
    case closeApplication
    case cancel
    case repeatLast
}
```

The parser may accept natural variants, but the output must be canonical.

Example:

```text
"double click that"
"double-click"
"double click"
        ↓
.doubleClick
```

The command itself should not contain arbitrary screen coordinates unless the executor explicitly requires them. Target resolution should remain a separate concern.

---

## 12. Target resolution

Lyra should use a priority order:

### Tier 1 — Accessibility semantics

When possible, map gaze to a macOS accessibility element.

Examples:

- AXButton
- AXTextField
- AXWindow
- AXMenuItem
- AXStaticText

If a valid accessibility action exists, prefer it over a raw mouse event.

### Tier 2 — Screen coordinate

If no useful accessibility target exists, use the gaze coordinate with CGEvent-level input.

### Tier 3 — Screen intelligence

Later, use screen capture, OCR, and visual analysis to identify targets that cannot be resolved through the accessibility tree.

### Target contract

```swift
struct Target {
    enum Kind {
        case accessibilityElement
        case screenRegion
        case point
    }

    let kind: Kind
    let confidence: Double
}
```

---

## 13. Computer control

Lyra needs two distinct execution paths.

### Semantic execution

```text
AXUIElement → perform accessibility action
```

Use when the target exposes an appropriate semantic action.

### Physical input emulation

```text
CGEvent → mouse / keyboard event
```

Use as the universal fallback.

The two paths must be exposed behind a common executor interface so higher layers do not care which implementation is used.

---

## 14. Screen understanding

This is not required for the first MVP.

Later pipeline:

```text
ScreenCaptureKit
      ↓
Captured frame
      ↓
OCR / vision
      ↓
Candidate regions
      ↓
Target resolver
```

Screen understanding should be selectively activated because screen contents can contain sensitive information.

---

## 15. AI architecture

AI is a separate layer above the deterministic control plane.

### Correct architecture

```text
Voice / Context
      ↓
AI intent parser / planner
      ↓
Structured intent
      ↓
Schema validation
      ↓
Risk policy
      ↓
Target resolution
      ↓
Executor
```

### Incorrect architecture

```text
User → LLM → arbitrary mouse/keyboard actions
```

AI must never directly control raw computer events.

### AI provider abstraction

Implement a provider protocol so users can choose among:

- local models where practical,
- remote API providers,
- future providers,
- no AI.

Base Lyra functionality must work with **no AI provider configured**.

---

## 16. VS Code integration — first AI-heavy integration

VS Code is a first-class integration target after the universal control layer is stable.

Potential commands:

- “open this file”
- “find the authentication function”
- “select this block”
- “delete this line”
- “move this block down”
- “run”
- “open terminal”
- “create a function called calculateAverage”
- “add a parameter called numbers”
- “make it return the average”

AI-generated code should be represented as structured operations where possible. Any generated changes should be validated before execution or insertion.

---

## 17. Safety

Lyra controls a user's computer. Safety is a product requirement, not a later feature.

### Risk levels

**Low**

- move cursor
- scroll
- click
- select

**Medium**

- paste
- delete UI content
- close application
- send a message

**High**

- file deletion
- shell commands
- credential/security changes
- financial actions
- external communications with irreversible consequences

High-risk operations require confirmation by default.

### Confirmation UX

Example:

```text
Delete “project.zip”?

Say “confirm” or “cancel”.
```

The confirmation system must be interruptible by voice.

---

## 18. Privacy

Principles:

1. Process gaze locally by default.
2. Process speech locally where practical.
3. Never upload camera frames by default.
4. Never upload screen contents by default.
5. AI/cloud access must be explicit and configurable.
6. Explain what information an AI provider receives.
7. Keep logs off by default for sensitive raw data.
8. Make debugging data easy to disable and delete.

The app should communicate privacy state clearly.

---

## 19. Accessibility requirements

Lyra itself must be accessible.

Its UI must support:

- keyboard navigation
- VoiceOver
- Dynamic Type / scalable text
- high contrast
- reduced motion
- clear focus indicators
- minimal hidden state
- configurable dwell times
- configurable voice confirmations

Do not design the onboarding exclusively for users who can operate a mouse.

---

## 20. Feedback

Every action should provide clear feedback.

### Visual

A lightweight status overlay may show:

```text
Target: Run button
Command: click
Status: ✓
```

### Audio

Optional voice feedback such as:

> “Clicked.”

Audio feedback must be configurable because spoken confirmations can interfere with speech recognition.

---

## 21. Architecture

Recommended top-level architecture:

```text
                    LYRA APP
                       │
        ┌──────────────┼──────────────┐
        │              │              │
      GAZE           VOICE          CONTEXT
        │              │              │
        └──────────────┼──────────────┘
                       ▼
                INTENT / STATE CORE
                       │
                TARGET RESOLVER
                       │
                 SAFETY POLICY
                       │
                  ACTION ENGINE
                       │
          ┌────────────┼────────────┐
          ▼            ▼            ▼
        AX API       CGEvent      App APIs
          │            │            │
          └────────────┼────────────┘
                       ▼
                      macOS
```

AI and screen intelligence plug into the core; they do not bypass it.

---

## 22. Native macOS stack

### Required

- Swift 6
- SwiftUI
- AppKit
- AVFoundation
- Vision
- Speech / modern Speech analysis APIs as available on target macOS versions
- Accessibility APIs / AXUIElement
- Core Graphics / CGEvent
- ScreenCaptureKit
- Core ML where useful
- Swift Package Manager
- XCTest + Swift Testing
- GitHub Actions

### Persistence

Use a lightweight local store for settings, calibration profiles, and non-sensitive configuration. SwiftData is acceptable for simple app state; SQLite can be introduced when cross-version stability or structured queries justify it.

### Packaging

Start with:

- Developer ID signed app
- notarized DMG
- optional direct download

Mac App Store distribution can be evaluated later because the product depends on privacy-sensitive system permissions and system-wide control capabilities.

---

## 23. Performance targets

These are engineering targets, not guarantees.

### Interaction latency

For deterministic local commands:

- target: speech recognition result to execution in <250 ms after final transcript is available.
- gaze indicator should remain visually stable and responsive.

### CPU / memory

- Avoid continuous unnecessary screen capture.
- Suspend or reduce camera processing when Lyra is paused.
- Keep UI lightweight.
- Profile on Apple Silicon.

### Reliability

- No command should execute twice because of duplicate speech callbacks.
- Low-confidence gaze should never create large unintended jumps.
- Permission failures must degrade gracefully and explain the missing capability.

---

## 24. Development phases

### Phase 0 — Gaze prototype

Deliver:

- webcam capture
- face/eye landmark pipeline
- gaze estimation prototype
- calibration
- gaze overlay
- debug visualization

Exit criterion:

> Stable, debuggable gaze point on the user's display.

### Phase 1 — Deterministic control

Deliver:

- speech recognition
- command parser
- state machine
- CGEvent executor
- basic actions
- feedback overlay

Exit criterion:

> A user can perform common desktop interactions using gaze + voice without AI.

### Phase 2 — Semantic accessibility

Deliver:

- AX application discovery
- element inspection
- target resolution
- semantic actions
- focused testing across Finder, Safari/Chrome, System Settings, TextEdit, and VS Code

Exit criterion:

> Lyra uses semantic UI actions when available and falls back to coordinates when necessary.

### Phase 3 — Robustness / privacy

Deliver:

- permission onboarding
- recovery states
- calibration persistence
- safety policies
- privacy controls
- logging controls
- automated integration tests

Exit criterion:

> Lyra is safe enough for external testers.

### Phase 4 — Screen intelligence

Deliver:

- ScreenCaptureKit integration
- OCR
- candidate target detection
- weak-accessibility fallback

### Phase 5 — AI

Deliver:

- structured intent schema
- provider abstraction
- context engine
- planning
- validation
- confirmation flows

### Phase 6 — Developer / VS Code

Deliver:

- VS Code integration
- code-aware actions
- semantic code operations
- AI coding workflows

---

## 25. Testing strategy

### Unit tests

Test independently:

- command normalization
- command parsing
- state transitions
- risk classification
- target selection
- confidence thresholds
- calibration math
- command deduplication

### Integration tests

Use deterministic fake inputs for:

- gaze samples
- speech transcripts
- accessibility elements
- action executors

The majority of core logic should be testable without a camera or microphone.

### Hardware tests

Maintain a manual matrix covering:

- built-in MacBook camera
- external webcam
- different lighting conditions
- different distances
- head movement
- glasses where practical
- single and multiple display setups

### Regression principle

Every accidental-command bug becomes a regression test.

---

## 26. Observability / debug mode

Debug mode should expose:

```text
Gaze
x: 842
 y: 421
confidence: 0.87

Target
role: AXButton
title: Run
confidence: 0.94

Command
click

Executor
AXPress

Result
SUCCESS
```

No sensitive raw camera/audio/screen data should be persisted merely because debug mode is enabled.

---

## 27. Source availability strategy

The repository should be structured so the accessibility core is easy to reuse independently.

Recommended boundaries:

- `LyraCore` — commands, state, safety, domain models.
- `LyraGaze` — gaze protocols and implementations.
- `LyraSpeech` — speech protocols and command parsing.
- `LyraAccessibility` — AX integration.
- `LyraInput` — CGEvent execution.
- `LyraScreen` — screen/OCR support.
- `LyraAI` — provider and structured-intent layer.

Keep APIs modular enough that external contributors can add hardware backends and application adapters without editing the core.

---

## 28. MVP acceptance criteria

Lyra is ready for an initial public alpha when all of the following are true:

- [ ] The desktop app launches reliably on macOS, Windows, and the supported Linux desktop environments.
- [ ] Permission onboarding explains why each permission is requested.
- [ ] Gaze calibration completes successfully.
- [ ] Gaze indicator is stable enough for basic targeting.
- [ ] Voice commands are recognized and normalized.
- [ ] Click, double click, right click, scroll, type, copy, paste, undo, redo work.
- [ ] Grab → gaze move → drop works.
- [ ] Cancel safely aborts an in-progress action.
- [ ] The platform accessibility adapter targets common controls semantically where available.
- [ ] The platform input fallback works where semantic controls are unavailable and the OS/compositor grants required access.
- [ ] Duplicate recognition events cannot accidentally execute actions twice.
- [ ] Risky actions can require confirmation.
- [ ] AI is not required for core commands.
- [ ] Camera/audio/screen data is not uploaded by default.
- [ ] Unit and integration test suites cover the command/state core.
- [ ] Debug mode makes gaze → target → command → action traceable.
- [ ] The app can operate common desktop applications on each supported platform; the validation matrix names representative file manager, browser, text editor, and VS Code cases.

---

## 29. North-star metric

The primary product question is not:

> “How accurately does Lyra move a cursor?”

It is:

> **“How much of a user's computer can they operate without physically using a conventional mouse or keyboard?”**

The long-term product should increase the range, reliability, and safety of computer tasks possible through gaze + voice.
