import SwiftUI
import IRCKit

struct ContentView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationTitle("PokeIRC")
                .toolbar { sidebarToolbar }
        } detail: {
            if let buffer = store.selectedBuffer, let server = store.selectedServer {
                ChatPanelView(server: server, buffer: buffer)
            } else {
                ContentUnavailableView("No buffer selected",
                                       systemImage: "bubble.left.and.bubble.right",
                                       description: Text("Connect to a network to start chatting."))
            }
        }
        .sheet(isPresented: $store.showServerEditor) {
            ServerEditorView()
                .environmentObject(store)
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $store.selection) {
            ForEach(store.servers) { server in
                Section {
                    ForEach(server.buffers) { buffer in
                        BufferRow(buffer: buffer)
                            .tag(buffer.id)
                            .onTapGesture { store.select(buffer) }
                    }
                } header: {
                    HStack {
                        Circle()
                            .fill(stateColor(server.state))
                            .frame(width: 8, height: 8)
                        Text(server.networkName).font(.headline)
                        Spacer()
                        if server.state == .disconnected {
                            Button("Connect") { server.connect() }
                                .buttonStyle(.borderless)
                                .font(.caption)
                        }
                    }
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var sidebarToolbar: some ToolbarContent {
        ToolbarItem {
            Button { store.showServerEditor = true } label: {
                Label("Add Server", systemImage: "plus")
            }
        }
        #if os(macOS)
        ToolbarItem {
            Button { store.connectAll() } label: {
                Label("Connect All", systemImage: "bolt.horizontal")
            }
        }
        #endif
    }

    private func stateColor(_ state: IRCSessionState) -> Color {
        switch state {
        case .online: return .green
        case .connecting, .registering: return .orange
        case .disconnecting: return .yellow
        case .disconnected: return .gray
        }
    }
}

private struct BufferRow: View {
    @ObservedObject var buffer: ChatBuffer

    var body: some View {
        HStack {
            Text(buffer.name)
            Spacer()
            if buffer.unread > 0 {
                Text("\(buffer.unread)")
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.blue, in: Capsule())
                    .foregroundStyle(.white)
            }
        }
    }
}

/// Chat pane: topic bar, log, member list (channels), composer.
struct ChatPanelView: View {
    @ObservedObject var server: ServerConnection
    @ObservedObject var buffer: ChatBuffer
    @State private var draft = ""
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 0) {
            if let topic = buffer.topic, !topic.isEmpty {
                Text(topic)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.quaternary.opacity(0.4))
            }
            ChatLogView(buffer: buffer, server: server,
                        onLink: { openURL($0) },
                        onNickTap: { draft += "\($0): " })
            Divider()
            HStack {
                TextField(buffer.isChannel ? "Message \(buffer.name)" : "Message",
                          text: $draft)
                    .textFieldStyle(.plain)
                    .padding(10)
                    .onSubmit(send)
                Button(action: send) {
                    Image(systemName: "paperplane.fill")
                }
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                .padding(.trailing, 10)
            }
        }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        server.send(text, to: buffer)
    }
}
