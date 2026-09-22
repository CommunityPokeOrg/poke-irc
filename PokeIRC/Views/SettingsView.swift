import SwiftUI

/// App preferences (macOS Settings scene; reachable via a sheet on iOS).
struct SettingsView: View {
    @AppStorage("chatRenderer") private var renderer = "web"
    @AppStorage("themeID") private var themeID = ThemeEngine.defaultThemeID

    private var themes: [ResolvedTheme] { ThemeEngine.allThemes() }

    var body: some View {
        Form {
            Section("Chat Rendering") {
                Picker("Renderer", selection: $renderer) {
                    Text("WebKit theme engine").tag("web")
                    Text("Native SwiftUI").tag("native")
                }
                Picker("Theme", selection: $themeID) {
                    ForEach(themes, id: \.manifest.id) { theme in
                        Text("\(theme.manifest.name) \(theme.manifest.version)")
                            .tag(theme.manifest.id)
                    }
                }
                .disabled(renderer != "web")
                Text("Themes live in ~/Library/Application Support/PokeIRC/Themes — "
                     + "see docs/THEMING.md for the CSS/JS API.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        #if os(macOS)
        .frame(width: 480, height: 220)
        #endif
    }
}
