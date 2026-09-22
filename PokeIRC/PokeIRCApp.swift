import SwiftUI

@main
struct PokeIRCApp: App {
    @StateObject private var store = AppStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                #if os(macOS)
                .frame(minWidth: 720, minHeight: 480)
                #endif
        }
        #if os(macOS)
        .windowStyle(.automatic)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Connection…") { store.showServerEditor = true }
                    .keyboardShortcut("n")
            }
        }
        #endif

        #if os(macOS)
        Settings {
            SettingsView()
                .environmentObject(store)
        }
        #endif
    }
}
