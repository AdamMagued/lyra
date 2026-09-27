import SwiftUI
import AppKit

@main
struct LyraApp: App {
    @StateObject private var viewModel = AppViewModel()

    var body: some Scene {
        Window("Lyra", id: "dashboard") {
            MainDashboardView(viewModel: viewModel)
        }
        .windowResizability(.contentSize)

        MenuBarExtra {
            Button(viewModel.snapshot.isEngineRunning ? "Stop engine" : "Start engine") {
                viewModel.toggleEngine()
            }

            Divider()

            // Ungated, like the dashboard button: `beginCalibration` starts the engine
            // itself, so gating it only ever produced a menu item that did nothing and
            // said nothing about why.
            Button(viewModel.isCalibrated ? "Recalibrate…" : "Calibrate…") {
                viewModel.startCalibration()
            }
            .disabled(viewModel.isCalibrating)

            Divider()

            Button(viewModel.snapshot.isSelectionModeActive ? "Stop selecting" : "Start selecting") {
                viewModel.send(viewModel.snapshot.isSelectionModeActive ? .stopTracking : .startTracking)
            }
            .disabled(!viewModel.snapshot.isEngineRunning)

            Divider()

            Button("Quit Lyra") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        } label: {
            Image(systemName: viewModel.snapshot.isSelectionModeActive ? "eye.fill" : "eye")
        }
    }
}
