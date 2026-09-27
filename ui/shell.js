const $ = id => document.getElementById(id);
const send = message => window.ipc.postMessage(JSON.stringify(message));
let state = { bookmarks: [], history: [], downloads: [], panel: null, tabs: [], active: 0 };
let photoVersion = -1;
function displayUrl(raw) {
  try { return new URL(raw).host || raw; } catch { return raw; }
}
function makeButton(label, className, onClick) {
  const button = document.createElement('button');
  button.type = 'button'; button.className = className; button.textContent = label;
  button.addEventListener('click', onClick);
  return button;
}
function savedRow(item, panelStyle) {
  const entry = makeButton('', 'entry', () => {
    if (state.panel !== 'downloads') send({ type: 'open_saved', url: item.url });
  });
  const tile = document.createElement('span'); tile.className = 'site-tile';
  tile.textContent = (displayUrl(item.url).replace(/^www\./, '')[0] || '•').toUpperCase();
  const text = document.createElement('span'); text.className = 'entry-text';
  const title = document.createElement('span'); title.className = 'entry-title';
  title.textContent = item.title || item.filename || item.url;
  const detail = document.createElement('span'); detail.className = 'entry-url';
  detail.textContent = state.panel === 'downloads' ? (item.success ? 'Downloaded' : item.complete ? 'Download failed' : 'Downloading') : displayUrl(item.url);
  text.append(title, detail); entry.append(tile, text);
  if (panelStyle) { const arrow = document.createElement('span'); arrow.className = 'entry-chevron'; arrow.textContent = '›'; entry.append(arrow); }
  return entry;
}
function renderPanel() {
  const panel = $('panel'); panel.classList.toggle('open', Boolean(state.panel)); panel.replaceChildren();
  if (!state.panel) return;
  const heading = document.createElement('div'); heading.className = 'panel-head';
  const title = document.createElement('h1'); title.textContent = state.panel[0].toUpperCase() + state.panel.slice(1);
  const actions = document.createElement('div'); actions.className = 'panel-actions';
  if (state.panel === 'history') actions.append(makeButton('Clear history', '', () => send({ type: 'clear_history' })));
  actions.append(makeButton('Close', '', () => send({ type: 'show_panel', panel: null })));
  heading.append(title, actions); panel.append(heading);
  const list = document.createElement('div'); list.className = 'panel-list';
  const items = state[state.panel] || [];
  if (!items.length) {
    const empty = document.createElement('p'); empty.className = 'empty';
    empty.textContent = state.panel === 'bookmarks' ? 'Bookmark a page to keep it here.' : state.panel === 'history' ? 'Pages you visit will appear here.' : 'Downloads will appear here.';
    list.append(empty);
  } else for (const item of items) list.append(savedRow(item, true));
  panel.append(list);
}
window.renderState = next => {
  state = next;
  const active = state.tabs.find(tab => tab.id === state.active);
  $('start').classList.toggle('open', Boolean(active && active.url === 'about:blank' && !state.panel));
  $('start-photo').style.objectPosition = `${state.photo_focus_x}% ${state.photo_focus_y}%`;
  $('start').classList.toggle('has-photo', state.has_photo);
  if (photoVersion !== state.photo_version || $('start-photo').classList.contains('visible') !== state.has_photo) {
    photoVersion = state.photo_version;
    const photo = $('start-photo');
    photo.classList.toggle('visible', state.has_photo);
    if (state.has_photo) photo.src = `moth-photo://localhost/photo?v=${photoVersion}`;
    else photo.removeAttribute('src');
  }
  renderPanel();
};
document.addEventListener('keydown', event => {
  if (event.key === 'Escape' && state.panel) send({ type: 'show_panel', panel: null });
});
