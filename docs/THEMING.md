# PokeIRC Theming — CSS/JS API

PokeIRC renders the chat log through a **sandboxed WebKit theme engine**
(inspired by Colloquy/Textual) with a native SwiftUI renderer as fallback.
A theme is a folder containing a manifest, one CSS file, and one JS file.

## Installing a theme

Drop the folder into:

```
~/Library/Application Support/PokeIRC/Themes/<your-theme-id>/
    theme.json
    chat.css
    chat.js
```

Bundled themes ship inside the app under `Themes/`. The Settings pane
lists every theme that loads cleanly.

## Manifest — `theme.json`

```json
{
  "id": "my-theme",          // unique, lowercase
  "name": "My Theme",        // display name in Settings
  "version": "1.0",
  "author": "you",
  "css": "chat.css",         // plain filename, no slashes
  "js": "chat.js"            // plain filename, no slashes
}
```

`css` and `js` must be bare filenames — paths are rejected so a theme can
never read outside its own directory.

## Message contract

For each line the app calls into the page with a message object:

```jsonc
{
  "id": "uuid",
  "kind": "privmsg",        // privmsg notice action join part quit nick
                            // topic mode kick system error highlight
  "network": "Libera",
  "buffer": "#irc",
  "sender": "wolfy",        // absent on system lines
  "text": "hello world",
  "timestamp": "2026-09-22T16:54:00Z",  // IRCv3 server-time when offered
  "tags": {"account": "wolfy", "batch": "…"},
  "self": false,            // sent by you
  "highlight": true         // your nick was mentioned
}
```

## JavaScript API

The bridge (`window.PokeIRC`) is injected before your script runs.
Implement one global hook:

```js
window.PokeIRCTheme = {
  // Return an HTMLElement to append, or null to use the built-in renderer.
  renderMessage(msg, helpers) { /* … */ }
};
```

`helpers` provided by the bridge:

| Helper | Description |
| --- | --- |
| `helpers.escapeHTML(s)` | entity-escape untrusted text |
| `helpers.formatTime(iso)` | local HH:MM |
| `helpers.nickColor(nick)` | deterministic HSL color per nick |
| `helpers.linkify(text)` | escaped text with `<a data-poke-link>` around http(s) URLs |

### Theme → app intents

Post to `window.webkit.messageHandlers.pokeIRC` (or just use the
attributes below — the bridge already delegates clicks on them):

| Message / attribute | Effect |
| --- | --- |
| `{type:"link", url}` / `data-poke-link` | opens http/https in the system browser |
| `{type:"nick", nick}` / `data-poke-nick` | inserts "nick: " in the composer |
| `{type:"ready"}` | sent automatically once DOM is ready |

## Security boundaries

* The page is **fully self-contained**: theme CSS and JS are injected
  inline into a generated HTML document — no file or network loads.
* A strict CSP applies: `default-src 'none'`, no `connect-src`, no
  `frame-src`, `img-src` limited to `data:`.
* The navigation delegate cancels *all* navigations; links reach the
  system browser only through the whitelisted `link` intent above.
* Message `text` is a JSON string, never raw HTML — a theme can only
  inject markup it builds itself.
* If the page fails to load or the user picks "Native SwiftUI" in
  Settings, the app renders the same `ChatMessage` list natively.
