import Foundation

/// Turns imprecise gaze into precise selection by making the targets bigger.
///
/// This is the answer to a problem that has no direct solution. A webcam tracker lands
/// within roughly 100-200 points of the true gaze position. A line of code is about
/// 19 points tall. So "look at this line" cannot work directly — not with a webcam, and
/// in fact not even with a $200 infrared tracker, which is accurate to about 2-3 lines.
/// No amount of calibration fixes this, because it is a limit of the hardware.
///
/// What does work is two-stage selection, the same trick gaze-typing keyboards use:
///
/// 1. Gaze lands somewhere roughly right. That is all the precision needed to decide
///    *which neighbourhood* the user is interested in.
/// 2. The neighbourhood is re-presented as a small number of very large rows. Each row
///    is now an order of magnitude taller than the tracker's error, so gaze selects
///    among them reliably.
/// 3. A voice command acts on the selected row.
///
/// The lens is what makes line-by-line editor control possible, and it is also how the
/// Dock's Stage Manager strip becomes reachable.
///
/// Pure geometry, no hardware, so the layout can be tested directly.
public struct TargetLens: Sendable {

    /// Maximum number of rows shown at once. Each additional row makes every row
    /// shorter, which trades away the accuracy the lens exists to provide. Four keeps
    /// rows comfortably taller than typical tracker error.
    public var maximumRows: Int

    /// Vertical size of each row, in points.
    ///
    /// This is the parameter the whole mechanism turns on, so it is set from the error
    /// it has to beat rather than from what looks tidy. A webcam gaze estimate lands
    /// within roughly 100 points of the truth; a row has to be clearly taller than that
    /// or picking among rows is no easier than picking on the screen directly, and the
    /// lens is just a bigger menu that costs the same to get wrong.
    public var rowHeight: Double

    /// Gap between rows, so a glance between two rows does not dither.
    public var rowSpacing: Double

    /// Fraction of the screen width the lens occupies.
    public var widthFraction: Double

    public init(
        maximumRows: Int = 4,
        rowHeight: Double = 150,
        rowSpacing: Double = 12,
        widthFraction: Double = 0.52
    ) {
        self.maximumRows = maximumRows
        self.rowHeight = rowHeight
        self.rowSpacing = rowSpacing
        self.widthFraction = widthFraction
    }

    public static let `default` = TargetLens()

    /// One row of the lens: a candidate, where it is drawn, and how far it was from the
    /// original gaze point.
    public struct Entry: Sendable, Identifiable, Equatable {
        public var id: String { candidate.id }
        public let candidate: TargetCandidate
        /// Where this row is drawn, in screen points.
        public let rowFrame: LyraRect
        /// Distance from the original gaze point to the real target, in points.
        public let sourceDistance: Double

        public init(candidate: TargetCandidate, rowFrame: LyraRect, sourceDistance: Double) {
            self.candidate = candidate
            self.rowFrame = rowFrame
            self.sourceDistance = sourceDistance
        }
    }

    /// A rendered lens: its panel bounds and its rows.
    public struct Layout: Sendable, Equatable {
        public let panelFrame: LyraRect
        public let entries: [Entry]

        public init(panelFrame: LyraRect, entries: [Entry]) {
            self.panelFrame = panelFrame
            self.entries = entries
        }

        public static let empty = Layout(panelFrame: .zero, entries: [])
    }

    /// Builds a lens for a gaze position.
    ///
    /// Candidates are ranked by distance from the gaze point, which is the only signal
    /// available — but distance is exactly the right one here. The user's gaze is
    /// imprecise, not arbitrary; the thing they meant is essentially always among the
    /// few nearest targets, and the lens exists to let them disambiguate the last step
    /// themselves rather than have the system guess.
    ///
    /// - Parameters:
    ///   - candidates: everything currently on screen.
    ///   - gazePoint: screen position in points, origin top-left.
    ///   - screenSize: screen bounds in points.
    ///   - limit: overrides `maximumRows` when the user asks for a bigger or smaller lens.
    public func layout(
        candidates: [TargetCandidate],
        gazePoint: LyraPoint,
        screenSize: LyraSize,
        limit: Int? = nil
    ) -> Layout {
        let rowCount = max(1, min(limit ?? maximumRows, maximumRows + 3))
        let actionable = candidates.filter(\.isActionable)
        let pool = actionable.isEmpty ? candidates : actionable

        let ranked = pool
            .map { ($0, $0.frame.distance(to: gazePoint)) }
            .sorted { lhs, rhs in
                if abs(lhs.1 - rhs.1) > 1.0 { return lhs.1 < rhs.1 }
                return lhs.0.area < rhs.0.area
            }
            .prefix(rowCount)

        guard !ranked.isEmpty else { return .empty }

        // Rows are the accuracy knob, so when the panel would not fit the screen the
        // gap gives way first, then the row height. A lens that overflows the display
        // is worse than a slightly shorter one: the top or bottom row becomes
        // unreachable, and the user has no way to tell that is why.
        var height = rowHeight
        var gap = rowSpacing
        let available = screenSize.height * 0.92
        let needed = { Double(ranked.count) * height + Double(max(ranked.count - 1, 0)) * gap + gap * 2 }
        if needed() > available {
            gap = max(2, gap * 0.4)
        }
        if needed() > available {
            height = max(
                30,
                (available - gap * (Double(ranked.count) + 1)) / Double(ranked.count)
            )
        }

        let panelWidth = screenSize.width * widthFraction
        let contentHeight = Double(ranked.count) * height
            + Double(max(ranked.count - 1, 0)) * gap
        let panelHeight = contentHeight + gap * 2

        let panelFrame = LyraRect(
            x: (screenSize.width - panelWidth) / 2.0,
            y: (screenSize.height - panelHeight) / 2.0,
            width: panelWidth,
            height: panelHeight
        )

        let entries = ranked.enumerated().map { index, pair -> Entry in
            let rowFrame = LyraRect(
                x: panelFrame.minX + gap,
                y: panelFrame.minY + gap + Double(index) * (height + gap),
                width: panelFrame.width - gap * 2,
                height: height
            )
            return Entry(candidate: pair.0, rowFrame: rowFrame, sourceDistance: pair.1)
        }

        return Layout(panelFrame: panelFrame, entries: entries)
    }

    /// Finds which lens row a gaze point falls on.
    ///
    /// Returns `nil` when the gaze is off the lens entirely, which the caller should
    /// treat as "still deciding" rather than as a selection.
    public func row(at gazePoint: LyraPoint, in layout: Layout) -> Entry? {
        guard layout.panelFrame.contains(gazePoint) else { return nil }

        if let direct = layout.entries.first(where: { $0.rowFrame.contains(gazePoint) }) {
            return direct
        }

        // Between rows: take the nearest, but only within the inter-row gap, so looking
        // at the space between two rows does not resolve to whichever happens to be
        // closer by a single point.
        let nearest = layout.entries
            .map { ($0, $0.rowFrame.distance(to: gazePoint)) }
            .min { $0.1 < $1.1 }

        guard let nearest, nearest.1 <= rowSpacing else { return nil }
        return nearest.0
    }
}
