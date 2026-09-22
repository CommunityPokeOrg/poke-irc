import SwiftUI

@main
struct PokeIRCApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
        }
        #if os(macOS)
        .defaultSize(width: 960, height: 620)
        #endif
    }
}
