import Foundation

/// Lyra's own geometry primitives.
///
/// The core deliberately does not use `CGPoint`, `CGRect` or `CGSize`. On Apple platforms
/// those come from CoreGraphics; on Windows and Linux they do not exist at all, and even
/// the Foundation-provided approximations differ in behaviour. Since `docs/AGENTS.md`
/// forbids a shared module depending on an OS-specific API — and since the eventual
/// Windows and Linux builds need the same targeting logic — the shared layer defines its
/// own.
///
/// These are plain `Double` structs. Platform adapters convert at their boundary, which
/// is a handful of lines in each of a few files, and in exchange the entire targeting,
/// calibration and policy layer is portable and testable without a display.
///
/// Coordinate convention throughout Lyra: origin at the **top-left** of the screen, y
/// increasing **downwards**, units are screen points. That matches how macOS reports
/// accessibility frames and how a user thinks about "the top of the screen", and having
/// one convention everywhere is what stops the classic y-flip bug.

public struct LyraPoint: Sendable, Equatable, Codable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public static let zero = LyraPoint(x: 0, y: 0)

    public func distance(to other: LyraPoint) -> Double {
        ((x - other.x) * (x - other.x) + (y - other.y) * (y - other.y)).squareRoot()
    }
}

public struct LyraSize: Sendable, Equatable, Codable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }

    public static let zero = LyraSize(width: 0, height: 0)

    public var area: Double { width * height }
}

public struct LyraRect: Sendable, Equatable, Codable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public init(origin: LyraPoint, size: LyraSize) {
        self.init(x: origin.x, y: origin.y, width: size.width, height: size.height)
    }

    public static let zero = LyraRect(x: 0, y: 0, width: 0, height: 0)

    public var minX: Double { x }
    public var minY: Double { y }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }
    public var center: LyraPoint { LyraPoint(x: midX, y: midY) }
    public var area: Double { width * height }

    public func contains(_ point: LyraPoint) -> Bool {
        point.x >= minX && point.x <= maxX && point.y >= minY && point.y <= maxY
    }

    public func intersects(_ other: LyraRect) -> Bool {
        !(other.minX > maxX || other.maxX < minX || other.minY > maxY || other.maxY < minY)
    }

    public func intersection(_ other: LyraRect) -> LyraRect {
        let newMinX = Swift.max(minX, other.minX)
        let newMinY = Swift.max(minY, other.minY)
        let newMaxX = Swift.min(maxX, other.maxX)
        let newMaxY = Swift.min(maxY, other.maxY)
        guard newMaxX > newMinX, newMaxY > newMinY else { return .zero }
        return LyraRect(x: newMinX, y: newMinY, width: newMaxX - newMinX, height: newMaxY - newMinY)
    }

    public func insetBy(dx: Double, dy: Double) -> LyraRect {
        LyraRect(x: x + dx, y: y + dy, width: width - dx * 2, height: height - dy * 2)
    }

    /// Shortest distance from a point to the rectangle. Zero when the point is inside.
    public func distance(to point: LyraPoint) -> Double {
        let dx = Swift.max(minX - point.x, 0, point.x - maxX)
        let dy = Swift.max(minY - point.y, 0, point.y - maxY)
        return (dx * dx + dy * dy).squareRoot()
    }
}
