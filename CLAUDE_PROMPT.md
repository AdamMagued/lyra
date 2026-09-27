# Lyra — Master Objective & Engineering Mandate

## Mission & Goal
You are working on **Lyra**, a native macOS accessibility and control system built on a simple foundation:
> **Gaze = Where**
> **Voice = What**

The ultimate objective is **sub-degree, jitter-free eye tracking with voice-activated cursor control**:
- **Saying `"cursor"`** activates eye-tracking cursor control.
- **Saying `"off"` or `"stop"`** instantly pauses/deactivates cursor control.
- **Saying `"click"`, `"double click"`, or `"right click"`** triggers immediate mouse actions at the current gaze location.
- **Calibration:** An immersive, fullscreen calibration routine (e.g. animated ball gliding across screen points that the user follows with their eyes) that tunes the system to the user's specific eye physiology, screen geometry, and distance.
- **Accuracy Target:** **90%+ accuracy**, rock-solid stability, zero micro-jitter during fixation, instant saccade response, and robust tolerance to posture shifts (leaning forward/backward, tilting head).

---

## Your Mandate & Freedom
**You have 100% full creative and architectural authority.**
- You can refactor, rewrite, replace, or completely redesign any algorithm, pipeline, or layer if you believe a cleaner or significantly more accurate approach exists.
- Do not hesitate to throw away or rebuild any component (gaze estimators, feature extractors, calibration math, smoothing filters, windowing, UI) to achieve **uncompromising, world-class tracking performance**.
- The standard is: **It must work EXTREMELY well.**

---

## Architectural Principles & Strict Constraints
1. **100% Native macOS & Swift 6:**
   - Use Apple's native frameworks: `Vision`, `AVFoundation`, `Speech`, `CoreGraphics`, `AppKit`, `SwiftUI`.
   - **NO Python, OpenCV, Electron, or cloud AI runtime dependencies.** The core control loop must run locally, at high framerates (60 FPS on Apple Silicon), with zero latency.
2. **Deterministic Control:**
   - Computer actions must flow through deterministic validation.
   - Degraded mode resilience: Gaze tracking must function even if speech/microphone is unavailable, and vice versa.
3. **DO NOT PUSH TO GITHUB:**
   - Keep all changes, branches, and commits strictly **LOCAL**. Do not run `git push`.
4. **Packaging:**
   - Build outputs: `build/Lyra.app` and `build/Lyra.dmg` (bundled with an `/Applications` symlink via `scripts/package_dmg.sh`).

---

## Current Architecture & State
The codebase is organized into clean Swift packages:
- **`LyraCore` (`Sources/LyraCore/`):**
  - `GazePoint`, `Transcript`, `LyraCommand`.
  - `CommandParser`: Parses spoken keywords (`cursor`, `off`, `stop`, `click`, etc.).
  - `OneEuroFilter`: Adaptive Casiez 1-Euro filter with velocity cutoff & fixation deadband to kill micro-jitter.
  - `CalibrationMap`: Bivariate polynomial screen mapping.
  - `LyraCoordinator`: Concurrency actor orchestrating gaze, speech, and cursor dispatch.
- **`LyraGaze` (`Sources/LyraGaze/`):**
  - `VisionGazeProvider`: 720p HD AVFoundation video capture with Apple `VNDetectFaceLandmarksRequestRevision3`.
  - `BiometricGazeEstimator`: Normalized pupil-in-canthus coordinates (PCCR), head-pose roll compensation, and Inter-Ocular Distance (IOD) depth scaling.
  - `RidgeCalibrationSolver`: Tikhonov-regularized Ridge regression fitting 2D screen polynomials.
- **`LyraSpeech` (`Sources/LyraSpeech/`):**
  - `NativeSpeechProvider`: Apple `Speech` framework (`SFSpeechRecognizer` + `AVAudioEngine`).
- **`LyraInput` (`Sources/LyraInput/`):**
  - `CGInputController`: `CGDisplayMoveCursorToPoint` + `CGEvent` mouse move & click simulation.
- **`LyraApp` (`Sources/LyraApp/`):**
  - `MainDashboardView`: Live 720p camera feed, status telemetry, calibration controls, permission indicators.
  - `CalibrationOverlayView`: Fullscreen animated gliding ball routine for multi-point gaze calibration.
  - `OverlayWindowManager`: Fullscreen borderless AppKit window (`NSWindow.Level.modalPanel`).
- **Scripts & Packaging:**
  - `scripts/build_app.sh`: Compiles release binary and creates ad-hoc signed `build/Lyra.app`.
  - `scripts/package_dmg.sh`: Generates distributable `build/Lyra.dmg`.
- **Engineering Guidelines:**
  - See `docs/AGENTS.md` for repository rules.

---

## Key Areas to Investigate & Elevate
1. **Biometric Feature Extraction (`BiometricGazeEstimator.swift`):**
   - Can we extract even cleaner pupil center vs. inner/outer canthus vectors from Vision's landmark contours?
   - Can we add iris boundary fitting, pupil-glint/reflection estimation, or multi-frame temporal alignment?
2. **Calibration Geometry & User Experience (`CalibrationOverlayView.swift` & `RidgeCalibrationSolver.swift`):**
   - Is 9 points sufficient, or should we offer a 16-point grid or dynamic spiral?
   - Dwell detection: Automatically detect steady ocular fixation before advancing to the next target.
   - Real-time visual feedback: Show a subtle indicator during calibration so the user knows when their gaze locks onto the target.
3. **Cursor Smoothing & Deadband (`OneEuroFilter.swift`):**
   - Fine-tune $\beta$ (speed coefficient), $f_{c,\min}$ (minimum cutoff frequency), and deadband thresholds so the cursor locks rock-still on small buttons, yet moves with zero perceptible drag during saccades.
4. **Voice Latency & Reliability (`NativeSpeechProvider.swift`):**
   - Ensure instantaneous response when saying "off" or "stop" to halt cursor movement immediately.

---

## Your Goal Now
Inspect the codebase, run tests (`swift test`), launch the app, analyze tracking precision, and implement whatever changes you deem necessary to make Lyra the fastest, smoothest, and most accurate open-source eye-tracking assistant on macOS.
