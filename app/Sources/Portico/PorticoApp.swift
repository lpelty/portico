import SwiftUI

/// The app entry point. An empty window for now; the real window lands with
/// the model and views in later tasks.
@main
struct PorticoApp: App {
    var body: some Scene {
        WindowGroup("Portico") {
            Text("Portico")
                .frame(minWidth: 480, minHeight: 320)
        }
    }
}
