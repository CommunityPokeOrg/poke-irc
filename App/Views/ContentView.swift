import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationTitle("PokeIRC")
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            model.showingNewServer = true
                        } label: {
                            Label("Add Server", systemImage: "plus")
                        }
                        .accessibilityLabel("Add a new IRC server")
                    }
                }
        } detail: {
            if let profileID = model.selectedProfileID,
               let profile = model.profiles.first(where: { $0.id == profileID }) {
                ChatView(controller: model.controller(for: profile))
                    .id(profileID)
            } else {
                ContentUnavailableView {
                    Label("No Server Selected", systemImage: "network")
                } description: {
                    Text("Add or select an IRC server to get started.")
                }
            }
        }
        .sheet(isPresented: $model.showingNewServer) {
            ServerEditorView()
        }
        .sheet(item: $model.editingProfile) { profile in
            ServerEditorView(existing: profile)
        }
    }
}
