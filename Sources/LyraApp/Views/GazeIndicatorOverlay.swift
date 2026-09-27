import SwiftUI
import LyraCore

/// The transparent, click-through surface drawn over everything: where the user is
/// looking, what that resolves to, and — when the lens is open — the magnified rows.
///
/// This is not decoration. With a webcam the gaze estimate is off by roughly the height
/// of a line of text, so "look at that line" only becomes reliable once the lens has
/// re-presented the neighbourhood as a handful of very tall rows. The lens *is* the
/// mechanism; the dot and the highlight are how the user learns to trust it.
struct GazeIndicatorOverlay: View {
    @ObservedObject var viewModel: AppViewModel

    private var snapshot: LyraSnapshot { viewModel.snapshot }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear

            if snapshot.isZoomed, !snapshot.lens.entries.isEmpty {
                lens
            }

            if let selection = snapshot.selection, !snapshot.isZoomed {
                highlight(selection)
            }

            if let gaze = snapshot.gazePoint {
                gazeDot(at: CGPoint(x: gaze.x, y: gaze.y))
            }

            if !snapshot.isSelectionModeActive {
                standbyBadge
            }
        }
        .ignoresSafeArea()
    }

    // MARK: - Gaze

    private func gazeDot(at point: CGPoint) -> some View {
        let confidence = max(0.0, min(snapshot.gazeConfidence, 1.0))
        // Dim with confidence rather than hiding: a dot that vanishes is indistinguishable
        // from a frozen one, and knowing the tracker is seeing you badly is useful.
        return ZStack {
            Circle()
                .fill(Color.accentColor.opacity(0.18 * confidence))
                .frame(width: 46, height: 46)
            Circle()
                .stroke(Color.accentColor.opacity(0.5 + 0.5 * confidence), lineWidth: 2)
                .frame(width: 18, height: 18)
            Circle()
                .fill(Color.accentColor.opacity(0.6 + 0.4 * confidence))
                .frame(width: 6, height: 6)
        }
        .position(point)
    }

    // MARK: - Direct selection

    private func highlight(_ selection: TargetSelection) -> some View {
        let frame = selection.candidate.frame
        return TargetBox(
            frame: frame,
            // Dwell progress turns the outline into a filling bar, so the user can see
            // a selection being made rather than only its result.
            fill: snapshot.dwellProgress,
            label: selection.candidate.displayName,
            isCommitted: snapshot.committedTarget?.id == selection.candidate.id
        )
    }

    // MARK: - Lens

    private var lens: some View {
        let layout = snapshot.lens
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 16)
                .fill(.black.opacity(0.82))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.accentColor.opacity(0.35), lineWidth: 1)
                )
                .frame(width: layout.panelFrame.width, height: layout.panelFrame.height)
                .position(
                    x: layout.panelFrame.midX,
                    y: layout.panelFrame.midY
                )

            ForEach(layout.entries) { entry in
                lensRow(entry)
            }
        }
    }

    private func lensRow(_ entry: TargetLens.Entry) -> some View {
        let isSelected = snapshot.selection?.candidate.id == entry.candidate.id
        let isCommitted = snapshot.committedTarget?.id == entry.candidate.id

        return ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 10)
                .fill(isSelected ? Color.accentColor.opacity(0.28) : Color.white.opacity(0.06))

            RoundedRectangle(cornerRadius: 10)
                .stroke(
                    isCommitted ? Color.green : (isSelected ? Color.accentColor : Color.white.opacity(0.12)),
                    lineWidth: isSelected ? 2 : 1
                )

            // The dwell bar, drawn as a left-to-right fill inside the row.
            if isSelected, let dwell = snapshot.dwellProgress {
                GeometryReader { geometry in
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.accentColor.opacity(0.35))
                        .frame(width: geometry.size.width * dwell)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.candidate.displayName)
                    .font(.system(size: 15, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Text(entry.candidate.role.isEmpty ? "target" : entry.candidate.role)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
        }
        .frame(width: entry.rowFrame.width, height: entry.rowFrame.height)
        .position(x: entry.rowFrame.midX, y: entry.rowFrame.midY)
    }

    // MARK: - Standby

    private var standbyBadge: some View {
        HStack(spacing: 7) {
            Image(systemName: "eye.slash")
            Text("Say \u{201C}cursor\u{201D} to start selecting")
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.white.opacity(0.85))
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.black.opacity(0.65), in: Capsule())
        .padding(.top, 44)
        .padding(.leading, 16)
    }
}

/// One outlined target, with an optional progress fill.
private struct TargetBox: View {
    let frame: LyraRect
    let fill: Double?
    let label: String
    let isCommitted: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let fill {
                Rectangle()
                    .fill(Color.accentColor.opacity(0.22))
                    .frame(width: frame.width * fill, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)
            }

            Rectangle()
                .stroke(
                    isCommitted ? Color.green : Color.accentColor,
                    style: StrokeStyle(lineWidth: isCommitted ? 3 : 2, dash: isCommitted ? [] : [6, 4])
                )
                .frame(width: frame.width, height: frame.height)
                .offset(x: frame.minX, y: frame.minY)

            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.black.opacity(0.7), in: Capsule())
                .offset(x: frame.minX, y: max(frame.minY - 22, 0))
        }
    }
}
