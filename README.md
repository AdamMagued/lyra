# Lyra

**Gaze = where. Voice = what.**

Lyra is an early-stage open-source desktop accessibility project for macOS, Windows, and Linux, exploring computer control through gaze and speech. Its base control path is intended to be deterministic, local-first, and useful without an AI provider. Each operating system needs its own camera, speech, accessibility, input, permission, and packaging adapters.

Lyra is licensed under the [OSI-approved MIT License](LICENSE). The license permits commercial use and resale, provided its copyright and license notice is retained.

The repository currently contains the product and engineering package. The application has not been scaffolded yet; the cross-platform architecture decision, implementation sequence, and release gates are in [the implementation plan](docs/IMPLEMENTATION_PLAN.md). The supplied PRD and stack began as macOS-only documents; the scope update at the top of those documents and the implementation plan supersede platform-specific assumptions in that original package.

## Project documents

- [Product requirements](docs/PRD.md)
- [Technical stack and architecture](docs/TECH_STACK.md)
- [Engineering guidance for coding agents](docs/AGENTS.md)
- [Implementation plan](docs/IMPLEMENTATION_PLAN.md)

## Core control path

Speech is normalized into a typed command. Lyra resolves the gaze target, checks confidence, permissions, and risk, then uses a semantic accessibility action when one is available on the current operating system. Raw input emulation is the fallback. AI and screen understanding must not bypass this path.

## Current status

Planning and repository setup. Key product and technical decisions are listed in the implementation plan. No camera, microphone, screen, or accessibility data is collected by this repository.
