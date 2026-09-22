import SwiftUI

/// Pure-SwiftUI fallback renderer — used when the user selects the
/// native renderer or when WebKit fails to load a theme page.
struct NativeChatLogView: View {
    let messages: [ChatMessage]
    var onNickTap: (String) -> Void = { _ in }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(messages) { message in
                        row(message)
                            .id(message.id)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .onChange(of: messages.count) { _, _ in
                if let last = messages.last {
                    withAnimation(.none) { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ m: ChatMessage) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(m.timestamp, style: .time)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            if let sender = m.sender {
                Text(sender)
                    .font(.body.weight(.medium))
                    .foregroundStyle(nickColor(sender))
                    .onTapGesture { onNickTap(sender) }
            }
            Text(displayText(m))
                .font(.body)
                .foregroundStyle(textColor(m))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func displayText(_ m: ChatMessage) -> String {
        switch m.kind {
        case .action: return "* \(m.sender ?? "") \(m.text)"
        case .join, .part, .quit, .nick, .topic, .mode, .kick,
             .system, .error:
            return "— \(m.text)"
        default: return m.text
        }
    }

    private func textColor(_ m: ChatMessage) -> Color {
        switch m.kind {
        case .highlight: return .yellow
        case .error: return .red
        case .notice: return .orange
        case .join, .part, .quit, .nick, .topic, .mode, .kick, .system:
            return .secondary
        default: return .primary
        }
    }

    private func nickColor(_ nick: String) -> Color {
        var hash = 0
        for u in nick.unicodeScalars { hash = (hash &* 31 &+ Int(u.value)) & 0x7fffffff }
        return Color(hue: Double(hash % 360) / 360.0, saturation: 0.55, brightness: 0.8)
    }
}
