import AppKit
import SwiftUI

/// Custom borderless window that can become key and handle ESC key to close
final class FullscreenCalibrationWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // ESC key
            OverlayWindowManager.shared.closeCalibrationWindow()
        } else {
            super.keyDown(with: event)
        }
    }
}

@MainActor
public final class OverlayWindowManager {
    public static let shared = OverlayWindowManager()

    private var calibrationWindow: NSWindow?
    private var indicatorWindow: NSWindow?

    private init() {}

    /// The screen every overlay is drawn against.
    ///
    /// ponytail: single display, `NSScreen.main`. Multi-display needs per-screen overlay
    /// windows and gaze coordinates translated into the target screen's space; add when
    /// someone actually runs Lyra across two monitors.
    private var targetScreen: NSScreen? { NSScreen.main }

    // MARK: - Fullscreen Calibration Window

    public func showCalibrationWindow(viewModel: AppViewModel) {
        guard let screen = targetScreen else { return }

        closeCalibrationWindow()

        let window = FullscreenCalibrationWindow(
            contentRect: screen.frame,
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = NSHostingController(
            rootView: CalibrationOverlayView(viewModel: viewModel)
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.isReleasedWhenClosed = false
        window.hasShadow = false
        window.ignoresMouseEvents = false

        self.calibrationWindow = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    public func closeCalibrationWindow() {
        calibrationWindow?.orderOut(nil)
        calibrationWindow?.close()
        calibrationWindow = nil
    }

    // MARK: - Gaze Indicator Overlay Window

    public func setIndicatorVisible(_ visible: Bool, viewModel: AppViewModel) {
        if visible {
            showIndicatorWindow(viewModel: viewModel)
        } else {
            closeIndicatorWindow()
        }
    }

    private func showIndicatorWindow(viewModel: AppViewModel) {
        guard indicatorWindow == nil, let screen = targetScreen else { return }

        let window = NSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = NSHostingController(
            rootView: GazeIndicatorOverlay(viewModel: viewModel)
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.isReleasedWhenClosed = false
        window.hasShadow = false
        window.orderFrontRegardless()

        self.indicatorWindow = window
    }

    private func closeIndicatorWindow() {
        indicatorWindow?.orderOut(nil)
        indicatorWindow?.close()
        indicatorWindow = nil
    }
}
