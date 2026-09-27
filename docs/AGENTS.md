# AGENTS.md — Lyra Engineering Rules

> **Scope update (2026-09-27):** This starter guidance assumed a native macOS-only product. Lyra now targets macOS, Windows, and Linux. Its safety, deterministic-control, privacy, accessibility, and testability rules remain in force; macOS-only frameworks and platform exclusivity are historical until the cross-platform architecture is selected in [the implementation plan](IMPLEMENTATION_PLAN.md). Do not make a shared module depend on an OS-specific API.

## Mission

Lyra is a desktop accessibility/control layer built around:

> **Gaze = where**
> **Voice = what**

The core product must remain useful without AI, cloud services, or application-specific integrations.

Agents working on this repository must preserve that architectural principle.

---

## 1. Absolute priorities

1. **Accessibility and user safety come before convenience.**
2. **Determinism comes before AI cleverness.**
3. **Native macOS integration comes before cross-platform abstraction.**
4. **Semantic UI interaction comes before coordinate clicking when semantics are available.**
5. **Local processing comes before cloud processing when technically practical.**
6. **Small, testable modules beat giant managers.**

---

## 2. Technology rules

### Required

- Swift 6
- SwiftUI for most UI
- AppKit where lower-level macOS behavior requires it
- Swift concurrency (`async/await`, actors, `AsyncStream`)
- Swift Package Manager
- Accessibility API / AXUIElement
- Core Graphics / CGEvent
- AVFoundation
- Vision
- Speech APIs appropriate to the supported macOS baseline
- ScreenCaptureKit for future screen intelligence
- Core ML where local ML is appropriate

### Do not introduce casually

- Electron
- React Native
- Flutter
- Python as a runtime dependency for the core product
- Node.js runtime dependency for the core product
- a custom webview-based desktop shell
- a large third-party framework when Apple provides the required native API

A new dependency requires a concrete reason: capability, security, performance, or major development-speed gain.

---

## 3. Architecture boundaries

### `LyraCore`

May contain domain logic only.

Must NOT depend directly on:

- SwiftUI
- camera hardware
- raw AX attribute strings
- a specific AI provider
- CGEvent implementation details

### `LyraGaze`

Owns gaze acquisition, calibration, filtering, and confidence.

Do not make UI code calculate gaze math.

### `LyraSpeech`

Owns speech recognition and deterministic command parsing.

Speech code must not directly execute computer actions.

### `LyraAccessibility`

Owns AXUIElement interaction and normalizes raw accessibility data into internal models.

Do not spread raw accessibility constants throughout the repository.

### `LyraInput`

Owns CGEvent mouse/keyboard event generation.

### `LyraAI`

Owns model/provider integrations and structured intent interpretation.

AI may propose actions; it does not bypass validation or directly call raw input APIs.

---

## 4. Never bypass the control plane

All computer actions must flow through:

```text
Input
  ↓
Command / Intent
  ↓
Validation
  ↓
Risk Policy
  ↓
Target Resolution
  ↓
Executor
```

Never add a shortcut such as:

```text
LLM → CGEvent
```

or:

```text
speech callback → click()
```

without routing through the core command pipeline.

---

## 5. AI rules

AI is optional.

The following must work without AI:

- click
- double click
- right click
- scroll
- type
- copy
- paste
- undo
- redo
- select
- grab
- move
- drop
- cancel

AI outputs must be:

1. structured,
2. schema-validated,
3. risk-checked,
4. target-resolved,
5. executed by trusted Lyra executors.

Never trust model-generated coordinates, shell commands, key sequences, or arbitrary code without validation appropriate to the feature.

---

## 6. Accessibility rules

Prefer this order:

```text
AX semantics
    ↓
application-specific API
    ↓
screen/OCR/vision target
    ↓
raw gaze coordinate
```

When adding an interaction, first ask:

> Can macOS Accessibility APIs expose the actual semantic element/action?

If yes, use it.

Coordinate-based interaction is the fallback, not the preferred semantic layer.

---

## 7. Gaze rules

Treat gaze as noisy probabilistic input.

Never assume:

- pixel-perfect accuracy,
- perfect lighting,
- perfect head position,
- constant camera geometry,
- constant user posture.

Every gaze point should have confidence and timestamp information.

Do not execute high-impact actions solely because one low-confidence gaze sample crossed a threshold.

Avoid sudden cursor jumps from noisy samples.

Keep calibration, smoothing, and target selection independently testable.

---

## 8. Speech rules

Speech recognition and command interpretation are separate stages.

Example:

```text
"double click that"
        ↓
transcript
        ↓
normalizer
        ↓
parser
        ↓
.doubleClick
```

A transcript is never itself an action.

Protect against duplicate callbacks and repeated recognition events.

Provide a clear cancel path.

---

## 9. Safety rules

Every command must have a risk policy.

Default expectations:

### Low risk

- move
- scroll
- ordinary click
- selection

### Higher risk

- delete
- close
- send
- paste into an unknown field
- shell execution
- file deletion
- security/account changes
- financial/external actions

High-risk operations require explicit confirmation unless the user has deliberately configured a different policy and the operation is appropriate to that policy.

Never hide destructive actions behind vague confirmation text.

---

## 10. Privacy rules

Do not:

- upload camera frames by default,
- upload audio by default,
- upload screen contents by default,
- persist raw gaze/audio/screen data just for logging.

Use local processing where practical.

Cloud AI must be explicit and configurable.

API keys/secrets belong in Keychain, never source files, test fixtures, or plain configuration committed to Git.

---

## 11. macOS permission rules

Handle these centrally:

- Camera
- Microphone
- Accessibility
- Screen Recording

Never repeatedly trigger system permission prompts from random feature code.

Every permission flow should have:

- explanation,
- request,
- success handling,
- denial handling,
- recovery instructions.

The product must remain usable in degraded mode when optional permissions are missing.

---

## 12. Testing rules

Every behavior added to the core pipeline should have a test when practical.

Especially test:

- command normalization,
- parser behavior,
- state transitions,
- cancellation,
- risk decisions,
- duplicate event suppression,
- target selection,
- low-confidence behavior,
- executor selection.

Prefer fakes over real hardware in unit tests.

A feature should not require an actual camera or microphone to test its core logic.

Every bug involving an accidental action should produce a regression test.

---

## 13. Concurrency rules

Use structured concurrency.

Prefer:

- `async/await`
- actors for serialized mutable state
- `AsyncStream` for event streams

Avoid unstructured detached work unless there is a specific documented reason.

The command execution path must prevent conflicting or duplicate executions.

---

## 14. Error handling rules

Do not silently ignore errors.

Use typed errors/results that can reach the UI or command feedback layer.

A failure should ideally explain:

- what failed,
- why it failed,
- whether the user can recover,
- what Lyra did instead.

---

## 15. Logging rules

Use Apple's unified logging appropriately.

Never log sensitive raw content by default:

- full speech transcripts,
- screen contents,
- camera frames,
- credentials,
- tokens,
- private file contents.

Debug mode may expose ephemeral diagnostics, but persistence requires explicit justification.

---

## 16. UI rules

Lyra's own interface must be accessible.

Support:

- VoiceOver
- keyboard navigation
- reduced motion
- scalable text
- high contrast
- clear focus states
- large enough interactive targets

Do not make a user operate the Lyra settings UI exclusively with a mouse.

---

## 17. Adding dependencies

Before adding a dependency, document:

- why Apple's APIs are insufficient,
- the maintenance/security implications,
- why the dependency is worth the cost.

Do not add libraries simply because they make a small function easier.

---

## 18. Application integrations

Integrations belong behind stable interfaces.

The generic control layer must continue working without an application adapter.

Initial priority:

1. Finder
2. Browser
3. VS Code
4. Terminal

Do not hard-code VS Code assumptions into `LyraCore`.

---

## 19. Coding style

Prefer:

- small files,
- explicit names,
- immutable values where practical,
- dependency injection,
- protocol boundaries,
- pure functions for command parsing and policy decisions.

Avoid:

- global mutable state,
- singleton abuse,
- giant view models,
- giant “Manager” classes,
- hidden side effects,
- direct system-event calls inside SwiftUI views.

---

## 20. Before modifying code

An agent should first identify:

1. the owning package/module,
2. the interface boundary,
3. the data flow into the feature,
4. the executor path,
5. the relevant tests.

Do not solve architecture problems by adding another global manager.

---

## 21. Before submitting a change

Check:

- Does the core still work without AI?
- Is the interaction deterministic?
- Is the action routed through the safety policy?
- Does semantic accessibility beat coordinate clicking when possible?
- Is the feature testable without hardware?
- Are errors recoverable?
- Did the change introduce a new privacy leak?
- Did the change introduce a new permission dependency?
- Did the change add unnecessary third-party dependencies?

Run the repository's documented verification/build/test commands before declaring the change complete.

---

## 22. Product direction that must not drift

Lyra is **not**:

> “An LLM that controls your computer.”

Lyra is:

> **“An accessibility control layer where gaze tells the computer where and voice tells it what.”**

AI adds intelligence on top of the control layer.

The deterministic accessibility foundation is the product's core asset and must be protected throughout development.
