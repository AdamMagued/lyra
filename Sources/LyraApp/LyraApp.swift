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

            Button("Calibrate…") { viewModel.startCalibration() }
                .disabled(!viewModel.snapshot.isEngineRunning)
            Button("Recalibrate (quick)") { viewModel.startCalibration(quick: true) }
                .disabled(!viewModel.snapshot.isEngineRunning)

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
