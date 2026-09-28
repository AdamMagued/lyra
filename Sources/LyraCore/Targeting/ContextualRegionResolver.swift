import Foundation

/// State-based Macro Navigation Engine for macOS gaze control.
///
/// Instead of continuous, jittery pixel-level floating cursor hunting:
/// 1. The screen is partitioned into high-level macro states so gaze ALWAYS attaches
///    confidently to an obvious target.
/// 2. States:
///    - Top Right: Whole menu extras / Control Center status bar
///    - Top Left: Whole Apple menu & application menu bar
///    - Bottom: Whole macOS Dock
///    - Left Edge (Stage Manager): Attaches to Stage Manager, then fine-tunes vertically
///      to highlight the exact window thumbnail closest to gaze
///    - Main Workspace: Highlights the active application window
public struct ContextualRegionResolver: Sendable {

    public init() {}

    /// Resolves the active macro state for any gaze coordinate.
    ///
    /// - Parameters:
    ///   - gazePoint: The user's screen-space gaze point (origin top-left).
    ///   - screenSize: Dimensions of the screen currently being tracked.
    ///   - candidates: Current snapshot of actionable/scanned UI targets.
    /// - Returns: A `ContextualHighlight` representing the active macro region.
    public func resolve(
        gazePoint: LyraPoint,
        screenSize: LyraSize,
        candidates: [TargetCandidate] = []
    ) -> ContextualHighlight? {
        guard screenSize.width > 100, screenSize.height > 100 else { return nil }

        let width = screenSize.width
        let height = screenSize.height

        // Macro boundary thresholds
        let topBarThresholdY = max(height * 0.16, 75.0)
        let dockThresholdY = height - max(height * 0.16, 95.0)
        let stageManagerThresholdX = max(width * 0.19, 180.0)

        // 1. Stage Manager: Left edge between menu bar and dock
        if gazePoint.x <= stageManagerThresholdX && gazePoint.y > 40.0 && gazePoint.y < (height - 65.0) {
            return resolveStageManagerThumbnail(gazePoint: gazePoint, screenSize: screenSize, candidates: candidates)
        }

        // 2. Top Menu Bar (Top Left & Top Right)
        if gazePoint.y <= topBarThresholdY {
            let splitX = width * 0.50
            if gazePoint.x >= splitX {
                return resolveWholeTopRight(screenSize: screenSize)
            } else {
                return resolveWholeTopLeft(screenSize: screenSize)
            }
        }

        // 3. Whole Dock (Bottom Area)
        if gazePoint.y >= dockThresholdY {
            return resolveWholeDock(screenSize: screenSize)
        }

        // 4. Main Workspace (Active Application Window)
        return resolveActiveAppWindow(screenSize: screenSize, candidates: candidates)
    }

    // MARK: - Macro State Creators

    /// Highlights the entire top-right status bar / Control Center region.
    public func resolveWholeTopRight(screenSize: LyraSize) -> ContextualHighlight {
        let barHeight = 32.0
        let startX = screenSize.width * 0.52
        let barWidth = screenSize.width - startX - 8.0
        let frame = LyraRect(x: startX, y: 3.0, width: barWidth, height: barHeight)

        return ContextualHighlight(
            kind: .topRightStatus,
            frame: frame,
            title: "Control Center & Status",
            subtitle: "Top Right",
            candidate: nil
        )
    }

    /// Highlights the entire top-left Apple menu & application menu bar.
    public func resolveWholeTopLeft(screenSize: LyraSize) -> ContextualHighlight {
        let barHeight = 32.0
        let startX = 6.0
        let barWidth = (screenSize.width * 0.48) - startX
        let frame = LyraRect(x: startX, y: 3.0, width: barWidth, height: barHeight)

        return ContextualHighlight(
            kind: .topLeftMenu,
            frame: frame,
            title: "Apple & App Menu",
            subtitle: "Top Left",
            candidate: nil
        )
    }

    /// Highlights the entire macOS Dock at the bottom of the screen.
    public func resolveWholeDock(screenSize: LyraSize) -> ContextualHighlight {
        let dockHeight = 84.0
        let dockWidth = min(screenSize.width * 0.88, 1200.0)
        let dockX = (screenSize.width - dockWidth) / 2.0
        let dockY = screenSize.height - dockHeight - 4.0
        let frame = LyraRect(x: dockX, y: dockY, width: dockWidth, height: dockHeight)

        return ContextualHighlight(
            kind: .dock,
            frame: frame,
            title: "Dock",
            subtitle: "Bottom",
            candidate: nil
        )
    }

    /// Fine-tunes vertically inside Stage Manager to calculate which specific window thumbnail
    /// is closest to gaze Y, and highlights that window thumbnail rectangle.
    public func resolveStageManagerThumbnail(
        gazePoint: LyraPoint,
        screenSize: LyraSize,
        candidates: [TargetCandidate] = []
    ) -> ContextualHighlight {
        // If accessibility scanned real Stage Manager window thumbnails, match against them
        let thumbnailCandidates = candidates.filter {
            $0.role == "StageManagerThumbnail" ||
            ($0.source == .screenRegion && $0.frame.minX <= 30.0 && $0.frame.width >= 60.0 && $0.frame.height >= 50.0)
        }

        if let best = thumbnailCandidates.min(by: { abs($0.frame.midY - gazePoint.y) < abs($1.frame.midY - gazePoint.y) }) {
            return ContextualHighlight(
                kind: .stageManager,
                frame: best.frame,
                title: best.displayName,
                subtitle: "Stage Manager Window",
                candidate: best
            )
        }

        // Geometric Stage Manager slots (calibrated to macOS 13/14 Stage Manager strip)
        let topY = 160.0
        let bottomY = screenSize.height - 110.0
        let availableHeight = max(bottomY - topY, 300.0)

        let slotCount = 4
        let slotHeight = min(availableHeight / Double(slotCount) - 16.0, 135.0)
        let slotWidth = 125.0
        let slotX = 6.0
        let spacing = (availableHeight - (Double(slotCount) * slotHeight)) / Double(slotCount - 1)

        var closestIndex = 0
        var minDistance = Double.infinity
        var closestFrame = LyraRect(x: slotX, y: topY, width: slotWidth, height: slotHeight)

        for i in 0..<slotCount {
            let y = topY + Double(i) * (slotHeight + spacing)
            let centerY = y + (slotHeight / 2.0)
            let distance = abs(gazePoint.y - centerY)

            if distance < minDistance {
                minDistance = distance
                closestIndex = i
                closestFrame = LyraRect(x: slotX, y: y, width: slotWidth, height: slotHeight)
            }
        }

        return ContextualHighlight(
            kind: .stageManager,
            frame: closestFrame,
            title: "Stage Manager (Window \(closestIndex + 1))",
            subtitle: "Left Edge",
            candidate: nil
        )
    }

    /// Highlights the active application window in the main workspace.
    public func resolveActiveAppWindow(
        screenSize: LyraSize,
        candidates: [TargetCandidate] = []
    ) -> ContextualHighlight {
        // If an active window candidate is available from accessibility, use its frame
        if let windowCandidate = candidates.first(where: {
            ($0.role == "AXWindow" || $0.role == "window") &&
            $0.frame.width > (screenSize.width * 0.35) &&
            $0.frame.height > (screenSize.height * 0.35)
        }) {
            return ContextualHighlight(
                kind: .activeAppWindow,
                frame: windowCandidate.frame,
                title: windowCandidate.displayName,
                subtitle: "Active Window",
                candidate: windowCandidate
            )
        }

        // Default workspace window frame (centered between Stage Manager and right margin)
        let leftMargin = max(screenSize.width * 0.14, 150.0)
        let topMargin = 38.0
        let bottomMargin = 96.0
        let rightMargin = 20.0

        let frame = LyraRect(
            x: leftMargin,
            y: topMargin,
            width: screenSize.width - leftMargin - rightMargin,
            height: screenSize.height - topMargin - bottomMargin
        )

        return ContextualHighlight(
            kind: .activeAppWindow,
            frame: frame,
            title: "Active Application",
            subtitle: "Main Workspace",
            candidate: nil
        )
    }
}
