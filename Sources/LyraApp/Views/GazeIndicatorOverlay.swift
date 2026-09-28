import SwiftUI
import LyraCore

/// The transparent, click-through overlay drawn over all windows:
/// where the user is looking, what target resolves, and magnified AutoLens rows.
///
/// Refined with Emil Kowalski / Apple-grade minimalism:
/// - Frosted elegant indicators with zero garish saturations.
/// - Hairline 0.5pt borders (`Color.white.opacity(0.08)`).
/// - Continuous squircle radii (`style: .continuous`).
/// - Fluid progressive dwell fill.
/// - SF Pro typography with tabular figures.
struct GazeIndicatorOverlay: View {
    @ObservedObject var viewModel: AppViewModel

    private var snapshot: LyraSnapshot { viewModel.snapshot }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear

            // AutoLens magnified cluster panel
            if snapshot.isZoomed, !snapshot.lens.entries.isEmpty {
                lensView
            }

            // Direct target candidate highlight
            if let selection = snapshot.selection, !snapshot.isZoomed {
                targetHighlight(selection)
            }

            // Live gaze dot / reticle
            if let gaze = snapshot.gazePoint {
                frostedGazeIndicator(at: CGPoint(x: gaze.x, y: gaze.y))
            }

            // Minimalist standby badge when selection is idle
            if !snapshot.isSelectionModeActive {
                standbyPill
            }
        }
        .ignoresSafeArea()
    }

    // MARK: - Frosted Gaze Indicator

    private func frostedGazeIndicator(at point: CGPoint) -> some View {
        let confidence = max(0.0, min(snapshot.gazeConfidence, 1.0))

        return ZStack {
            // Diffuse frosted halo glow
            Circle()
                .fill(Color.white.opacity(0.08 * confidence))
                .frame(width: 48, height: 48)

            // Outer hairline precision ring
            Circle()
                .stroke(Color.white.opacity(0.40 * confidence), lineWidth: 0.5)
                .frame(width: 22, height: 22)

            // Center crisp dot
            Circle()
                .fill(Color.white.opacity(0.90 * confidence))
                .frame(width: 5, height: 5)
                .shadow(color: Color.black.opacity(0.4), radius: 2)
        }
        .position(point)
        .animation(.spring(response: 0.28, dampingFraction: 0.8), value: point)
    }

    // MARK: - Direct Selection Box

    private func targetHighlight(_ selection: TargetSelection) -> some View {
        let frame = selection.candidate.frame
        let isCommitted = snapshot.committedTarget?.id == selection.candidate.id

        return FrostedTargetBox(
            frame: frame,
            dwellProgress: snapshot.dwellProgress,
            label: selection.candidate.displayName,
            role: selection.candidate.role,
            isCommitted: isCommitted
        )
    }

    // MARK: - AutoLens Panel

    private var lensView: some View {
        let layout = snapshot.lens

        return ZStack(alignment: .topLeading) {
            // Lens panel background card
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(red: 0.08, green: 0.08, blue: 0.09).opacity(0.92))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
                )
                .shadow(color: Color.black.opacity(0.45), radius: 24, y: 10)
                .frame(width: layout.panelFrame.width, height: layout.panelFrame.height)
                .position(x: layout.panelFrame.midX, y: layout.panelFrame.midY)

            // AutoLens target rows
            ForEach(layout.entries) { entry in
                autoLensRow(entry)
            }
        }
    }

    private func autoLensRow(_ entry: TargetLens.Entry) -> some View {
        let isSelected = snapshot.selection?.candidate.id == entry.candidate.id
        let isCommitted = snapshot.committedTarget?.id == entry.candidate.id

        return ZStack(alignment: .leading) {
            // Row background
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(
                    isSelected
                        ? Color.white.opacity(0.12)
                        : Color.white.opacity(0.04)
                )

            // Fluid dwell fill bar
            if isSelected, let dwell = snapshot.dwellProgress {
                GeometryReader { geo in
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.white.opacity(0.22), Color.white.opacity(0.14)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: geo.size.width * CGFloat(dwell))
                        .animation(.linear(duration: 0.05), value: dwell)
                }
            }

            // Row hairline border
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(
                    isCommitted
                        ? Color(red: 0.22, green: 0.78, blue: 0.48)
                        : (isSelected ? Color.white.opacity(0.35) : Color.white.opacity(0.08)),
                    lineWidth: isCommitted ? 1.5 : (isSelected ? 1.0 : 0.5)
                )

            // Row text content
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.candidate.displayName)
                        .font(.system(size: 14, weight: isSelected ? .semibold : .medium, design: .default))
                        .foregroundStyle(Color.white)
                        .lineLimit(1)

                    Text(entry.candidate.role.isEmpty ? "target" : entry.candidate.role)
                        .font(.system(size: 10, design: .default))
                        .foregroundStyle(Color(red: 0.55, green: 0.55, blue: 0.58))
                        .lineLimit(1)
                }

                Spacer()

                if isCommitted {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color(red: 0.22, green: 0.78, blue: 0.48))
                }
            }
            .padding(.horizontal, 14)
        }
        .frame(width: entry.rowFrame.width, height: entry.rowFrame.height)
        .position(x: entry.rowFrame.midX, y: entry.rowFrame.midY)
    }

    // MARK: - Standby Pill Badge

    private var standbyPill: some View {
        HStack(spacing: 7) {
            Image(systemName: "eye.slash")
                .font(.system(size: 11))
                .foregroundStyle(Color(red: 0.6, green: 0.6, blue: 0.62))
            Text("Say \u{201C}cursor\u{201D} to select")
                .font(.system(size: 12, weight: .medium, design: .default))
                .foregroundStyle(Color(red: 0.85, green: 0.85, blue: 0.88))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(Color(red: 0.09, green: 0.09, blue: 0.10).opacity(0.88))
        )
        .overlay(
            Capsule()
                .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.3), radius: 10, y: 4)
        .padding(.top, 44)
        .padding(.leading, 18)
    }
}

// MARK: - Frosted Target Box

private struct FrostedTargetBox: View {
    let frame: LyraRect
    let dwellProgress: Double?
    let label: String
    let role: String
    let isCommitted: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Fluid dwell progress fill
            if let dwell = dwellProgress {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(0.12))
                    .frame(width: CGFloat(frame.width) * CGFloat(dwell), height: CGFloat(frame.height))
                    .offset(x: frame.minX, y: frame.minY)
                    .animation(.linear(duration: 0.05), value: dwell)
            }

            // Target bounding stroke
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(
                    isCommitted
                        ? Color(red: 0.22, green: 0.78, blue: 0.48)
                        : Color.white.opacity(0.50),
                    lineWidth: isCommitted ? 2.0 : 1.0
                )
                .frame(width: CGFloat(frame.width), height: CGFloat(frame.height))
                .offset(x: frame.minX, y: frame.minY)

            // Minimal floating label pill
            HStack(spacing: 4) {
                Text(label)
                    .font(.system(size: 11, weight: .semibold, design: .default))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                if !role.isEmpty {
                    Text("•")
                        .font(.system(size: 9))
                        .foregroundStyle(Color(red: 0.5, green: 0.5, blue: 0.52))
                    Text(role)
                        .font(.system(size: 10, design: .default))
                        .foregroundStyle(Color(red: 0.7, green: 0.7, blue: 0.72))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(Color(red: 0.09, green: 0.09, blue: 0.10).opacity(0.92))
            )
            .overlay(
                Capsule()
                    .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
            )
            .shadow(color: Color.black.opacity(0.3), radius: 6, y: 2)
            .offset(x: frame.minX, y: max(frame.minY - 24, 4))
        }
    }
}
