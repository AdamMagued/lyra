import SwiftUI
import LyraCore

/// The control window: turn it on, calibrate it, and see what it thinks it is doing.
struct MainDashboardView: View {
    @ObservedObject var viewModel: AppViewModel

    private var snapshot: LyraSnapshot { viewModel.snapshot }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            statusRow
            Divider()
            controls
            Divider()
            diagnostics
            Spacer(minLength: 0)
            footer
        }
        .padding(20)
        .frame(minWidth: 460, minHeight: 520)
    }

    // MARK: - Status

    private var statusRow: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                Circle()
                    .fill(stateColour.opacity(0.18))
                    .frame(width: 44, height: 44)
                Image(systemName: stateSymbol)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(stateColour)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(snapshot.trackingState.description)
                    .font(.system(size: 17, weight: .semibold))
                Text(snapshot.statusMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 3) {
                Text(viewModel.isCalibrated
                     ? String(format: "±%.0f px", viewModel.calibrationMap.validationErrorPixels)
                     : "uncalibrated")
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .foregroundStyle(viewModel.isCalibrated ? .green : .orange)
                Text("\(snapshot.targetCount) targets")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var stateColour: Color {
        switch snapshot.trackingState {
        case .tracking: return .green
        case .calibrating: return .blue
        case .blinking, .uncalibrated: return .orange
        case .faceLost, .error: return .red
        case .idle: return .secondary
        }
    }

    private var stateSymbol: String {
        switch snapshot.trackingState {
        case .tracking: return "eye"
        case .calibrating: return "scope"
        case .blinking: return "eye.slash"
        case .faceLost: return "person.fill.questionmark"
        case .uncalibrated: return "exclamationmark.triangle"
        case .error: return "xmark.octagon"
        case .idle: return "pause"
        }
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Button(snapshot.isEngineRunning ? "Stop" : "Start") {
                    viewModel.toggleEngine()
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isCalibrating)

                Button("Calibrate") {
                    viewModel.startCalibration()
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.isCalibrating || !snapshot.isEngineRunning)

                Button("Quick") {
                    viewModel.startCalibration(quick: true)
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.isCalibrating || !snapshot.isEngineRunning)

                Spacer()

                Toggle("Magnify", isOn: $viewModel.autoLensEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .help("Open the lens automatically when your gaze settles on a cluster of small controls")

                Toggle("Overlay", isOn: $viewModel.showGazeOverlay)
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }

            if let error = viewModel.calibrationError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }

            if let reason = viewModel.calibrationInvalidReason {
                Label(reason, systemImage: "display.trianglebadge.exclamationmark")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }

            if snapshot.isEngineRunning {
                HStack(spacing: 8) {
                    Button(snapshot.isSelectionModeActive ? "Stop selecting" : "Start selecting") {
                        viewModel.send(snapshot.isSelectionModeActive ? .stopTracking : .startTracking)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button("Show targets") { viewModel.send(.showTargets) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                    Button("Hide") { viewModel.send(.hideTargets) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                    Button("Click") { viewModel.send(.activate) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        }
    }

    // MARK: - Diagnostics

    private var diagnostics: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Voice")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            HStack(alignment: .top, spacing: 8) {
                Text("\u{201C}\(snapshot.lastTranscript)\u{201D}")
                    .font(.system(size: 12))
                    .lineLimit(2)
                Spacer()
                if let command = snapshot.lastCommand {
                    Text(commandName(command))
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                }
            }

            if let selection = snapshot.selection {
                HStack(spacing: 8) {
                    Image(systemName: "scope")
                    Text(selection.candidate.displayName)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    if snapshot.committedTarget != nil {
                        Text("committed")
                            .font(.system(size: 10))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.2), in: Capsule())
                            .foregroundStyle(.green)
                    }
                    Spacer()
                    if let dwell = snapshot.dwellProgress {
                        ProgressView(value: dwell)
                            .frame(width: 70)
                    }
                }
            }

            permissionRow
        }
    }

    private var permissionRow: some View {
        HStack(spacing: 6) {
            permission("Camera", viewModel.cameraGranted)
            permission("Mic", viewModel.microphoneGranted)
            permission("Speech", viewModel.speechGranted)
            permission("Accessibility", viewModel.accessibilityGranted)

            if !viewModel.accessibilityGranted || !viewModel.cameraGranted {
                Button("Grant") { viewModel.requestPermissions() }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
            }
        }
    }

    private func permission(_ name: String, _ granted: Bool) -> some View {
        HStack(spacing: 3) {
            Circle()
                .fill(granted ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 6, height: 6)
            Text(name)
                .font(.system(size: 10))
                .foregroundStyle(granted ? .primary : .secondary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Color.secondary.opacity(0.08), in: Capsule())
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Say \u{201C}cursor\u{201D} \u{2192} look \u{2192} \u{201C}click\u{201D}.  \u{201C}next\u{201D} fixes a wrong pick, \u{201C}zoom\u{201D} magnifies, \u{201C}stop\u{201D} halts.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            if !viewModel.isStageManagerOn {
                Text("Stage Manager is off — turn it on to select window thumbnails.")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
            }

            if viewModel.isCalibrated {
                Button("Forget calibration") { viewModel.resetCalibration() }
                    .buttonStyle(.link)
                    .font(.system(size: 10))
            }
        }
    }

    private func commandName(_ command: LyraCommand) -> String {
        switch command {
        case .startTracking: return "start"
        case .stopTracking: return "stop"
        case .activate: return "click"
        case .doubleClick: return "double click"
        case .rightClick: return "right click"
        case .nextTarget: return "next"
        case .previousTarget: return "previous"
        case .showTargets: return "show targets"
        case .hideTargets: return "hide targets"
        case .zoomIn: return "zoom in"
        case .zoomOut: return "zoom out"
        case .undo: return "undo"
        case .cancel: return "cancel"
        case .confirm: return "confirm"
        case .deny: return "deny"
        case .unrecognized(let text): return "heard: \(text.prefix(20))"
        }
    }
}
