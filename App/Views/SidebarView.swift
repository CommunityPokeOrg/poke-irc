import IRCKit
import SwiftUI

/// Sidebar: saved servers (with status) and, under the selected server,
/// its conversations.
struct SidebarView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        List(selection: $model.selectedProfileID) {
            Section("Servers") {
                ForEach(model.profiles) { profile in
                    ServerRowView(profile: profile)
                        .tag(profile.id)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            model.selectedProfileID = profile.id
                        }
                }
                .onDelete { indexSet in
                    indexSet.map { model.profiles[$0] }.forEach { model.delete(profile: $0) }
                }
            }

            if let profileID = model.selectedProfileID,
               let profile = model.profiles.first(where: { $0.id == profileID }) {
                ConversationListView(controller: model.controller(for: profile))
            }
        }
        .listStyle(.sidebar)
    }
}

private struct ServerRowView: View {
    @EnvironmentObject private var model: AppModel
    let profile: ServerProfile

    var body: some View {
        let controller = model.controller(for: profile)
        HStack(spacing: 8) {
            Circle()
                .fill(controller.isConnected ? .green : .secondary)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.displayName)
                    .font(.headline)
                Text("\(profile.host):\(profile.port)\(profile.useTLS ? " (TLS)" : "")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Button("Edit…") { model.editingProfile = profile }
                if controller.isConnected {
                    Button("Disconnect") {
                        Task { await model.disconnect(profile) }
                    }
                } else {
                    Button("Connect") {
                        Task { await model.connect(profile) }
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .accessibilityLabel("Server actions for \(profile.displayName)")
            }
            .menuStyle(.borderlessButton)
        }
        .contextMenu {
            Button("Edit…") { model.editingProfile = profile }
            Button("Delete", role: .destructive) { model.delete(profile: profile) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(profile.displayName), \(controller.statusText)")
    }
}

private struct ConversationListView: View {
    @ObservedObject var controller: ConnectionController

    var body: some View {
        Section("Conversations") {
            ForEach(controller.conversations) { conversation in
                Button {
                    controller.selectedConversationID = conversation.id
                    Task { await controller.markConversationRead(conversation.id) }
                } label: {
                    HStack {
                        Label {
                            Text(conversation.title)
                        } icon: {
                            Image(systemName: icon(for: conversation))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if conversation.unreadCount > 0 {
                            Text("\(conversation.unreadCount)")
                                .font(.caption2.bold())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.tint, in: Capsule())
                                .foregroundStyle(.white)
                        }
                    }
                }
                .buttonStyle(.plain)
                .fontWeight(controller.selectedConversationID == conversation.id ? .semibold : .regular)
                .accessibilityLabel("\(conversation.title), \(conversation.unreadCount) unread")
            }
        }
    }

    private func icon(for c: IRCConversation) -> String {
        switch c.kind {
        case .server: return "server.rack"
        case .channel: return "number"
        case .direct: return "person"
        }
    }
}
