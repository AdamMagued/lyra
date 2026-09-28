import SwiftUI
import LyraCore

/// Full-screen calibration surface with Emil Kowalski / Apple-grade minimalism.
///
/// Features:
/// - Monochromatic zinc/graphite/white palette with zero garish saturations.
/// - WebGazer 9-point multi-click calibration (3×3 grid: 0.10, 0.50, 0.90) with all 9 points active simultaneously.
/// - Tactile animated click rings with spring physics and tabular counters.
/// - 3.5-second precision verification phase at screen center with live accuracy percentage.
/// - Hairline 0.5pt borders (`Color.white.opacity(0.08)`) and continuous squircle corners.
struct CalibrationOverlayView: View {
    @ObservedObject var viewModel: AppViewModel

    private var webGazer: WebGazerCalibration.Progress? { viewModel.webGazerProgress }
    private var progress: ClickCalibration.Progress? { viewModel.calibrationProgress }
    private var adaptive: AdaptiveCalibration.Progress? { viewModel.adaptiveProgress }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Completely opaque solid matte black background for pure focus
                Color(red: 0.05, green: 0.05, blue: 0.06)
                    .ignoresSafeArea()

                switch viewModel.calibrationStage {
                case .idle:
                    EmptyView()
                case .intro:
                    introCard
                case .running:
                    runningView(in: geometry.size)
                case .fitting:
                    fittingCard
                case .finished:
                    resultCard
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .local) { location in
                viewModel.handleCalibrationClick(
                    atNormalized: CGPoint(
                        x: location.x / max(geometry.size.width, 1),
                        y: location.y / max(geometry.size.height, 1)
                    )
                )
            }
            .overlay(
                Button("") {
                    viewModel.handleCalibrationClick(atNormalized: CGPoint(x: 0.5, y: 0.5))
                }
                .keyboardShortcut(.space, modifiers: [])
                .opacity(0)
                .allowsHitTesting(false)
            )
        }
        .ignoresSafeArea()
        .onExitCommand { viewModel.cancelCalibration() }
    }

    // MARK: - Running View Router

    @ViewBuilder
    private func runningView(in size: CGSize) -> some View {
        if viewModel.calibrationMode == .webGazer9, let webGazer {
            switch webGazer.phase {
            case .precisionVerification(let timeRemaining, _, let accuracy):
                verificationView(timeRemaining: timeRemaining, accuracy: accuracy, in: size)
            case .fitting:
                fittingCard
            case .completed:
                resultCard
            default:
                webGazerNinePointsView(webGazer, in: size)
            }
        } else if viewModel.calibrationMode == .adaptive, let adaptive {
            adaptiveTarget(
                at: CGPoint(
                    x: adaptive.pointX * size.width,
                    y: adaptive.pointY * size.height
                ),
                progress: adaptive
            )
            adaptiveHUDContainer(adaptive)
        } else if let progress {
            target(
                at: CGPoint(
                    x: progress.pointX * size.width,
                    y: progress.pointY * size.height
                ),
                progress: progress
            )
            VStack {
                header
                Spacer()
                footer
            }
            .padding(28)
        }
    }

    // MARK: - WebGazer 9-Point Calibration Screen

    @ViewBuilder
    private func webGazerNinePointsView(_ progress: WebGazerCalibration.Progress, in size: CGSize) -> some View {
        ZStack {
            // All 9 points displayed on screen simultaneously
            ForEach(progress.points) { pt in
                WebGazerPointView(point: pt) {
                    viewModel.handleCalibrationClick(pointIndex: pt.id)
                }
                .position(x: pt.x * size.width, y: pt.y * size.height)
            }

            // Top HUD
            VStack {
                webGazerHUD(progress)
                Spacer()
            }
            .padding(.top, 54)
            .padding(.horizontal, 32)
        }
    }

    private func webGazerHUD(_ progress: WebGazerCalibration.Progress) -> some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color(red: 0.22, green: 0.78, blue: 0.48))
                        .frame(width: 7, height: 7)
                    Text("WebGazer 9-Point Calibration")
                        .font(.system(size: 15, weight: .semibold, design: .default))
                        .foregroundStyle(Color.white)
                }

                Text("Look directly at each target and click it 5 times")
                    .font(.system(size: 12, design: .default))
                    .foregroundStyle(Color(red: 0.65, green: 0.65, blue: 0.68))
            }

            Spacer(minLength: 24)

            // Minimalist Progress Track
            VStack(alignment: .trailing, spacing: 5) {
                HStack(spacing: 6) {
                    Text("\(progress.totalClicks)")
                        .font(.system(size: 13, weight: .semibold, design: .default).monospacedDigit())
                        .foregroundStyle(Color.white)
                    Text("/")
                        .font(.system(size: 12, design: .default))
                        .foregroundStyle(Color(red: 0.5, green: 0.5, blue: 0.52))
                    Text("\(progress.requiredClicks) clicks")
                        .font(.system(size: 12, design: .default).monospacedDigit())
                        .foregroundStyle(Color(red: 0.65, green: 0.65, blue: 0.68))
                }

                GeometryReader { barGeo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.08))
                        Capsule()
                            .fill(Color.white.opacity(0.85))
                            .frame(width: barGeo.size.width * CGFloat(progress.overallProgressFraction))
                            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: progress.totalClicks)
                    }
                }
                .frame(width: 140, height: 5)
            }

            Button("Cancel") {
                viewModel.cancelCalibration()
            }
            .buttonStyle(ZincPillButtonStyle())
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(red: 0.11, green: 0.11, blue: 0.12).opacity(0.92))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.4), radius: 18, y: 6)
    }

    // MARK: - WebGazer Precision Verification View

    @ViewBuilder
    private func verificationView(timeRemaining: Double, accuracy: Double, in size: CGSize) -> some View {
        ZStack {
            // Concentric precision rings at screen center (0.50, 0.50)
            PrecisionCenterTarget()
                .position(x: 0.50 * size.width, y: 0.50 * size.height)

            // Precision verification floating card
            VStack {
                HStack(spacing: 20) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 7) {
                            Circle()
                                .fill(Color(red: 0.22, green: 0.78, blue: 0.48))
                                .frame(width: 8, height: 8)
                            Text("Precision Verification")
                                .font(.system(size: 15, weight: .semibold, design: .default))
                                .foregroundStyle(.white)
                        }
                        Text("Hold your gaze steadily on the center target")
                            .font(.system(size: 12, design: .default))
                            .foregroundStyle(Color(red: 0.65, green: 0.65, blue: 0.68))
                    }

                    Spacer(minLength: 24)

                    // Live countdown & accuracy gauge
                    HStack(spacing: 16) {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(String(format: "%.1fs", max(0.0, timeRemaining)))
                                .font(.system(size: 18, weight: .bold, design: .default).monospacedDigit())
                                .foregroundStyle(.white)
                            Text("time remaining")
                                .font(.system(size: 10, design: .default))
                                .foregroundStyle(Color(red: 0.5, green: 0.5, blue: 0.52))
                        }

                        Divider()
                            .frame(height: 28)
                            .background(Color.white.opacity(0.08))

                        VStack(alignment: .trailing, spacing: 2) {
                            Text(String(format: "%.1f%%", accuracy))
                                .font(.system(size: 18, weight: .bold, design: .default).monospacedDigit())
                                .foregroundStyle(accuracy >= 80.0 ? Color(red: 0.22, green: 0.78, blue: 0.48) : Color(red: 0.95, green: 0.65, blue: 0.25))
                            Text("live accuracy")
                                .font(.system(size: 10, design: .default))
                                .foregroundStyle(Color(red: 0.5, green: 0.5, blue: 0.52))
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color(red: 0.11, green: 0.11, blue: 0.12).opacity(0.95))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
                )
                .shadow(color: Color.black.opacity(0.4), radius: 24, y: 8)
                .frame(maxWidth: 560)

                Spacer()
            }
            .padding(.top, 40)
        }
    }

    // MARK: - Intro Card

    private var introCard: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Calibration")
                    .font(.system(size: 24, weight: .semibold, design: .default))
                    .foregroundStyle(.white)

                Text("Maps your eye and facial landmarks to precise screen coordinates using Ridge Regression (L2 regularization).")
                    .font(.system(size: 13, design: .default))
                    .foregroundStyle(Color(red: 0.65, green: 0.65, blue: 0.68))
                    .lineSpacing(2)
            }

            VStack(alignment: .leading, spacing: 12) {
                minimalBullet(
                    "scope",
                    "9 simultaneous targets in a 3×3 grid. Look at each target and click it 5 times (45 samples)."
                )
                minimalBullet(
                    "function",
                    "Fits continuous Ridge Regression polynomials for X and Y screen axes with L2 regularization."
                )
                minimalBullet(
                    "stopwatch",
                    "A 3.5-second center verification phase immediately validates live tracking accuracy."
                )
            }
            .padding(.vertical, 4)

            HStack(spacing: 12) {
                Button("Begin Calibration") {
                    viewModel.beginCalibration()
                }
                .buttonStyle(ZincProminentButtonStyle())
                .keyboardShortcut(.defaultAction)

                Button("Cancel") {
                    viewModel.cancelCalibration()
                }
                .buttonStyle(ZincSecondaryButtonStyle())
                .keyboardShortcut(.escape, modifiers: [])
            }
            .padding(.top, 4)

            if let error = viewModel.calibrationError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 12))
                    Text(error)
                        .font(.system(size: 12))
                }
                .foregroundStyle(Color(red: 0.95, green: 0.65, blue: 0.25))
            }
        }
        .padding(32)
        .frame(maxWidth: 560, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(red: 0.10, green: 0.10, blue: 0.11))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.5), radius: 30, y: 12)
    }

    private func minimalBullet(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color(red: 0.75, green: 0.75, blue: 0.78))
                .frame(width: 20, alignment: .center)
            Text(text)
                .font(.system(size: 13, design: .default))
                .foregroundStyle(Color(red: 0.88, green: 0.88, blue: 0.90))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Fitting Phase Card

    private var fittingCard: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.regular)
                .tint(.white)

            Text("Fitting Personal Eye Model…")
                .font(.system(size: 16, weight: .semibold, design: .default))
                .foregroundStyle(.white)

            Text("Solving regularized Ridge Regression across horizontal and vertical axes.")
                .font(.system(size: 12, design: .default))
                .foregroundStyle(Color(red: 0.65, green: 0.65, blue: 0.68))
        }
        .padding(32)
        .frame(maxWidth: 420)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(red: 0.10, green: 0.10, blue: 0.11))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.4), radius: 24, y: 8)
    }

    // MARK: - Result Card

    private var resultCard: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let result = viewModel.calibrationResult {
                HStack(spacing: 8) {
                    Circle()
                        .fill(result.isPrecise ? Color(red: 0.22, green: 0.78, blue: 0.48) : Color(red: 0.95, green: 0.65, blue: 0.25))
                        .frame(width: 8, height: 8)
                    Text(result.isPrecise ? "Calibration High Precision" : "Calibration Complete")
                        .font(.system(size: 22, weight: .semibold, design: .default))
                        .foregroundStyle(.white)
                }

                HStack(spacing: 24) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(String(format: "%.1f%%", result.accuracyPercentage))
                            .font(.system(size: 38, weight: .bold, design: .default).monospacedDigit())
                            .foregroundStyle(result.isPrecise ? Color(red: 0.22, green: 0.78, blue: 0.48) : .white)
                        Text("live accuracy score")
                            .font(.system(size: 12, design: .default))
                            .foregroundStyle(Color(red: 0.6, green: 0.6, blue: 0.62))
                    }

                    Divider()
                        .frame(height: 48)
                        .background(Color.white.opacity(0.08))

                    VStack(alignment: .leading, spacing: 4) {
                        Text("±\(Int(result.errorPixels.rounded())) px")
                            .font(.system(size: 38, weight: .bold, design: .default).monospacedDigit())
                            .foregroundStyle(.white)
                        Text("validation error")
                            .font(.system(size: 12, design: .default))
                            .foregroundStyle(Color(red: 0.6, green: 0.6, blue: 0.62))
                    }
                }

                Text("\(result.usedPoints) of \(result.totalPoints) samples fitted into personalized eye model with regularized polynomial mapping.")
                    .font(.system(size: 13, design: .default))
                    .foregroundStyle(Color(red: 0.75, green: 0.75, blue: 0.78))
                    .lineSpacing(2)
            } else {
                Text("Calibration Incomplete")
                    .font(.system(size: 22, weight: .semibold, design: .default))
                    .foregroundStyle(.white)

                Text(viewModel.calibrationError ?? "Could not converge eye model.")
                    .font(.system(size: 13, design: .default))
                    .foregroundStyle(Color(red: 0.95, green: 0.65, blue: 0.25))
            }

            HStack(spacing: 12) {
                Button("Done") {
                    viewModel.closeCalibration()
                }
                .buttonStyle(ZincProminentButtonStyle())
                .keyboardShortcut(.defaultAction)

                Button("Calibrate Again") {
                    viewModel.repeatCalibration()
                }
                .buttonStyle(ZincSecondaryButtonStyle())
            }
            .padding(.top, 4)
        }
        .padding(32)
        .frame(maxWidth: 520, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(red: 0.10, green: 0.10, blue: 0.11))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.5), radius: 30, y: 12)
    }

    // MARK: - Adaptive Legacy Views (Cleaned)

    private func adaptiveHUDContainer(_ progress: AdaptiveCalibration.Progress) -> some View {
        let isTop = progress.pointY < 0.50
        return VStack {
            if !isTop {
                adaptiveHUD(progress)
                Spacer()
            } else {
                Spacer()
                adaptiveHUD(progress)
            }
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 28)
        .animation(.easeInOut(duration: 0.25), value: isTop)
    }

    private func adaptiveHUD(_ progress: AdaptiveCalibration.Progress) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(progress.promptTitle)
                    .font(.system(size: 16, weight: .semibold, design: .default))
                    .foregroundStyle(.white)
                Text(progress.promptSubtitle)
                    .font(.system(size: 12, design: .default))
                    .foregroundStyle(Color(red: 0.65, green: 0.65, blue: 0.68))
            }
            Spacer()
            Button("Cancel") { viewModel.cancelCalibration() }
                .buttonStyle(ZincPillButtonStyle())
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(maxWidth: 540)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(red: 0.11, green: 0.11, blue: 0.12).opacity(0.92))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
        )
    }

    private func adaptiveTarget(at position: CGPoint, progress: AdaptiveCalibration.Progress) -> some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.12), lineWidth: 4)
                .frame(width: 64, height: 64)

            Circle()
                .trim(from: 0, to: progress.targetProgress)
                .stroke(Color.white, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: 64, height: 64)

            Circle()
                .fill(Color.white)
                .frame(width: 24, height: 24)
        }
        .position(position)
    }

    // MARK: - Click Legacy Fallback

    private func target(at position: CGPoint, progress: ClickCalibration.Progress) -> some View {
        let done = Double(progress.clicksForPoint) / Double(max(progress.clicksPerPoint, 1))
        return ZStack {
            Circle()
                .stroke(Color.white.opacity(0.12), lineWidth: 5)
                .frame(width: 80, height: 80)
            Circle()
                .trim(from: 0, to: done)
                .stroke(Color.white, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: 80, height: 80)
            Circle()
                .fill(Color.white)
                .frame(width: 36, height: 36)
                .overlay(
                    Text("\(progress.clicksForPoint)/\(progress.clicksPerPoint)")
                        .font(.system(size: 13, weight: .bold).monospacedDigit())
                        .foregroundStyle(Color.black)
                )
        }
        .position(position)
    }

    private var header: some View {
        HStack {
            Text("Look at the dot, then click it")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
            Spacer()
            if let progress {
                Text("\(min(progress.pointIndex + 1, progress.totalPoints)) of \(progress.totalPoints)")
                    .font(.system(size: 14, weight: .medium).monospacedDigit())
                    .foregroundStyle(Color(red: 0.7, green: 0.7, blue: 0.72))
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(red: 0.11, green: 0.11, blue: 0.12).opacity(0.9))
        )
    }

    private var footer: some View {
        Button("Cancel") { viewModel.cancelCalibration() }
            .buttonStyle(ZincSecondaryButtonStyle())
    }
}

// MARK: - WebGazer Interactive Point View

private struct WebGazerPointView: View {
    let point: WebGazerCalibration.PointState
    let onClick: () -> Void

    @State private var isHovered = false
    @State private var isPressed = false

    var body: some View {
        Button(action: {
            guard !point.isComplete else { return }
            withAnimation(.spring(response: 0.2, dampingFraction: 0.6)) {
                isPressed = true
            }
            onClick()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                    isPressed = false
                }
            }
        }) {
            ZStack {
                // Subtle ambient glow
                Circle()
                    .fill(Color.white.opacity(point.isComplete ? 0.04 : (isHovered ? 0.12 : 0.06)))
                    .frame(width: 90, height: 90)

                // Background track
                Circle()
                    .stroke(Color.white.opacity(0.08), lineWidth: 4)
                    .frame(width: 64, height: 64)

                // Animated progress fill ring
                Circle()
                    .trim(from: 0, to: point.progressFraction)
                    .stroke(
                        point.isComplete ? Color(red: 0.22, green: 0.78, blue: 0.48) : Color.white,
                        style: StrokeStyle(lineWidth: 4, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .frame(width: 64, height: 64)
                    .animation(.spring(response: 0.32, dampingFraction: 0.78), value: point.clicks)

                // Center disc
                ZStack {
                    Circle()
                        .fill(
                            point.isComplete
                                ? Color(red: 0.15, green: 0.28, blue: 0.20)
                                : Color(red: 0.18, green: 0.18, blue: 0.20)
                        )
                        .frame(width: 44, height: 44)
                        .overlay(
                            Circle()
                                .stroke(
                                    point.isComplete
                                        ? Color(red: 0.22, green: 0.78, blue: 0.48).opacity(0.4)
                                        : Color.white.opacity(0.12),
                                    lineWidth: 0.5
                                )
                        )

                    if point.isComplete {
                        Image(systemName: "checkmark")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(Color(red: 0.22, green: 0.78, blue: 0.48))
                    } else {
                        Text("\(point.clicks)/\(point.clicksRequired)")
                            .font(.system(size: 13, weight: .semibold, design: .default).monospacedDigit())
                            .foregroundStyle(.white)
                    }
                }
            }
            .scaleEffect(isPressed ? 0.90 : (isHovered && !point.isComplete ? 1.06 : 1.0))
            .animation(.spring(response: 0.25, dampingFraction: 0.75), value: isPressed)
            .animation(.spring(response: 0.25, dampingFraction: 0.75), value: isHovered)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(point.isComplete ? "Calibration target \(point.id + 1) completed" : "Calibration target \(point.id + 1) of 9, \(point.clicks) of \(point.clicksRequired) clicks")
        .accessibilityHint(point.isComplete ? "" : "Look directly at this target and click 5 times")
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

// MARK: - Precision Center Target

private struct PrecisionCenterTarget: View {
    @State private var pulse = false

    var body: some View {
        ZStack {
            // Concentric ambient breathing rings
            Circle()
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
                .frame(width: pulse ? 160 : 130, height: pulse ? 160 : 130)

            Circle()
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
                .frame(width: pulse ? 100 : 80, height: pulse ? 100 : 80)

            // Precision crosshair lines
            ForEach(0..<4, id: \.self) { i in
                Capsule()
                    .fill(Color.white.opacity(0.45))
                    .frame(width: 2, height: 14)
                    .offset(y: -24)
                    .rotationEffect(.degrees(Double(i) * 90))
            }

            // Center target disc
            Circle()
                .fill(Color.white)
                .frame(width: 20, height: 20)
                .shadow(color: Color.white.opacity(0.3), radius: 8)

            Circle()
                .fill(Color.black)
                .frame(width: 6, height: 6)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}

// MARK: - Minimalist Zinc Button Styles

private struct ZincProminentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold, design: .default))
            .foregroundStyle(Color.black)
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(Color.white.opacity(configuration.isPressed ? 0.85 : 1.0))
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

private struct ZincSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium, design: .default))
            .foregroundStyle(Color(red: 0.88, green: 0.88, blue: 0.90))
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(Color.white.opacity(configuration.isPressed ? 0.08 : 0.04))
            )
            .overlay(
                Capsule()
                    .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

private struct ZincPillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium, design: .default))
            .foregroundStyle(Color(red: 0.8, green: 0.8, blue: 0.82))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(Color.white.opacity(configuration.isPressed ? 0.12 : 0.06))
            )
            .overlay(
                Capsule()
                    .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
            )
    }
}
