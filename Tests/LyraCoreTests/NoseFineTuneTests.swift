import XCTest
@testable import LyraCore

final class NoseFineTuneTests: XCTestCase {

    func testNoseOnlyZeroJitterAtRest() {
        let controller = NoseFineTuneController(mode: .noseOnly, sensitivity: 2.0)
        let t0 = Date()

        // First frame establishes neutral pose at center
        let p0 = controller.updateNoseOnly(yaw: 0.0, pitch: 0.0, now: t0)
        XCTAssertEqual(p0.x, 0.5, accuracy: 1e-3)
        XCTAssertEqual(p0.y, 0.5, accuracy: 1e-3)

        // Send 15 frames with sensor micro-fluctuation / tremor (±0.0004 rad)
        for i in 1...15 {
            let t = t0.addingTimeInterval(Double(i) * 0.033)
            let microJitter = (i % 2 == 0 ? 1.0 : -1.0) * 0.0004
            let p = controller.updateNoseOnly(yaw: microJitter, pitch: microJitter, now: t)

            // Deadband should completely lock position with ABSOLUTELY ZERO jitter
            XCTAssertEqual(p.x, p0.x, accuracy: 1e-4, "Frame \(i) exhibited horizontal jitter!")
            XCTAssertEqual(p.y, p0.y, accuracy: 1e-4, "Frame \(i) exhibited vertical jitter!")
        }
    }

    func testNoseOnlySmoothSteering() {
        let controller = NoseFineTuneController(mode: .noseOnly, sensitivity: 2.0)
        let t0 = Date()

        _ = controller.updateNoseOnly(yaw: 0.0, pitch: 0.0, now: t0)

        // Turn head right (positive yaw: +0.04 rad)
        var p = CGPoint(x: 0.5, y: 0.5)
        for i in 1...15 {
            let t = t0.addingTimeInterval(Double(i) * 0.033)
            p = controller.updateNoseOnly(yaw: 0.04, pitch: 0.0, now: t)
        }

        // Pointer should have moved smoothly to the right (X > 0.5)
        XCTAssertGreaterThan(p.x, 0.65)
        XCTAssertEqual(p.y, 0.5, accuracy: 0.02)

        // Nod head down (negative pitch: -0.03 rad)
        for i in 16...30 {
            let t = t0.addingTimeInterval(Double(i) * 0.033)
            p = controller.updateNoseOnly(yaw: 0.04, pitch: -0.03, now: t)
        }

        // Pointer should have moved down (Y > 0.5)
        XCTAssertGreaterThan(p.y, 0.65)
    }

    func testNoseOnlyRecenter() {
        let controller = NoseFineTuneController(mode: .noseOnly, sensitivity: 2.0)
        let t0 = Date()

        // Set neutral at yaw=0
        _ = controller.updateNoseOnly(yaw: 0.0, pitch: 0.0, now: t0)

        // Steer away to yaw = 0.05
        let t1 = t0.addingTimeInterval(0.5)
        let pMoved = controller.updateNoseOnly(yaw: 0.05, pitch: 0.0, now: t1)
        XCTAssertGreaterThan(pMoved.x, 0.55)

        // Recenter while head is at yaw = 0.05
        controller.recenter()

        let t2 = t1.addingTimeInterval(0.033)
        let pRecentered = controller.updateNoseOnly(yaw: 0.05, pitch: 0.0, now: t2)

        // Center should now be at yaw = 0.05, so screen position is back at (0.5, 0.5)
        XCTAssertEqual(pRecentered.x, 0.5, accuracy: 1e-2)
        XCTAssertEqual(pRecentered.y, 0.5, accuracy: 1e-2)
    }

    func testHybridEyeSaccadeRelocatesAnchor() {
        let controller = NoseFineTuneController(mode: .hybrid, isEnabled: true, sensitivity: 2.0, saccadeThreshold: 0.08)
        let t0 = Date()

        // Initial eye fixation in center
        let p1 = controller.update(rawGaze: CGPoint(x: 0.5, y: 0.5), yaw: 0.0, pitch: 0.0, now: t0)
        XCTAssertEqual(p1.x, 0.5, accuracy: 1e-4)
        XCTAssertEqual(p1.y, 0.5, accuracy: 1e-4)

        // Large eye jump (saccade) to top-left (0.1, 0.1)
        let t1 = t0.addingTimeInterval(0.05)
        let p2 = controller.update(rawGaze: CGPoint(x: 0.1, y: 0.1), yaw: 0.0, pitch: 0.0, now: t1)
        XCTAssertEqual(p2.x, 0.1, accuracy: 1e-4)
        XCTAssertEqual(p2.y, 0.1, accuracy: 1e-4)
    }

    func testHybridNoseNudgeSteersCursorLocally() {
        let controller = NoseFineTuneController(mode: .hybrid, isEnabled: true, sensitivity: 2.0, saccadeThreshold: 0.10)
        let t0 = Date()

        _ = controller.update(rawGaze: CGPoint(x: 0.5, y: 0.5), yaw: 0.0, pitch: 0.0, now: t0)

        // User turns nose right (positive yaw: +0.02 rad)
        var p = CGPoint(x: 0.5, y: 0.5)
        for i in 1...10 {
            let t = t0.addingTimeInterval(Double(i) * 0.033)
            p = controller.update(rawGaze: CGPoint(x: 0.5, y: 0.5), yaw: 0.02, pitch: 0.0, now: t)
        }

        // Cursor should have moved to the right (x > 0.5)
        XCTAssertGreaterThan(p.x, 0.52)
        XCTAssertEqual(p.y, 0.5, accuracy: 0.01)

        // User nods head down (negative pitch: -0.02 rad)
        for i in 11...20 {
            let t = t0.addingTimeInterval(Double(i) * 0.033)
            p = controller.update(rawGaze: CGPoint(x: 0.5, y: 0.5), yaw: 0.02, pitch: -0.02, now: t)
        }

        // Cursor should have moved down (y > 0.5)
        XCTAssertGreaterThan(p.y, 0.52)
    }

    func testDisabledControllerPassesThroughRawGaze() {
        let controller = NoseFineTuneController(isEnabled: false)
        let p = controller.update(rawGaze: CGPoint(x: 0.35, y: 0.42), yaw: 0.1, pitch: -0.2)
        XCTAssertEqual(p.x, 0.35, accuracy: 1e-4)
        XCTAssertEqual(p.y, 0.42, accuracy: 1e-4)
    }

    func testLocalFixationLockHoldsAtNonCenterTarget() {
        let controller = NoseFineTuneController(mode: .noseOnly, sensitivity: 2.0, deadband: 0.009)
        let t0 = Date()

        // 1. Establish neutral at center (0.0, 0.0)
        _ = controller.updateNoseOnly(yaw: 0.0, pitch: 0.0, now: t0)

        // 2. Steer head to right (yaw = 0.05) over 15 frames
        var pMoved = CGPoint(x: 0.5, y: 0.5)
        for i in 1...15 {
            let t = t0.addingTimeInterval(Double(i) * 0.033)
            pMoved = controller.updateNoseOnly(yaw: 0.05, pitch: 0.0, now: t)
        }
        XCTAssertGreaterThan(pMoved.x, 0.70)

        // 3. User holds head still at this target for 5 frames -> Fixation Lock engages
        var pTarget = pMoved
        for i in 16...20 {
            let t = t0.addingTimeInterval(Double(i) * 0.033)
            pTarget = controller.updateNoseOnly(yaw: 0.05, pitch: 0.0, now: t)
        }

        // 4. Send 30 frames with realistic camera sensor noise (±0.004) around yaw = 0.05
        for i in 21...50 {
            let t = t0.addingTimeInterval(Double(i) * 0.033)
            let noise = (i % 2 == 0 ? 1.0 : -1.0) * 0.004
            let p = controller.updateNoseOnly(yaw: 0.05 + noise, pitch: noise, now: t)

            // Must stay 100.000% locked at the target position with zero drift and zero jitter
            XCTAssertEqual(p.x, pTarget.x, accuracy: 1e-5, "Frame \(i) exhibited drift at target position!")
            XCTAssertEqual(p.y, pTarget.y, accuracy: 1e-5, "Frame \(i) exhibited drift at target position!")
        }
    }

    func testInvertAxes() {
        let controller = NoseFineTuneController(
            mode: .noseOnly,
            sensitivity: 2.0,
            invertX: true,
            invertY: true
        )
        let t0 = Date()
        _ = controller.updateNoseOnly(yaw: 0.0, pitch: 0.0, now: t0)

        // Turn head right (positive yaw: +0.04 rad) with invertX = true -> pointer moves left (X < 0.5)
        var p = CGPoint(x: 0.5, y: 0.5)
        for i in 1...15 {
            let t = t0.addingTimeInterval(Double(i) * 0.033)
            p = controller.updateNoseOnly(yaw: 0.04, pitch: 0.0, now: t)
        }
        XCTAssertLessThan(p.x, 0.35)

        // Nod head down (negative pitch: -0.03 rad) with invertY = true -> pointer moves up (Y < 0.5)
        for i in 16...30 {
            let t = t0.addingTimeInterval(Double(i) * 0.033)
            p = controller.updateNoseOnly(yaw: 0.04, pitch: -0.03, now: t)
        }
        XCTAssertLessThan(p.y, 0.35)
    }
}
