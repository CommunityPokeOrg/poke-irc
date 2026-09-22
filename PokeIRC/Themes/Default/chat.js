/* PokeIRC default theme JS.
 *
 * Contract (see docs/THEMING.md):
 *   PokeIRCTheme.renderMessage(msg, helpers) -> HTMLElement | null
 *   Returning null falls back to the built-in renderer.
 *
 * msg: {id, kind, network, buffer, sender?, text, timestamp, tags?, self, highlight}
 * helpers: {escapeHTML, formatTime, nickColor, linkify}
 */
window.PokeIRCTheme = {
  renderMessage(msg, h) {
    const div = document.createElement('div');
    div.className = 'msg kind-' + h.escapeHTML(msg.kind) +
      (msg.highlight ? ' highlight' : '') + (msg.self ? ' self' : '');

    const ts = document.createElement('span');
    ts.className = 'ts';
    ts.textContent = h.formatTime(msg.timestamp);
    div.appendChild(ts);

    const body = document.createElement('span');
    if (msg.sender) {
      const nick = document.createElement('span');
      nick.className = 'nick';
      nick.style.color = h.nickColor(msg.sender);
      nick.dataset.pokeNick = msg.sender;
      nick.textContent = msg.kind === 'action' ? `* ${msg.sender}` : `<${msg.sender}>`;
      body.appendChild(nick);
      body.appendChild(document.createTextNode(' '));
    }
    body.innerHTML += h.linkify(msg.text);
    div.appendChild(body);
    return div;
  }
};
