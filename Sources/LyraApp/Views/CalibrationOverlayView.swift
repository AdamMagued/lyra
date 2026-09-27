import SwiftUI
import LyraCore

/// The full-screen calibration surface.
///
/// Calibration is a task the user has to be *told about* before, *guided through* during,
/// and *shown the result of* after. The first version did none of those: pressing Calibrate
/// dropped straight into a small dot on a black screen with no warning, and when the run
/// ended the surface closed itself and reported the outcome as status text on a window the
/// user had already stopped looking at. Every part of that reads as a malfunction.
///
/// So there are four acts, and each one answers a question the user actually has:
///
/// - **Intro** — what is this, what will I have to do, how long will it take.
/// - **Running** — where do I click, how many times, how much is left.
/// - **Fitting** — the pause after the last click, which is otherwise indistinguishable
///   from a hang.
/// - **Finished** — did it work, and how well.
struct CalibrationOverlayView: View {
    @ObservedObject var viewModel: AppViewModel

    private var progress: ClickCalibration.Progress? { viewModel.calibrationProgress }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Dimmed, not blacked out. The user needs to see their own screen to know
                // where on it they are being asked to look; an opaque field turns every
                // target into an abstract dot in a void.
                Color.black.opacity(0.62).ignoresSafeArea()

                switch viewModel.calibrationStage {
                case .idle:
                    EmptyView()
                case .intro:
                    intro
                case .running:
                    if let progress {
                        target(
                            at: CGPoint(
                                x: progress.pointX * geometry.size.width,
                                y: progress.pointY * geometry.size.height
                            ),
                            progress: progress
                        )
                    }
                case .fitting:
                    fitting
                case .finished:
                    result
                }

                if viewModel.calibrationStage == .running, progress != nil {
                    VStack {
                        header
                        Spacer()
                        footer
                    }
                    .padding(28)
                }
            }
            .contentShape(Rectangle())
            // The whole surface takes the click, not just the dot. A click that lands away
            // from the dot is a mistake worth telling the user about, and it cannot be told
            // about if the surface silently swallows it. The run itself decides whether a
            // click was close enough to count.
            .onTapGesture(coordinateSpace: .local) { location in
                viewModel.handleCalibrationClick(
                    atNormalized: CGPoint(
                        x: location.x / max(geometry.size.width, 1),
                        y: location.y / max(geometry.size.height, 1)
                    )
                )
            }
        }
        .ignoresSafeArea()
        .onExitCommand { viewModel.cancelCalibration() }
    }

    // MARK: - Intro

    private var intro: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Calibrate Lyra to your eyes")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.white)

            VStack(alignment: .leading, spacing: 10) {
                bullet(
                    "ellipsis.circle",
                    "Lyra learns how your eye and head movements map to points on your screen. It measures your face through the camera — nothing is recorded or sent anywhere."
                )
                bullet(
                    "hand.tap",
                    "\(viewModel.calibrationPointCount) dots will appear one at a time. Look at the dot, then click it — \(viewModel.calibrationClickCount / viewModel.calibrationPointCount) times each. Your click tells Lyra where you were actually looking, which is what makes it accurate."
                )
                bullet(
                    "clock",
                    "Under a minute. You can stop at any point with Escape."
                )
                bullet(
                    "figure.seated.side",
                    "Sit the way you normally would — same chair, same distance, and carry on wearing your glasses if you wear them. Only your head position matters, not how still you think you look."
                )
            }

            HStack(spacing: 12) {
                Button("Begin") { viewModel.beginCalibration() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)

                Button("Cancel") { viewModel.cancelCalibration() }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.escape, modifiers: [])
            }
            .foregroundStyle(.white)
            .padding(.top, 4)

            if let error = viewModel.calibrationError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
            }
        }
        .padding(30)
        .frame(maxWidth: 560, alignment: .leading)
        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 18))
    }

    private func bullet(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 20, alignment: .center)
            Text(text)
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.88))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Running

    /// Diameter of the solid disc the user clicks.
    ///
    /// Sized to be findable from a normal sitting distance without hunting. The old 9-point
    /// dot was legible only if you were already looking straight at it, which is the one
    /// thing a user mid-calibration cannot rely on.
    private let targetDiameter: CGFloat = 46

    private func target(at position: CGPoint, progress: ClickCalibration.Progress) -> some View {
        let done = Double(progress.clicksForPoint) / Double(max(progress.clicksPerPoint, 1))

        return ZStack {
            // Soft glow so the target is findable in peripheral vision, which is how the
            // user actually locates it: they do not know where the next point is until
            // they have already started moving towards it.
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color.white.opacity(0.18), .clear],
                        center: .center,
                        startRadius: 10,
                        endRadius: 140
                    )
                )
                .frame(width: 280, height: 280)

            // How many of this dot's clicks are in. Carried on the target itself rather
            // than in a corner, so the user never has to look away from the thing they are
            // supposed to be clicking.
            Circle()
                .stroke(Color.white.opacity(0.18), lineWidth: 7)
                .frame(width: 132, height: 132)

            Circle()
                .trim(from: 0, to: done)
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: 132, height: 132)
                .animation(.easeOut(duration: 0.18), value: done)

            // Crosshair ticks. They make the exact spot unambiguous at a glance, which a
            // lone disc does not — its centre has to be inferred, and the click has to land
            // within tolerance of it.
            ForEach(0..<4, id: \.self) { index in
                Capsule()
                    .fill(Color.white.opacity(0.9))
                    .frame(width: 4, height: 26)
                    .offset(y: -52)
                    .rotationEffect(.degrees(Double(index) * 90))
            }

            Circle()
                .fill(Color.white)
                .frame(width: targetDiameter, height: targetDiameter)
                .overlay(Circle().stroke(Color.black.opacity(0.65), lineWidth: 3))
                .overlay(
                    Text("\(progress.clicksForPoint)/\(progress.clicksPerPoint)")
                        .font(.system(size: 15, weight: .bold).monospacedDigit())
                        .foregroundStyle(.black.opacity(0.75))
                )
        }
        .position(position)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("Look at the dot, then click it")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)

            Text("Keep your eyes on the dot while you click — that is what it learns from")
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.65))

            Spacer()

            if let progress {
                Text("\(min(progress.pointIndex + 1, progress.totalPoints)) of \(progress.totalPoints)")
                    .font(.system(size: 16, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }

    private var footer: some View {
        VStack(spacing: 12) {
            if let progress {
                overallProgressBar(progress)
            }

            HStack(spacing: 16) {
                if let progress {
                    Text("\(progress.samplesCollected) of \(viewModel.calibrationClickCount) clicks recorded")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                }

                Button("Cancel") { viewModel.cancelCalibration() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .keyboardShortcut(.escape, modifiers: [])
            }
            .foregroundStyle(.white)
        }
        .padding(16)
        .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }

    /// How much of the whole run is left. The dot count alone does not convey how much
    /// clicking is left, and a user who cannot see the end of a task assumes it is stuck.
    private func overallProgressBar(_ progress: ClickCalibration.Progress) -> some View {
        let fraction = Double(progress.samplesCollected) / Double(max(viewModel.calibrationClickCount, 1))
        return ZStack(alignment: .leading) {
            Capsule().fill(Color.white.opacity(0.18))
            GeometryReader { geometry in
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: geometry.size.width * fraction)
            }
        }
        .frame(width: 260, height: 6)
    }

    // MARK: - Pauses and outcomes

    private var fitting: some View {
        panel {
            ProgressView().controlSize(.large)
            Text("Working out your gaze model…")
                .font(.headline)
                .foregroundStyle(.white)
            Text("This takes a few seconds.")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.7))
        }
    }

    private var result: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let result = viewModel.calibrationResult {
                Text(result.isPrecise ? "Calibrated" : "Calibrated — roughly")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white)

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(Int(result.errorPixels.rounded()))")
                        .font(.system(size: 44, weight: .bold).monospacedDigit())
                        .foregroundStyle(result.isPrecise ? Color.green : Color.orange)
                    Text("points average error")
                        .font(.system(size: 15))
                        .foregroundStyle(.white.opacity(0.7))
                }

                Text(verdict(for: result))
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)

                Text("\(result.usedPoints) of \(result.totalPoints) clicks were used.")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.6))

                if result.abandonedPoints > 0 {
                    Label(
                        "\(result.abandonedPoints) click\(result.abandonedPoints == 1 ? "" : "s") could not be used — either they missed the dot or the camera lost your eyes at that moment.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("Calibration did not complete")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                Text(viewModel.calibrationError ?? "The points could not be fitted into a gaze model.")
                    .font(.system(size: 14))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 12) {
                Button("Done") { viewModel.closeCalibration() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)

                Button("Calibrate again") { viewModel.repeatCalibration() }
                    .buttonStyle(.bordered)
            }
            .foregroundStyle(.white)
            .padding(.top, 4)
        }
        .padding(30)
        .frame(maxWidth: 520, alignment: .leading)
        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 18))
    }

    /// Says what the number means for using the thing, because "41 points" is not
    /// something a person can evaluate.
    private func verdict(for result: CalibrationAppResult) -> String {
        if result.isPrecise {
            return "Gaze should land where you look. You can turn on selection and try it."
        }
        return "That is looser than it should be. Dim rooms, sitting further back than usual, or a lot of head movement during the run all cost accuracy — it is worth another go."
    }

    private func panel<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 14) { content() }
            .padding(28)
            .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 16))
    }
}

/// Alias so the verdict helper reads clearly at its call site.
private typealias CalibrationAppResult = AppViewModel.CalibrationResult
