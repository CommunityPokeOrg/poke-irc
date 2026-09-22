import SwiftUI

/// Chooses the active renderer for a buffer:
/// the WebKit theme engine, or the native SwiftUI fallback.
struct ChatLogView: View {
    @ObservedObject var buffer: ChatBuffer
    @ObservedObject var server: ServerConnection

    @AppStorage("chatRenderer") private var renderer = "web"
    @AppStorage("themeID") private var themeID = ThemeEngine.defaultThemeID

    var onLink: (URL) -> Void = { _ in }
    var onNickTap: (String) -> Void = { _ in }

    var body: some View {
        Group {
            if renderer == "web", let theme = resolvedTheme {
                WebChatLogView(theme: theme, messages: buffer.messages,
                               onLink: onLink, onNickTap: onNickTap)
            } else {
                NativeChatLogView(messages: buffer.messages,
                                  onNickTap: onNickTap)
            }
        }
    }

    /// Falls back to the bundled default, then to native when no theme
    /// resolves at all.
    private var resolvedTheme: ResolvedTheme? {
        ThemeEngine.theme(id: themeID)
            ?? ThemeEngine.theme(id: ThemeEngine.defaultThemeID)
    }
}
