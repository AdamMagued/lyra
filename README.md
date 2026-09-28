# Lyra

**Gaze = where. Voice = what.**

Lyra is an early-stage open-source desktop accessibility project for macOS, Windows, and Linux, exploring computer control through gaze and speech. Its base control path is intended to be deterministic, local-first, and useful without an AI provider. Each operating system needs its own camera, speech, accessibility, input, permission, and packaging adapters.

Lyra is free and open-source software licensed under the [GNU General Public License v3.0 (GPLv3)](LICENSE).

## Attribution & Acknowledgements

Lyra's 9-point multi-click calibration engine, continuous online click training, and regularized eye-gaze regression are built upon research and methods developed by the **Brown University HCI Group** in **WebGazer**:
- Papoutsaki, A., Sangkloy, P., Laskey, J., Daskalova, N., Huang, J., & Hays, J. (2016). *WebGazer: Scalable Webcam Eye Tracking Using User Interactions*. Proceedings of the Twenty-Fifth International Joint Conference on Artificial Intelligence (IJCAI 2016).
- Portions Copyright (C) 2016–2026 Brown University HCI Group (WebGazer).
- Copyright (C) 2026 wisphex.

The repository currently contains the product and engineering package. The application architecture and release gates are documented in [the implementation plan](docs/IMPLEMENTATION_PLAN.md).

## Project documents

- [Product requirements](docs/PRD.md)
- [Technical stack and architecture](docs/TECH_STACK.md)
- [Engineering guidance for coding agents](docs/AGENTS.md)
- [Implementation plan](docs/IMPLEMENTATION_PLAN.md)

## Core control path

Speech is normalized into a typed command. Lyra resolves the gaze target, checks confidence, permissions, and risk, then uses a semantic accessibility action when one is available on the current operating system. Raw input emulation is the fallback. AI and screen understanding must not bypass this path.

## Current status

Active development on macOS with continuous squircle Emil Kowalski minimalist UI, WebGazer 9-point multi-click calibration, live precision verification, and nose fine-tune stabilization. No camera, microphone, screen, or accessibility data is ever transmitted off-device.
