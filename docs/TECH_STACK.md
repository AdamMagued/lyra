# Lyra — Technical Stack & Architecture

> **Scope update (2026-09-27):** This stack was supplied for a macOS-only product. The current target is macOS, Windows, and Linux. Treat Apple frameworks below as candidates for the macOS adapter, not as cross-platform dependencies. The shared-core/UI/adapters strategy and platform feasibility gates in [the implementation plan](IMPLEMENTATION_PLAN.md) supersede platform-specific assumptions here.

## 1. Stack summary

| Area | Choice | Why |
|---|---|---|
| Primary language | Swift 6 | Best fit for deep native macOS integration and low-level system APIs |
| UI | SwiftUI | Native UI, accessibility support, fast iteration |
| macOS integration | AppKit | Menu bar, app lifecycle, windows, lower-level AppKit behavior |
| Camera | AVFoundation | Native camera capture |
| Face/eye perception | Vision | Native landmark detection and vision primitives |
| Gaze inference | Core ML + pluggable model interface | Keeps gaze estimation modular and allows future models/hardware |
| Speech | Speech framework / modern Speech APIs | Native speech recognition; prefer on-device paths where supported |
| Accessibility | Accessibility API / AXUIElement | Semantic interaction with other macOS apps |
| Raw input | Core Graphics / CGEvent | Universal mouse and keyboard event injection |
| Screen capture | ScreenCaptureKit | Native high-performance screen capture for later visual understanding |
| Local ML | Core ML | Local inference where appropriate |
| Storage | SwiftData initially; SQLite if justified later | Local configuration and calibration data |
| Dependencies | Swift Package Manager | Native dependency management |
| Testing | Swift Testing + XCTest | Unit, integration, and platform tests |
| CI | GitHub Actions | Automated build/test/lint checks |
| Distribution | Developer ID + notarized DMG initially | Fits system-level permission model and public, noncommercial source distribution |
| AI | Provider abstraction | Supports local and remote models without coupling the core |

## 2. Architecture principles

### Principle 1 — Native first

The accessibility/control plane is native Swift. Do not use Electron, React Native, Flutter, or a Python process for the core input loop.

### Principle 2 — Deterministic control plane

Basic commands must be deterministic:

```text
speech transcript
    ↓
command parser
    ↓
typed command
    ↓
risk policy
    ↓
target resolution
    ↓
executor
```

An LLM must never sit directly between the user and raw CGEvent calls.

### Principle 3 — Semantic before pixel

Target resolution priority:

```text
1. Accessibility element
2. Screen region / OCR / visual target
3. Raw gaze coordinate
```

Execution priority:

```text
1. Accessibility semantic action
2. Application-specific action
3. CGEvent fallback
```

### Principle 4 — AI is optional

The product must remain useful with:

- no internet,
- no AI API key,
- no cloud provider,
- only deterministic commands.

### Principle 5 — Privacy by default

Camera, microphone, and screen contents should stay local unless the user explicitly enables a feature that requires cloud processing.

---

## 3. Package layout

```text
Lyra/
├── App/
├── Packages/
│   ├── LyraCore/
│   ├── LyraGaze/
│   ├── LyraSpeech/
│   ├── LyraAccessibility/
│   ├── LyraInput/
│   ├── LyraScreen/
│   ├── LyraAI/
│   └── LyraIntegrations/
├── Features/
│   ├── Onboarding/
│   ├── Calibration/
│   ├── CommandCenter/
│   ├── Settings/
│   └── Debug/
└── Tests/
```

### `LyraCore`

Owns:

- domain models
- `LyraCommand`
- command state machine
- target contracts
- risk classification
- permission state models
- execution results
- shared protocols

`LyraCore` should have no dependency on UI, camera frameworks, or concrete AI providers.

### `LyraGaze`

Owns:

- camera input protocol
- Vision implementation
- gaze estimation
- calibration
- filtering/smoothing
- confidence
- gaze stream

Expose protocols so dedicated eye trackers can be added later.

### `LyraSpeech`

Owns:

- audio/speech recognition abstraction
- transcript stream
- normalization
- deterministic parser
- command vocabulary

It must not execute commands.

### `LyraAccessibility`

Owns:

- AX application discovery
- element tree inspection
- point-to-element resolution
- semantic actions
- accessibility metadata normalization

### `LyraInput`

Owns:

- mouse movement
- mouse buttons
- keyboard events
- typing
- scrolling
- drag/drop

### `LyraScreen`

Owns later:

- ScreenCaptureKit
- OCR
- visual candidate detection
- screen context

### `LyraAI`

Owns:

- AI provider protocol
- request/response schemas
- structured intent parsing
- planning
- tool/action validation
- provider-specific adapters

### `LyraIntegrations`

Owns:

- VS Code integration
- browser integration
- terminal integration
- future third-party adapters

---

## 4. Core protocols

Keep the main abstractions small.

```swift
protocol GazeProvider {
    func start() async throws
    func stop()
    var gazeStream: AsyncStream<GazePoint> { get }
}

protocol SpeechProvider {
    func start() async throws
    func stop()
    var transcriptStream: AsyncStream<Transcript> { get }
}

protocol TargetResolver {
    func resolve(at point: CGPoint) async -> TargetResolution
}

protocol ActionExecutor {
    func execute(_ command: LyraCommand, on target: Target?) async throws -> ExecutionResult
}

protocol IntentProvider {
    func interpret(_ input: IntentInput) async throws -> StructuredIntent
}
```

Avoid massive protocols that combine unrelated responsibilities.

---

## 5. Data flow

### Deterministic command

```text
AVFoundation
    ↓
Speech recognizer
    ↓
Transcript
    ↓
CommandParser
    ↓
LyraCommand.click
    ↓
GazeProvider.latestTarget
    ↓
TargetResolver
    ↓
RiskPolicy
    ↓
ActionExecutor
    ↓
AXPress or CGEvent
    ↓
Feedback
```

### AI command

```text
Speech
  ↓
Transcript
  ↓
AI Intent Provider
  ↓
StructuredIntent
  ↓
Schema validation
  ↓
Risk policy
  ↓
Target/context resolution
  ↓
Action plan
  ↓
Validated executors
```

---

## 6. Gaze implementation strategy

Start with a protocol-driven architecture:

```text
GazeProvider
├── WebcamGazeProvider
└── FutureDedicatedEyeTrackerProvider
```

The webcam implementation can use Vision for face/eye landmarks plus a calibration/inference model.

Do not hard-code the assumption that every Mac has the same camera, resolution, field of view, or physical setup.

### Gaze processing pipeline

```text
Frame
 ↓
Face detection
 ↓
Eye landmarks
 ↓
Feature extraction
 ↓
Gaze model
 ↓
Calibration transform
 ↓
Smoothing
 ↓
Confidence
 ↓
GazePoint
```

Treat each stage as testable independently.

---

## 7. Speech implementation strategy

Primary:

- native Speech framework / modern Speech APIs available on supported macOS versions.

Fallback during development:

- push-to-talk mode.

Later:

- configurable wake phrase / activation strategy.
- alternative speech providers.

The speech provider emits transcripts; the parser decides whether the transcript matches a command.

---

## 8. Accessibility integration strategy

The accessibility layer should expose a normalized internal model.

Example:

```swift
struct AccessibleElement {
    let role: Role
    let title: String?
    let value: String?
    let frame: CGRect
    let enabled: Bool
    let actions: Set<AccessibilityAction>
}
```

The rest of the system should not directly depend on raw AX attribute strings everywhere.

Create a focused adapter around AXUIElement and centralize conversion to internal types.

---

## 9. Input execution strategy

Implement an executor abstraction.

```text
ActionExecutor
├── AccessibilityExecutor
├── CGEventExecutor
└── CompositeExecutor
```

`CompositeExecutor` decides:

1. Can the target expose a valid semantic action?
2. If yes, use it.
3. Otherwise, is a raw input action safe?
4. If yes, use CGEvent.
5. Otherwise return a recoverable error.

---

## 10. AI provider architecture

Never make the rest of the project know about a specific vendor.

```text
IntentProvider
├── NoAIProvider
├── LocalModelProvider
├── RemoteModelProvider
└── MockIntentProvider
```

AI outputs must conform to a strict schema.

Example:

```json
{
  "intent": "type_text",
  "text": "hello world",
  "target": "gaze_target"
}
```

The schema is validated before any action reaches an executor.

---

## 11. Safety architecture

Use a central policy engine:

```swift
protocol RiskPolicy {
    func evaluate(command: LyraCommand, target: Target?) -> RiskDecision
}
```

Possible result:

```swift
enum RiskDecision {
    case allow
    case requireConfirmation
    case deny(reason: String)
}
```

Do not scatter confirmation logic across individual buttons or handlers.

---

## 12. Permissions architecture

Create one permission coordinator that knows the status of:

- microphone
- camera
- Accessibility
- screen recording

The UI asks the coordinator what is missing instead of embedding permission logic in unrelated features.

Every permission request should have:

1. explanation,
2. system request,
3. success state,
4. denial state,
5. recovery instructions.

---

## 13. Configuration / persistence

Persist:

- gaze calibration profile
- smoothing settings
- voice settings
- confirmation policy
- enabled integrations
- AI provider configuration metadata
- accessibility preferences

Do not persist raw camera/audio/screen content unless a future feature explicitly requires it and the user opts in.

Secrets/API keys should use macOS Keychain rather than plain local storage.

---

## 14. Concurrency

Use Swift concurrency (`async/await`, `Task`, `AsyncStream`) as the default architecture.

Keep streams separated:

```text
Gaze stream
Speech stream
System events
App context
```

Use an actor or other serialized coordination point for command execution to prevent duplicate or concurrent destructive actions.

---

## 15. Error handling

Errors must be typed and recoverable where possible.

Examples:

- `cameraUnavailable`
- `microphoneDenied`
- `accessibilityPermissionMissing`
- `screenRecordingDenied`
- `gazeUnavailable`
- `lowGazeConfidence`
- `noTargetFound`
- `commandNotRecognized`
- `actionUnavailable`
- `confirmationRequired`

Avoid swallowing errors and continuing silently.

---

## 16. Testability

Core command behavior must be testable without real hardware.

Create fakes for:

- gaze provider
- speech provider
- accessibility resolver
- executor
- AI provider
- permission coordinator

A unit test should be able to do:

```text
fake gaze → point at fake button
fake speech → "click"
run command pipeline
assert semantic click executed
```

---

## 17. Build and CI

Every pull request should run:

1. formatting/lint checks where configured,
2. Swift build,
3. unit tests,
4. package tests,
5. integration tests that do not require real permissions/hardware.

Hardware/manual tests should be documented separately.

Do not make CI depend on Accessibility permission or a physical camera.

---

## 18. macOS support policy

Choose a supported macOS baseline early and centralize all availability checks.

Do not scatter version checks throughout business logic.

Use small platform adapters for APIs that vary by macOS version.

---

## 19. Recommended developer tooling

- Xcode
- Swift Package Manager
- SwiftFormat or equivalent formatter
- SwiftLint or equivalent linting if the team accepts the dependency
- GitHub Actions
- Instruments for performance profiling
- Accessibility Inspector for AX debugging
- Console / unified logging for diagnostics

Use Apple's native debugging tools before adding custom tooling.

---

## 20. First implementation order

1. Create `LyraCore`.
2. Create a fake gaze provider.
3. Create a fake speech provider.
4. Implement the command model/state machine.
5. Implement a CGEvent executor.
6. Build a simple debug overlay.
7. Build real microphone transcription.
8. Build real gaze estimation + calibration.
9. Add AX target resolution.
10. Add composite execution.
11. Add permission onboarding.
12. Add safety policy.
13. Add integration tests.
14. Only then add screen intelligence or AI.
