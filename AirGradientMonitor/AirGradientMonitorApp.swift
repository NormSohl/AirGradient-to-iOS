import SwiftUI

@main
struct AirGradientMonitorApp: App {
    @State private var model = MonitorsModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            DashboardView()
                .environment(model)
        }
        .onChange(of: scenePhase) { _, phase in
            // Polling only while the app is actually on screen. A background
            // poll would be refused anyway once the app is suspended, and the
            // history flush here is what makes the charts survive a quit.
            switch phase {
            case .active: model.startPolling()
            default: model.stopPolling()
            }
        }
    }
}
