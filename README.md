# PokeIRC

A native IRC client for **iOS and macOS** — SwiftUI shell, async Swift
Concurrency engine, and a Colloquy-style **WebKit theme layer** for fully
custom CSS/JS chat rendering.

## Architecture

```
PokeIRC/                  → universal SwiftUI app target (iOS + macOS)
  Views/                  → sidebar, chat panel, server editor, settings
  Rendering/
    ThemeEngine.swift     → theme discovery, manifest validation, page assembly
    WebChatLogView.swift  → sandboxed WKWebView renderer + JS bridge
    NativeChatLogView.swift → SwiftUI fallback renderer
    ChatLogView.swift     → picks the renderer (Settings → "Chat Rendering")
  Themes/Default/         → bundled theme (theme.json + chat.css + chat.js)
  ServerConnection.swift  → IRCSession → ChatMessage routing, buffers, members
  AppStore.swift          → saved servers, selection, persistence

IRCKit/                   → SwiftPM package, pure networking/protocol core
  Sources/IRCKit/
    Core/                 → IRCMessage model, parser, serializer (IRCv3 tags)
    Transport/            → IRCTransport protocol + NWConnection TCP/TLS impl
    Capabilities/         → CAP LS/REQ/ACK/NAK state machine
    SASL/                 → SASL PLAIN authenticator (chunked AUTHENTICATE)
    Session/              → IRCSession actor — connection lifecycle,
                            registration, capability negotiation, auto-PONG
  Tests/IRCKitTests/      → 27 unit tests incl. full registration flows
```

### IRCv3 foundations

- **message-tags** — `@key=value` parsing with escape sequences both ways
- **capability negotiation** — `CAP LS 302` (multiline), `REQ`/`ACK`/`NAK`,
  `CAP END` gated on negotiation + SASL completion
- **SASL** — `PLAIN` mechanism, ≤400-byte `AUTHENTICATE` chunks,
  900–908 numeric handling
- **server-time** — tag surfaced as a `Date` on every message
- **transport** — `NWConnection`-based TCP/TLS line protocol with
  pluggable `IRCTransport` for tests
- **lifecycle** — `disconnected → connecting → registering → online`,
  clean `QUIT`, auto-PONG, nick tracking

## Theming (custom CSS/JS)

The chat log runs inside a locked-down `WKWebView`: a self-contained page
with `default-src 'none'` CSP, all navigation denied, and a narrow JS
bridge. Themes implement `PokeIRCTheme.renderMessage(msg, helpers)` and
can post whitelisted intents (open link, insert nick) back to the app.
Drop a theme folder into `~/Library/Application Support/PokeIRC/Themes/`
and pick it in Settings. **See [docs/THEMING.md](docs/THEMING.md).**

## Build & test

```sh
# Xcode project is generated — edit project.yml, not the .xcodeproj
brew install xcodegen && xcodegen

# Engine unit tests (fast, no app needed)
cd IRCKit && swift test

# macOS app build
xcodebuild -scheme PokeIRC -destination 'platform=macOS' build

# iOS Simulator build
xcodebuild -scheme PokeIRC \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

## Roadmap

- Keychain-backed SASL credential store (currently UserDefaults)
- ZNC bouncer / `chathistory` support, BATCH playbacks
- `labeled-response`, `draft/extended-isupport`, OTR?
- iCloud-synced servers & themes, iPad multitasking polish
