import Foundation

/// A theme's `theme.json` manifest. A theme directory contains this
/// manifest plus the referenced CSS and JS files.
struct ThemeManifest: Codable, Equatable {
    var id: String
    var name: String
    var version: String = "1.0"
    var author: String = ""
    /// Stylesheet filename inside the theme directory (required).
    var css: String
    /// JavaScript filename inside the theme directory (required).
    var js: String
}

/// A theme with its source loaded into memory, ready to be injected
/// into the sandboxed WebKit page.
struct ResolvedTheme: Equatable {
    var manifest: ThemeManifest
    var cssText: String
    var jsText: String
    /// nil for the bundled default; custom themes keep their directory.
    var sourceDirectory: URL?
}

/// Loads and validates themes from the app bundle and the user's
/// `~/Library/Application Support/PokeIRC/Themes/<id>/` directory, and
/// renders the fully self-contained HTML page the WebKit log runs.
enum ThemeEngine {

    static let defaultThemeID = "default"

    // MARK: - Discovery

    /// Every usable theme: bundled first, then user-installed.
    static func allThemes() -> [ResolvedTheme] {
        bundledThemes() + userThemes()
    }

    static func bundledThemes() -> [ResolvedTheme] {
        guard let root = Bundle.main.resourceURL?.appendingPathComponent("Themes")
        else { return [] }
        return themes(under: root)
    }

    /// User themes live outside the sandboxed page; they are read once
    /// and injected inline, so they never get file-system access at runtime.
    static func userThemes() -> [ResolvedTheme] {
        let root = userThemesDirectory()
        return themes(under: root)
    }

    static func userThemesDirectory() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask).first!
        return support.appendingPathComponent("PokeIRC/Themes", isDirectory: true)
    }

    static func theme(id: String) -> ResolvedTheme? {
        allThemes().first { $0.manifest.id == id }
    }

    // MARK: - Loading

    private static func themes(under root: URL) -> [ResolvedTheme] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil)
        else { return [] }
        return entries.compactMap { dir -> ResolvedTheme? in
            let manifestURL = dir.appendingPathComponent("theme.json")
            guard let data = try? Data(contentsOf: manifestURL),
                  let manifest = try? JSONDecoder().decode(ThemeManifest.self,
                                                           from: data)
            else { return nil }
            // Only plain filenames — no path traversal into arbitrary files.
            guard !manifest.css.contains("/"), !manifest.js.contains("/"),
                  let css = try? String(contentsOf: dir.appendingPathComponent(manifest.css),
                                        encoding: .utf8),
                  let js = try? String(contentsOf: dir.appendingPathComponent(manifest.js),
                                       encoding: .utf8)
            else { return nil }
            return ResolvedTheme(manifest: manifest, cssText: css, jsText: js,
                                 sourceDirectory: dir)
        }
    }

    // MARK: - Page assembly

    /// The complete, self-contained HTML document loaded into the
    /// WKWebView. Theme CSS and JS are injected inline so the page has
    /// zero external references and can be locked down with a strict
    /// Content-Security-Policy.
    static func pageHTML(theme: ResolvedTheme) -> String {
        """
        <!doctype html>
        <html><head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:; font-src data:; media-src 'none'; connect-src 'none'; object-src 'none'; frame-src 'none'; worker-src 'none'; form-action 'none'; base-uri 'none'">
        <style>
          html,body{margin:0;padding:0;height:100%;background:#0f1115;color:#e6e8eb;
                    font:14px/1.45 -apple-system,BlinkMacSystemFont,"SF Pro Text",sans-serif}
          #log{padding:8px 10px 20px;overflow-wrap:anywhere}
          .msg{white-space:pre-wrap}
          a{color:#6ea8ff}
        </style>
        <style id="theme-css">
        \(theme.cssText)
        </style>
        </head><body>
        <div id="log" role="log" aria-live="polite"></div>
        <script>
        \(bridgeJS)
        </script>
        <script id="theme-js">
        \(theme.jsText)
        </script>
        </body></html>
        """
    }

    /// The app-side JS contract injected before the theme script.
    /// See docs/THEMING.md for the full API.
    static let bridgeJS = """
      window.PokeIRC = (function () {
        const log = document.getElementById('log');
        const queue = [];
        let ready = false;

        const helpers = {
          escapeHTML(s) {
            return String(s).replace(/[&<>"']/g, c => ({
              '&': '&amp;', '<': '&lt;', '>': '&gt;',
              '"': '&quot;', "'": '&#39;'
            }[c]));
          },
          formatTime(iso) {
            try {
              const d = new Date(iso);
              return d.toLocaleTimeString([], {hour: '2-digit', minute: '2-digit'});
            } catch (e) { return ''; }
          },
          nickColor(nick) {
            let h = 0;
            for (const c of String(nick)) h = (h * 31 + c.charCodeAt(0)) >>> 0;
            return `hsl(${h % 360}, 65%, 68%)`;
          },
          linkify(text) {
            const esc = helpers.escapeHTML(text);
            return esc.replace(
              /(https?:\\/\\/[^\\s<>"']+)/g,
              '<a href="$1" data-poke-link="$1">$1</a>');
          }
        };

        function defaultRender(msg, h) {
          const div = document.createElement('div');
          div.className = 'msg kind-' + msg.kind +
            (msg.highlight ? ' highlight' : '') + (msg.self ? ' self' : '');
          const time = `<span class="ts">${h.formatTime(msg.timestamp)}</span>`;
          const who = msg.sender
            ? `<span class="nick" style="color:${h.nickColor(msg.sender)}"
                  data-poke-nick="${h.escapeHTML(msg.sender)}">${h.escapeHTML(msg.sender)}</span>`
            : '';
          const sep = msg.kind === 'action' ? ' ' : ': ';
          div.innerHTML = `${time} ${who}${sep}${h.linkify(msg.text)}`;
          return div;
        }

        function renderOne(msg) {
          let node = null;
          if (window.PokeIRCTheme && typeof PokeIRCTheme.renderMessage === 'function') {
            node = PokeIRCTheme.renderMessage(msg, helpers);
          }
          if (!node) node = defaultRender(msg, helpers);
          if (node) log.appendChild(node);
        }

        function flush() {
          while (queue.length) renderOne(queue.shift());
          window.scrollTo(0, document.body.scrollHeight);
        }

        document.addEventListener('click', e => {
          const a = e.target.closest('a[data-poke-link]');
          if (a) {
            e.preventDefault();
            post('link', {url: a.dataset.pokeLink});
            return;
          }
          const n = e.target.closest('[data-poke-nick]');
          if (n) post('nick', {nick: n.dataset.pokeNick});
        });

        function post(type, payload) {
          if (window.webkit && webkit.messageHandlers && webkit.messageHandlers.pokeIRC) {
            webkit.messageHandlers.pokeIRC.postMessage(Object.assign({type}, payload));
          }
        }

        return {
          enqueue(list) {
            for (const m of [].concat(list)) queue.push(m);
            if (ready) flush();
          },
          setReady() { ready = true; post('ready', {}); flush(); },
          clear() { log.innerHTML = ''; },
          helpers
        };
      })();
      window.addEventListener('DOMContentLoaded', () => PokeIRC.setReady());
      """
}
