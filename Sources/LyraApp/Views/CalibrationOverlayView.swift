import SwiftUI
import LyraCore

/// The full-screen calibration surface.
///
/// Three pieces of information are on screen because each of them is actionable by the
/// user, and nothing else is:
///
/// - **Where to look**, as a dot that grows and fills as the data comes in.
/// - **Whether the system is getting a clean read** (the ring), which the user can fix
///   by holding still or moving their head back to where it was.
/// - **How far through the run they are**, so the cost of finishing is visible. A
///   calibration that refuses to accept bad data takes longer than one that does not,
///   and that has to be legible or it just looks broken.
struct CalibrationOverlayView: View {
    @ObservedObject var viewModel: AppViewModel

    private var progress: CalibrationCapture.Progress? { viewModel.calibrationProgress }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.94).ignoresSafeArea()

                if let progress {
                    if progress.isFinished {
                        finishing
                    } else {
                        dot(
                            at: CGPoint(
                                x: progress.pointX * geometry.size.width,
                                y: progress.pointY * geometry.size.height
                            ),
                            progress: progress
                        )
                    }
                } else {
                    waiting
                }

                VStack {
                    header
                    Spacer()
                    footer
                }
                .padding(28)
            }
            .contentShape(Rectangle())
        }
        .onExitCommand { viewModel.cancelCalibration() }
    }

    // MARK: - Pieces

    private func dot(at position: CGPoint, progress: CalibrationCapture.Progress) -> some View {
        ZStack {
            // Outer ring: how cleanly the eye is being read.
            Circle()
                .stroke(Color.white.opacity(0.12), lineWidth: 6)
                .frame(width: 96, height: 96)

            Circle()
                .trim(from: 0, to: progress.lockQuality)
                .stroke(
                    progress.isLocked ? Color.green : Color.orange,
                    style: StrokeStyle(lineWidth: 6, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .frame(width: 96, height: 96)
                .animation(.easeOut(duration: 0.12), value: progress.lockQuality)

            // Inner disc: time on this point.
            Circle()
                .stroke(Color.white.opacity(0.25), lineWidth: 3)
                .frame(width: 40, height: 40)

            Circle()
                .fill(progress.phase == .settling ? Color.white.opacity(0.35) : Color.accentColor)
                .frame(
                    width: 40 * progress.elapsedFraction,
                    height: 40 * progress.elapsedFraction
                )

            Circle()
                .fill(Color.white)
                .frame(width: 9, height: 9)
        }
        .position(position)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Look at the dot and hold still")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)

            Spacer()

            if let progress {
                Text("\(min(progress.pointIndex + 1, progress.totalPoints)) / \(progress.totalPoints)")
                    .font(.system(size: 15, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 10) {
            if let progress, progress.retryCount > 0 {
                Text("Repeating \(progress.retryCount) point\(progress.retryCount == 1 ? "" : "s") — data was not clean enough")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange.opacity(0.9))
            }

            HStack(spacing: 16) {
                statusPill(progress)

                Button("This one was bad") { viewModel.retryCurrentPoint() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                Button("Cancel") { viewModel.cancelCalibration() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .keyboardShortcut(.escape, modifiers: [])
            }
            .foregroundStyle(.white)
        }
    }

    private func statusPill(_ progress: CalibrationCapture.Progress?) -> some View {
        let text: String
        let colour: Color
        switch progress?.phase {
        case .settling:
            text = "Settling…"
            colour = .white.opacity(0.5)
        case .collecting:
            if progress?.isLocked == true {
                text = "Locked on"
                colour = .green
            } else {
                text = "Hold still"
                colour = .orange
            }
        default:
            text = "Starting…"
            colour = .white.opacity(0.5)
        }
        return Text(text)
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(colour.opacity(0.18), in: Capsule())
            .foregroundStyle(colour)
    }

    private var waiting: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.large)
            Text(viewModel.snapshot.trackingState.description)
                .font(.headline)
                .foregroundStyle(.white)
            Text("Waiting for the camera. Make sure your face is lit and inside the frame.")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.6))
        }
    }

    private var finishing: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.large)
            Text("Fitting your gaze model…")
                .font(.headline)
                .foregroundStyle(.white)
        }
    }
}
