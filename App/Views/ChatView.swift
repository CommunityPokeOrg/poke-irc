import IRCKit
import SwiftUI

/// Message timeline, composer, status banner and member inspector for
/// the selected conversation of one server connection.
struct ChatView: View {
    @ObservedObject var controller: ConnectionController
    @State private var draft = ""
    @State private var showingMembers = false

    var body: some View {
        VStack(spacing: 0) {
            if !controller.isConnected {
                StatusBanner(controller: controller)
            }
            MessageListView(controller: controller)
            ComposerView(draft: $draft) {
                let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return }
                draft = ""
                Task {
                    await controller.submit(text, to: controller.selectedConversationID)
                }
            }
        }
        .navigationTitle(controller.profile.displayName)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingMembers.toggle()
                } label: {
                    Label("Members", systemImage: "person.2")
                }
                .disabled(controller.selectedConversation?.members.isEmpty != false)
                .accessibilityLabel("Show channel member list")
            }
        }
        .inspector(isPresented: $showingMembers) {
            MemberListView(members: controller.selectedConversation?.members ?? [])
        }
        .task {
            await controller.markConversationRead(controller.selectedConversationID)
        }
    }
}

/// Reconnect/status feedback strip shown above the timeline.
private struct StatusBanner: View {
    @ObservedObject var controller: ConnectionController

    var body: some View {
        HStack(spacing: 8) {
            if case .reconnecting = controller.phase {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
            }
            Text(controller.statusText)
                .font(.callout)
            Spacer()
            if case .reconnecting = controller.phase {
                Button("Cancel") {
                    Task { await controller.disconnect() }
                }
                .controlSize(.small)
            } else if !controller.isConnected {
                Button("Connect") {
                    Task { await controller.connect() }
                }
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.quaternary)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Connection status: \(controller.statusText)")
    }
}

private struct MessageListView: View {
    @ObservedObject var controller: ConnectionController

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(controller.selectedConversation?.lines ?? []) { line in
                        ChatLineView(line: line)
                            .id(line.id)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .accessibilityLabel("Message timeline")
            .onChange(of: controller.selectedConversation?.lines.count) {
                if let last = controller.selectedConversation?.lines.last {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }
}

private struct ChatLineView: View {
    let line: ChatLine

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(line.timestamp, style: .time)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
            switch line.kind {
            case .event, .status:
                Text(line.text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .italic()
            case .error:
                Label(line.text, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.red)
            case .action:
                Text("* \(line.sender) \(line.text)")
                    .font(.callout)
                    .foregroundStyle(.purple)
            case .notice:
                Text("-\(line.sender)- \(line.text)")
                    .font(.callout)
                    .foregroundStyle(.orange)
            case .message:
                Text(line.sender.isEmpty ? "•" : line.sender)
                    .font(.callout.bold())
                    .foregroundStyle(line.isOutgoing ? .secondary : Color.accentColor)
                + Text("  \(line.text)")
                    .font(.callout)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct ComposerView: View {
    @Binding var draft: String
    var onSend: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            TextField("Message", text: $draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...5)
                .onSubmit(onSend)
                .accessibilityLabel("Message input — type /help commands or plain text")
            Button(action: onSend) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
            }
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel("Send message")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

private struct MemberListView: View {
    let members: [String]

    var body: some View {
        List(members, id: \.self) { member in
            Label(member, systemImage: member.hasPrefix("@") ? "crown" : "person")
        }
        .navigationTitle("Members (\(members.count))")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .inspectorColumnWidth(min: 160, ideal: 200, max: 240)
    }
}
