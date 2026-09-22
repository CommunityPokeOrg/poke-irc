# PokeIRC

A native IRC client for **iOS** and **macOS** written in Swift and SwiftUI.

The repository contains two pieces:

| Piece | Location | What it is |
|-------|----------|------------|
| **IRCKit** | `Sources/IRCKit` | A platform-leaning Swift package: the async IRC engine, IRCv3 support, session state, and a testable conversation domain layer. Builds and tests on macOS, iOS, and Linux. |
| **PokeIRC app** | `App/` | A shared SwiftUI app (iOS 17+, macOS 14+) whose Xcode project is generated from `project.yml` with [XcodeGen](https://github.com/yonsm/XcodeGen). |

## Features

### Engine (`IRCKit`)

- **Async Swift Concurrency** client (`IRCConnection` actor): structured tasks for
  reading, writing, keepalive pings, and reconnect — cancellation-safe throughout.
- **Transports**: `NWConnection` (TLS-capable) on Apple platforms; a POSIX socket
  transport (plaintext, development only) on Linux. The transport is a protocol,
  so tests run against a fully scriptable mock.
- **RFC 1459 + IRCv3 parser/serializer**: message tags (escaping/unescaping),
  `server-time`, prefix parsing, trailing params, byte-level line splitting.
- **Capability negotiation**: `CAP LS 302` → `REQ` → `ACK/NAK` handling. Desired
  caps (`message-tags`, `server-time`, `echo-message`, `away-notify`,
  `account-tag`, `extended-join`, `multi-prefix`, `userhost-in-names`, `chghost`)
  are a set, so new caps are one-line additions.
- **SASL PLAIN** authentication with 400-byte chunking; negotiation ends via
  `CAP END` on success (903) or failure (904–907).
- **Everyday IRC**: join/part/kick/quit, PRIVMSG/NOTICE, CTCP ACTION (`/me`),
  nick changes (with automatic `_` fallback on 433), server numerics,
  NAMES/topic/channel-mode tracking in `IRCSessionState`.
- **Auto-reconnect**: exponential backoff with jitter (`ReconnectPolicy`),
  followed by re-registration and re-join of open channels.
- **Domain layer** (`IRCConversationStore`): turns events into ordered
  conversations (server log, channels, DMs) with unread counts — the view-model
  surface the UI binds to.

### App (`App/`)

- `NavigationSplitView` layout that adapts to iOS and macOS.
- Server list with live status dots, connect/disconnect/edit/delete actions.
- Conversation list (server log, channels, DMs) with unread badges.
- Message timeline with timestamps, notices, actions, joins/parts, errors;
  auto-scroll to newest.
- Composer supporting plain text plus `/join`, `/part`, `/msg`, `/me`,
  `/notice`, `/nick`, `/topic`, `/quit`, `/raw`.
- Status banner for connecting/reconnecting (with countdown and cancel) and
  failed states.
- Member list in the inspector (macOS sidebar / iOS panel).
- Accessibility labels on all interactive elements.
- Server profiles persist as JSON in Application Support; SASL passwords live
  in the **Keychain** — never on disk, never in the profile file.

## Requirements

- **App**: Xcode 16+ (built with Xcode 26), iOS 17 / macOS 14 deployment targets.
- **Engine + tests**: any Swift 6 toolchain (`swift build`, `swift test`) —
  verified on macOS and Linux.
- **Project generation**: [`xcodegen`](https://github.com/yonsm/XcodeGen)
  (`brew install xcodegen`).

## Build & test

### The engine (any platform, including Linux)

```sh
swift build
swift test          # 32 tests: parser, tags, caps, SASL, reconnect, state, store
```

### The app (macOS host)

```sh
brew install xcodegen
xcodegen generate          # produces PokeIRC.xcodeproj

# iOS Simulator build
xcodebuild -project PokeIRC.xcodeproj -scheme PokeIRC \
  -destination 'generic/platform=iOS Simulator' \
  build CODE_SIGNING_ALLOWED=NO

# macOS build
xcodebuild -project PokeIRC.xcodeproj -scheme PokeIRCMac \
  -destination 'platform=macOS' \
  build CODE_SIGNING_ALLOWED=NO
```

Then open `PokeIRC.xcodeproj` in Xcode and run either scheme. CI
(`.github/workflows/ci.yml`) runs `swift test` and both app builds on
`macos-latest`.

## Architecture

```
┌─────────────┐   AsyncStream<IRCEvent>   ┌──────────────────────────┐
│ IRCConnection│ ───────────────────────▶ │ IRCConversationStore     │
│  (actor)     │                          │  (actor, view-model)     │
└─────┬───────┘                           └───────────┬──────────────┘
      │ IRCTransport                                  │ @Published
      ▼                                               ▼
┌─────────────┐                             ┌──────────────────────────┐
│ NWConnection │ (Apple) / POSIX (Linux)    │ ConnectionController →   │
│             │  or MockTransport (tests)   │ SwiftUI views            │
└─────────────┘                             └──────────────────────────┘
```

- **Core** (`Sources/IRCKit/Core`): wire-level types — `IRCMessage`,
  `IRCParser`, tag escaping, CTCP, IRC case mapping.
- **Transport** (`Sources/IRCKit/Transport`): `IRCTransport` protocol,
  `NWConnectionTransport`, `PosixSocketTransport`.
- **Client** (`Sources/IRCKit/Client`): `IRCConnection`, configuration/SASL,
  `ReconnectPolicy`, `IRCSessionState`, `IRCEvent`, `server-time` parsing.
- **Domain** (`Sources/IRCKit/Domain`): `IRCConversationStore`, `ChatLine`,
  `IRCConversation` — presentation-ready, fully unit-testable.
- **App** (`App/`): `AppModel` (profiles, controllers), `ConnectionController`
  (event→state bridge, slash commands), and the SwiftUI views.

## Notes and current limitations

- TLS uses the system `NWConnection` trust evaluation; there is no per-server
  certificate pinning or self-signed override UI yet.
- SASL supports PLAIN only (EXTERNAL/SCRAM would slot into
  `SASLCredentials.Mechanism`).
- No bouncer/ZNC sync, `CHATHISTORY`/`batch`, DCC transfers, scripts, or
  ignore lists — the cap framework is ready for them.
- The Linux transport is plaintext-only and exists so the engine builds and
  tests everywhere; it is not the shipping path.
- `soju`-style hostnames, TLS client certificates, and proxy support are not
  implemented.
- Messages are in-memory only (no history persistence across launches).

## License

MIT — see `LICENSE`.
