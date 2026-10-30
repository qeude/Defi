// A small Defi on a 1440 × 900 point Mac, drawn in HTML at real size and scaled to fit.
// Geometry, widths, border and motion follow Defi's built-in defaults (CONFIGURATION.md).

const W = 1440;
const H = 900;
const MENU = 24;
const DOCK = 76;
const GAP = 8; // [layout] gaps
const BORDER = 4; // [decorations.borders] width, placement = "outside"
const PRESETS = [0.33, 0.5, 0.66, 0.8]; // [layout] preset_column_widths
const OVERVIEW_ZOOM = 0.5; // [overview] zoom
// Overview rows as DefiCore lays them out: 28 pt apart, each the screen scaled to (H − 2 × 28) × zoom.
const OVERVIEW_GAP = 28;
const OVERVIEW_SCALE = ((H - 2 * OVERVIEW_GAP) * OVERVIEW_ZOOM) / H;
const OVERVIEW_ROW = H + OVERVIEW_GAP / OVERVIEW_SCALE;
// The panel's left edge in track points, where the "← N" pill sits 12 pt in.
const OVERVIEW_EDGE = (W * (1 - OVERVIEW_SCALE)) / 2 / OVERVIEW_SCALE;

// Defi animates with a critically damped spring (mass 1, stiffness 800); sample it for CSS.
const OMEGA = Math.sqrt(800);
const SPRING_S = 9.9 / OMEGA;
const SPRING = `linear(${Array.from({ length: 31 }, (_, i) => {
  const t = (i / 30) * SPRING_S;
  return (1 - (1 + OMEGA * t) * Math.exp(-OMEGA * t)).toFixed(4);
}).join(',')})`;

const APPS = {
  finder: { name: 'Finder', menus: ['File', 'Edit', 'View', 'Go', 'Window', 'Help'] },
  safari: { name: 'Safari', menus: ['File', 'Edit', 'View', 'History', 'Bookmarks', 'Window', 'Help'] },
  ghostty: { name: 'Ghostty', menus: ['File', 'Edit', 'View', 'Window', 'Help'] },
  xcode: { name: 'Xcode', menus: ['File', 'Edit', 'View', 'Find', 'Navigate', 'Editor', 'Product', 'Debug', 'Window', 'Help'] },
  messages: { name: 'Messages', menus: ['File', 'Edit', 'View', 'Conversation', 'Window', 'Help'] },
  notes: { name: 'Notes', menus: ['File', 'Edit', 'Format', 'View', 'Window', 'Help'] },
  music: { name: 'Music', menus: ['File', 'Edit', 'Song', 'View', 'Controls', 'Account', 'Window', 'Help'] },
  mail: { name: 'Mail', menus: ['File', 'Edit', 'View', 'Mailbox', 'Message', 'Format', 'Window', 'Help'] },
  figma: { name: 'Figma', menus: ['File', 'Edit', 'View', 'Object', 'Text', 'Arrange', 'Window', 'Help'] },
};
const DOCK_APPS = ['finder', 'safari', 'ghostty', 'xcode', 'messages', 'notes', 'mail', 'music', 'figma'];

const GLYPHS = {
  finder: '<svg viewBox="0 0 48 48"><path d="M24 0v48" stroke="#0b3b8c" stroke-width="2"/><circle cx="15" cy="19" r="2.4" fill="#0b2a5c"/><circle cx="33" cy="19" r="2.4" fill="#0b2a5c"/><path d="M14 31q10 7 20 0" fill="none" stroke="#0b2a5c" stroke-width="2.4" stroke-linecap="round"/></svg>',
  safari: '<svg viewBox="0 0 48 48"><circle cx="24" cy="24" r="17" fill="#fff"/><path d="M24 24l9-9-5 13z" fill="#ff3b30"/><path d="M24 24l-9 9 5-13z" fill="#8e8e93"/></svg>',
  ghostty: '<svg viewBox="0 0 48 48"><path d="M14 38V20a10 10 0 0 1 20 0v18l-4-3-3 3-3-3-3 3-3-3z" fill="#fff"/><circle cx="20" cy="21" r="2" fill="#111"/><circle cx="28" cy="21" r="2" fill="#111"/></svg>',
  xcode: '<svg viewBox="0 0 48 48"><path d="M14 33l20-20M17 12l6 6M30 30l5 5" stroke="#fff" stroke-width="4" stroke-linecap="round"/></svg>',
  messages: '<svg viewBox="0 0 48 48"><path d="M24 11c-9 0-15 5.6-15 12.4 0 3.9 2 7.3 5.2 9.6L13 38l6-3c1.5.4 3.2.6 5 .6 9 0 15-5.6 15-12.3S33 11 24 11z" fill="#fff"/></svg>',
  notes: '<svg viewBox="0 0 48 48"><rect x="0" y="0" width="48" height="13" fill="#f7c948"/><path d="M10 22h28M10 29h28M10 36h20" stroke="#c9c4b5" stroke-width="2"/></svg>',
  mail: '<svg viewBox="0 0 48 48"><rect x="9" y="14" width="30" height="21" rx="3" fill="#fff"/><path d="M10 16l14 10 14-10" fill="none" stroke="#1e6ff2" stroke-width="2"/></svg>',
  music: '<svg viewBox="0 0 48 48"><path d="M20 32V15l14-3v17" fill="none" stroke="#fff" stroke-width="3"/><circle cx="17" cy="32" r="4" fill="#fff"/><circle cx="31" cy="29" r="4" fill="#fff"/></svg>',
  figma: '<svg viewBox="0 0 48 48"><circle cx="20" cy="12" r="5" fill="#f24e1e"/><circle cx="29" cy="12" r="5" fill="#ff7262"/><circle cx="20" cy="22" r="5" fill="#a259ff"/><circle cx="29" cy="22" r="5" fill="#1abcfe"/><circle cx="20" cy="32" r="5" fill="#0acf83"/></svg>',
};
export const appIcon = app => `<i class="app-icon" data-app="${app}">${GLYPHS[app]}</i>`;

const icon = `${import.meta.env.BASE_URL}media/defi-icon.png`;
const lights = '<span class="lights"><i></i><i></i><i></i></span>';
const swift = [
  '<k>public func</k> <f>focusedColumnLeftScrollOffset</f>(',
  '  workspace: <t>Workspace</t>,',
  '  viewport: <t>Rect</t> = <t>Rect</t>(x: <n>0</n>, y: <n>0</n>, width: <n>1_000</n>, height: <n>1</n>),',
  '  windows: [<t>Window</t>] = [],',
  '  settings: <t>LayoutSettings</t> = <t>LayoutSettings</t>()',
  ') -> <t>Double</t> {',
  '  <k>let</k> windowsByID = <t>Dictionary</t>(uniqueKeysWithValues: windows.<f>map</f> { ($0.id, $0) })',
  '  <k>let</k> widths = <f>columnWidthsInViewports</f>(',
  '    workspace.columns, viewport: viewport, windowsByID: windowsByID, settings: settings',
  '  )',
  '  <k>let</k> focusedLeft = widths.<f>prefix</f>(workspace.focusedColumn).<f>reduce</f>(<n>0</n>, +)',
  '  <k>let</k> totalWidth = widths.<f>reduce</f>(<n>0</n>, +)',
  '  <k>return</k> <f>min</f>(<f>max</f>(focusedLeft, <n>0</n>), <f>max</f>(totalWidth - <n>1</n>, <n>0</n>))',
  '}',
];
const repoFiles = [
  ['dir', '.github', 'feat(site): refresh landing page presentation', '8 days ago'], ['dir', 'Sources', 'fix(overview): show the captured wallpaper on every opening', '10 hours ago'],
  ['dir', 'Support', 'chore: prepare Defi 0.5.1 release', '8 days ago'], ['dir', 'Tests', 'fix(overview): show the captured wallpaper on every opening', '10 hours ago'],
  ['dir', 'docs', 'fix(macos): keep the ribbon reactive to window lifecycle', '14 hours ago'], ['dir', 'script', 'fix(macos): keep the ribbon reactive to window lifecycle', '14 hours ago'],
  ['dir', 'site', 'feat(permissions): request Screen Recording after Accessibility', '15 hours ago'], ['file', 'AGENTS.md', 'feat(permissions): request Screen Recording after Accessibility', '15 hours ago'],
  ['file', 'CONFIGURATION.md', 'fix(layout): keep configured gaps at every screen edge', '15 hours ago'], ['file', 'LICENSE', 'chore: prepare repository for public release', '3 months ago'],
  ['file', 'Package.swift', 'refactor(runtime): isolate navigation from the main actor', '5 weeks ago'], ['file', 'README.md', 'feat(permissions): request Screen Recording after Accessibility', '15 hours ago'],
];
const topics = ['macos', 'window-manager', 'niri', 'scrolling', 'tiling', 'swift'];

const CONTENT = {
  safari: title => `<div class="tb">${lights}<span class="tb-btns"><b>‹</b><b>›</b></span><span class="url">${title === 'docs' ? 'developer.apple.com' : 'github.com/qeude/Defi'}</span><span class="tb-btns"><b>⇪</b><b>＋</b></span></div>
    ${title === 'docs' ? `<div class="docs"><aside><p class="h">Application Services</p><p>AXUIElement</p><p class="on">AXUIElementSetAttributeValue</p><p>AXObserver</p><p>kAXPositionAttribute</p><p>kAXSizeAttribute</p><p>kAXFocusedWindowAttribute</p></aside><article><p class="eyebrow">Function</p><h4>AXUIElementSetAttributeValue</h4><p>Sets the accessibility object’s attribute to the specified value.</p><pre>func AXUIElementSetAttributeValue(\n  _ element: AXUIElement,\n  _ attribute: CFString,\n  _ value: CFTypeRef\n) -> AXError</pre><p class="h2">Discussion</p><p>You can send this message to any object that has an attribute that is settable.</p></article></div>`
    : `<div class="gh"><div class="gh-head"><img src="${icon}" alt=""><b>qeude / <strong>Defi</strong></b><span class="pub">Public</span><span class="gh-act">◉ Watch <i>1</i></span><span class="gh-act">⑂ Fork <i>2</i></span><button type="button" tabindex="-1" class="gh-act gh-star" title="You know you want to">☆ <span>Star</span> <i>37</i></button><a tabindex="-1" class="gh-real" href="https://github.com/qeude/Defi" target="_blank" rel="noopener">Thanks! Now star it for real ↗</a></div>
      <div class="gh-tabs"><span class="on">‹› Code</span><span>⊙ Issues <i>2</i></span><span>⇅ Pull requests <i>1</i></span><span>▷ Actions</span><span>▦ Projects</span><span>⛉ Security</span><span>⌁ Insights</span></div>
      <div class="gh-body"><div class="gh-main"><div class="gh-bar"><span class="gh-btn">⑂ main ▾</span><span class="gh-muted">6 Branches · 12 Tags</span><span class="gh-btn gh-goto">Go to file</span><span class="gh-btn gh-code">‹› Code ▾</span></div>
      <div class="gh-files"><p class="gh-commit"><i></i><b>qeude</b> fix(overview): show the captured wallpaper on every opening (<u>#170</u>) <span>c12e82c · 10 hours ago · <b>160 Commits</b></span></p>${repoFiles.map(([kind, name, message, when]) => `<p><i class="${kind}"></i><span>${name}</span><em>${message}</em><small>${when}</small></p>`).join('')}</div>
      <div class="gh-readme"><p class="gh-readme-tab"><b>README</b><span>MIT license</span></p><img src="${icon}" alt=""><h4>Defi</h4><p>A fast, native scrollable-tiling window manager for macOS, inspired by Niri.</p><code>brew install --cask qeude/tap/defi</code><p class="gh-egg">Psst: you are looking at it. Press <kbd>⌃⌥</kbd> <kbd>→</kbd>.</p></div></div>
      <aside class="gh-about"><h5>About</h5><p>A fast, native scrollable-tiling window manager for macOS, inspired by Niri.</p><p class="gh-link">⚲ qeude.github.io/Defi</p><p class="gh-topics">${topics.map(t => `<span>${t}</span>`).join('')}</p><p class="gh-muted">▤ Readme<br>⚖ MIT license<br>☆ <b class="gh-stars">37</b> stars<br>◉ 1 watching<br>⑂ 2 forks</p><h5>Releases <i>12</i></h5><p><span class="gh-latest">Latest</span> Defi 0.5.1</p></aside></div></div>`}`,
  ghostty: title => `<div class="tb tb-term">${lights}<span class="tb-title">${title === 'tests' ? 'swift test' : '~'}</span></div><pre class="term">${title === 'tests'
    ? `<g>~/Developer/Defi</g> <p>❯</p> swift test --filter DefiCoreTests
Building for debugging...
[412/412] Linking DefiPackageTests
Test Suite 'DefiCoreTests' started
<d>✔ focusedColumnScrollTarget() passed (0.002 seconds)</d>
<d>✔ cycleWidthWrapsAtBothEnds() passed (0.001 seconds)</d>
<d>✔ parkingStaysOnItsOwnDisplay() passed (0.004 seconds)</d>
<d>✔ overviewKeepsRibbonOrder() passed (0.003 seconds)</d>
<d>✔ trailingWorkspaceStaysEmpty() passed (0.001 seconds)</d>
<g>✔ Test run passed with 0 failures</g>
<g>~/Developer/Defi</g> <p>❯</p> <u> </u>`
    : `<g>~</g> <p>❯</p> brew install --cask qeude/tap/defi
<b>==></b> Tapping qeude/tap
<b>==></b> Downloading Defi
######################################## 100.0%
<b>==></b> Installing Cask <g>defi</g>
<b>==></b> Moving App 'Defi.app' to '/Applications/Defi.app'
🍺  defi was successfully installed!
<g>~</g> <p>❯</p> open -a Defi
<g>~</g> <p>❯</p> <u> </u>`}</pre>`,
  xcode: () => `<div class="tb tb-xcode">${lights}<span class="run">▶</span><span class="scheme">Defi › My Mac</span><span class="status">Build Succeeded | Today at 9:41</span></div><div class="xc"><aside><p>▾ Defi</p><p class="i1">▾ Sources</p><p class="i2">▾ DefiCore</p><p class="i3">Animation.swift</p><p class="i3">ContinuousStrip.swift</p><p class="i3">Layout.swift</p><p class="i3">Overview.swift</p><p class="i3">Parking.swift</p><p class="i3 on">WorkspaceScrolling.swift</p><p class="i2">▸ DefiMacOS</p><p class="i2">▸ DefiRuntime</p><p class="i1">▸ Tests</p></aside><div class="code"><p class="crumb">DefiCore › WorkspaceScrolling.swift › focusedColumnLeftScrollOffset</p>${swift.map((line, i) => `<p><span class="no">${i + 3}</span>${line}</p>`).join('')}</div></div>`,
  messages: () => `<div class="msg"><aside>${lights}<p class="search">Search</p>${[['Hermance', 'Ship it.', true], ['Doudi', 'You still owe me a croissant 🥐'], ['Tom', 'Tests pass on both monitors'], ['Design', 'New hero is live'], ['Mom', 'Call me tonight?']].map(([who, what, on]) => `<div class="conv${on ? ' on' : ''}"><i>${who[0]}</i><p><b>${who}</b>${what}</p></div>`).join('')}</aside><div class="thread"><p class="to">To: <b>Hermance</b></p><p class="in">Is the review ready?</p><p class="out">Pushed. Control-Option → takes you to the terminal.</p><p class="in">Tests pass on both monitors 🎉</p><p class="out">Ship it.</p><p class="compose">iMessage</p></div></div>`,
  notes: () => `<div class="notes"><aside>${lights}<p class="h">iCloud</p><p class="on">Launch list</p><p>Shortcuts to learn</p><p>Ideas</p></aside><article><p class="date">27 October 2026 at 9:41</p><h4>Launch list</h4><p>☑ Record the new hero</p><p>☑ Columns, not tiles</p><p>☐ Try two monitors</p><p>☐ Name the dev workspace</p><p>☐ Send Doudi the link (promised)</p><h5>Shortcuts</h5><p>⌃⌥ ← → move between columns</p><p>⌃⌥ ↑ ↓ switch workspace</p><p>⌃⌥ O Overview</p><p>⌃⌥ − = column width</p></article></div>`,
  mail: () => `<div class="mail"><aside>${lights}<p class="h">Favorites</p><p class="on">Inbox <span>3</span></p><p>Sent</p><p>Drafts</p><p>Archive</p></aside><div class="list">${[['GitHub', '[qeude/Defi] New release', 'Defi tidies your desktop into scrolling columns…', true], ['Homebrew', 'qeude/tap updated', 'A new defi cask is available'], ['Hermance', 'Landing page', 'The interactive hero is great, can we…'], ['Apple Developer', 'macOS 26.1 is available', 'Download the release notes…']].map(([from, subject, preview, on]) => `<div class="row${on ? ' on' : ''}"><b>${from}</b><p>${subject}</p><em>${preview}</em></div>`).join('')}</div><article><h4>[qeude/Defi] New release</h4><p class="from">GitHub · 9:12</p><p>Defi tidies your desktop into scrolling columns. Workspace switches now slide on the overlay, and your layout survives a restart.</p></article></div>`,
  music: () => `<div class="music"><aside>${lights}<p class="h">Apple Music</p><p>Home</p><p>Radio</p><p class="h">Library</p><p class="on">Albums</p><p>Songs</p></aside><div class="albums">${['#fa2d55,#ffb86b', '#7a5cff,#2b6df2', '#0acf83,#1abcfe', '#ffcf7a,#ff7262', '#c099ff,#5b3cc4', '#1b1b1d,#5a5d6a'].map((c, i) => `<figure><i style="background:linear-gradient(135deg,${c})"></i><figcaption>${['Night Drive', 'Columns', 'Horizon', 'Late Light', 'Without the Edges', 'Doudi’s Mix'][i]}</figcaption></figure>`).join('')}</div><div class="player"><i></i><p><b>Night Drive</b>Defi Ensemble</p><span>⏮ ⏸ ⏭</span></div></div>`,
  figma: () => `<div class="tb tb-figma">${lights}<span class="tb-title">Defi — Landing</span></div><div class="fig"><aside><p class="h">Layers</p><p>▾ Hero</p><p class="i1 on">Desk</p><p class="i1">Headline</p><p class="i1">Install</p><p>▸ Shortcuts</p><p>▸ Bento</p></aside><div class="canvas"><div class="frame"><b class="f-h">Meet Defi</b><i class="f-d"></i><i class="f-c"></i><i class="f-c two"></i></div></div><aside class="props"><p class="h">Frame</p><p>W 1440 · H 900</p><p class="h">Fill</p><p><i></i>#1B1B1D</p></aside></div>`,
};

// A column is a stack of windows (DefiCore's Column); floating windows sit above, at their own frame.
const DEFAULT_WIDTH = 0.8; // [layout] default_column_width
// shortcut: Defi refuses a join when the stack would not fit the windows' minimum heights; three windows stand in for that limit.
const MAX_STACK = 3;
const col = (app, title, w, mess) => ({ w, wins: [{ app, title, mess }], focus: 0 });
const workspace = cols => ({ focus: 0, scroll: 0, cols, floats: [], floatFocus: 0, layer: 'tiled' });
const initialSpaces = () => [
  workspace([col('safari', 'GitHub — qeude/Defi', 0.66, [150, 64, 900, 600, 9]), col('ghostty', '~', 0.33, [700, 330, 560, 400, 6]), col('notes', 'Launch list', 0.5, [300, 230, 520, 480, 3]), col('mail', 'Inbox', 0.5, [830, 96, 560, 500, 4])]),
  workspace([col('xcode', 'WorkspaceScrolling.swift', 0.66, [60, 150, 980, 620, 2]), col('ghostty', 'tests', 0.33, [990, 380, 420, 360, 7]), col('messages', 'Hermance', 0.5, [440, 52, 600, 440, 5]), col('safari', 'docs', 0.5, [720, 250, 660, 500, 1])]),
  workspace([col('figma', 'Defi — Landing', 0.66, [220, 320, 860, 460, 8]), col('music', 'Music', 0.33, [24, 40, 520, 400, 0])]),
];

const KEYS = {
  ArrowLeft: 'focus-column left', ArrowRight: 'focus-column right', ArrowUp: 'focus-workspace up', ArrowDown: 'focus-workspace down',
  BracketLeft: 'focus-column first', BracketRight: 'focus-column last', KeyO: 'toggle-overview',
  Minus: 'cycle-width previous', Equal: 'cycle-width next', KeyF: 'maximize-column',
  KeyK: 'focus-window up', KeyJ: 'focus-window down', Semicolon: 'join-window left', Quote: 'join-window right', KeyR: 'unjoin-windows',
  Backslash: 'toggle-floating', Comma: 'focus-floating previous', Period: 'focus-floating next',
};
const SHIFT_KEYS = {
  ArrowLeft: 'move-column left', ArrowRight: 'move-column right', ArrowUp: 'move-column-to-workspace up', ArrowDown: 'move-column-to-workspace down',
  BracketLeft: 'move-column first', BracketRight: 'move-column last',
  KeyK: 'move-window up', KeyJ: 'move-window down', Backslash: 'activate-floating',
};
// The stack steps (join, move along it, unjoin, then narrow back to 0.33) leave the first workspace as it was.
export const DEMO = ['ArrowRight', 'Semicolon', 'KeyK', 'KeyJ', 'KeyR', 'Minus', 'Minus', 'Minus', 'ArrowRight', 'Equal', 'ArrowLeft', 'ArrowDown', 'ArrowRight', 'ArrowRight', 'KeyO', 'ArrowDown', 'KeyO', 'ArrowUp', 'ArrowUp', 'BracketLeft'];

// Defi's cheatsheet for the built-in keys, as CheatsheetView lays it out: two balanced
// columns of sections; each row is a chord, its action, then the Shift chord and its action.
const cheatsheet = [
  [
    ['Columns', [['⌃⌥', '←', 'Column left', '⌃⌥⇧', 'Move column left'], ['⌃⌥', '→', 'Column right', '⌃⌥⇧', 'Move column right'], ['⌃⌥', '[', 'First column', '⌃⌥⇧', 'Move column to first'], ['⌃⌥', ']', 'Last column', '⌃⌥⇧', 'Move column to last']]],
    ['Windows in a column', [['⌃⌥', 'K', 'Window up', '⌃⌥⇧', 'Move window up'], ['⌃⌥', 'J', 'Window down', '⌃⌥⇧', 'Move window down'], ['⌃⌥', ';', 'Join left column'], ['⌃⌥', "'", 'Join right column'], ['⌃⌥', 'R', 'Unjoin']]],
    ['Workspaces', [['⌃⌥', '↑', 'Workspace up', '⌃⌥⇧', 'Move column to workspace up'], ['⌃⌥', '↓', 'Workspace down', '⌃⌥⇧', 'Move column to workspace down'], ['⌃⌥', '1–9', 'Workspace 1–9', '⌃⌥⇧', 'Move column to workspace 1–9'], ['⌃⌥', 'O', 'Overview']]],
  ],
  [
    ['Monitors', [['⌃⌘', '←↑↓→', 'Focus monitor', '⌃⇧⌘', 'Move column to monitor'], ['✧', '←↑↓→', 'Move workspace to monitor']]],
    ['Size', [['⌃⌥', '−', 'Narrower'], ['⌃⌥', '=', 'Wider'], ['⌃⌥', 'F', 'Maximize column']]],
    ['Floating', [['⌃⌥', '\\', 'Float or tile window', '⌃⌥⇧', 'Show floating layer'], ['⌃⌥', ',', 'Previous floating'], ['⌃⌥', '.', 'Next floating']]],
  ],
];
const chord = (mods, key) => `<span class="chord"><kbd>${mods}</kbd><kbd>${key}</kbd></span>`;
export const cheatsheetMarkup = () => cheatsheet.map(groups => `<div class="cs-col">${groups.map(([title, rows]) => `<h5>${title}</h5>${rows.map(([mods, key, action, shiftMods, shiftAction]) => `${chord(mods, key)}<span>${action}</span>${shiftMods ? `${chord(shiftMods, key)}<span>${shiftAction}</span>` : '<i></i><i></i>'}`).join('')}`).join('')}</div>`).join('');

export function windowMarkup({ app, title }) {
  const shown = title === 'docs' ? 'Developer Documentation' : title === 'tests' ? 'swift test' : title;
  return `<div class="ov-title" aria-hidden="true">${appIcon(app)}<span>${shown}</span></div><div class="app app-${app}" aria-hidden="true">${CONTENT[app](title)}</div>`;
}

export function mountDesk(root, { reducedMotion, onCommand = () => {} }) {
  root.innerHTML = `<div class="screen">
    <div class="wallpaper"></div><div class="ov-backdrop"></div>
    <div class="track"></div>
    <div class="menubar"><span class="mb-apple"><svg viewBox="0 0 14 17"><path fill="currentColor" d="M11.6 9c0-2 1.7-3 1.8-3.1-1-1.4-2.5-1.6-3-1.6-1.3-.1-2.5.8-3.1.8-.7 0-1.6-.7-2.7-.7C3.2 4.4 1.9 5.3 1.2 6.6c-1.5 2.6-.4 6.4 1 8.5.7 1 1.5 2.2 2.6 2.1 1-.1 1.4-.7 2.7-.7 1.2 0 1.6.7 2.7.6 1.1 0 1.8-1 2.5-2 .8-1.2 1.1-2.3 1.1-2.4 0 0-2.2-.8-2.2-3.7ZM9.5 2.9c.6-.7 1-1.7.9-2.7-.9 0-1.9.6-2.5 1.3-.6.6-1 1.6-.9 2.6 1 .1 1.9-.5 2.5-1.2Z"/></svg></span><b class="mb-app"></b><span class="mb-menus"></span>
      <span class="mb-right"><button type="button" class="mb-defi" aria-haspopup="menu" aria-label="Defi menu"><svg viewBox="0 0 18 14"><rect x="1" y="1" width="4" height="12" rx="1.2"/><rect x="7" y="1" width="4" height="12" rx="1.2"/><rect x="13" y="1" width="4" height="12" rx="1.2"/></svg><span class="mb-label"></span></button>
      <svg class="mb-ico" viewBox="0 0 20 14"><path d="M10 13l2.2-2.6a3 3 0 0 0-4.4 0zM4.5 7.3l1.6 1.8a5.5 5.5 0 0 1 7.8 0l1.6-1.8a8 8 0 0 0-11 0zM1 3.6l1.6 1.8a10.5 10.5 0 0 1 14.8 0L19 3.6a13 13 0 0 0-18 0z" fill="currentColor"/></svg>
      <svg class="mb-ico battery" viewBox="0 0 28 13"><rect x=".5" y=".5" width="24" height="12" rx="3.5" fill="none" stroke="currentColor" opacity=".5"/><rect x="2.5" y="2.5" width="17" height="8" rx="2" fill="currentColor"/><path d="M26 4.5v4a2 2 0 0 0 0-4z" fill="currentColor" opacity=".5"/></svg>
      <svg class="mb-ico" viewBox="0 0 16 14"><rect x="1" y="1" width="6" height="5" rx="2.5" fill="none" stroke="currentColor" stroke-width="1.4"/><rect x="1" y="8" width="6" height="5" rx="2.5" fill="currentColor"/><rect x="9" y="1" width="6" height="5" rx="2.5" fill="currentColor"/><rect x="9" y="8" width="6" height="5" rx="2.5" fill="none" stroke="currentColor" stroke-width="1.4"/></svg>
      <span class="mb-clock"></span></span></div>
    <div class="defi-menu" role="menu" hidden></div>
    <div class="spotlight" aria-hidden="true"><div class="sp-bar"><svg viewBox="0 0 20 20"><circle cx="8.5" cy="8.5" r="6" fill="none" stroke="currentColor" stroke-width="2"/><path d="M13 13l5 5" stroke="currentColor" stroke-width="2" stroke-linecap="round"/></svg><span class="sp-text"></span></div><div class="sp-result"><img src="${icon}" alt=""><b>Defi</b><span>Application</span></div></div>
    <div class="dock">${DOCK_APPS.map(app => `<button type="button" class="dock-item" data-app="${app}" aria-label="${APPS[app].name}">${appIcon(app)}<span class="dot"></span><span class="tip">${APPS[app].name}</span></button>`).join('')}</div>
    <div class="cheatsheet" aria-hidden="true">${cheatsheetMarkup()}</div>
  </div>`;
  root.style.setProperty('--ov-edge', `${OVERVIEW_EDGE}px`);
  root.style.setProperty('--spring', SPRING);
  root.style.setProperty('--spring-s', `${SPRING_S.toFixed(3)}s`);
  const screen = root.querySelector('.screen');
  const track = root.querySelector('.track');
  const menuApp = root.querySelector('.mb-app');
  const menus = root.querySelector('.mb-menus');
  const label = root.querySelector('.mb-label');
  const defiButton = root.querySelector('.mb-defi');
  const defiMenu = root.querySelector('.defi-menu');
  const sheet = root.querySelector('.cheatsheet');
  const spaces = initialSpaces();
  let active = 0;
  let overview = false;
  let zoomTimer;
  let messy = !reducedMotion.matches; // Before Defi starts, the windows overlap as on any Mac.
  const els = new Map();
  const rows = new Map();
  const isEmpty = space => !space.cols.length && !space.floats.length;
  const focusedWin = space => (space.layer === 'floating' && space.floats.length
    ? space.floats[space.floatFocus].win
    : space.cols[space.focus]?.wins[space.cols[space.focus].focus]);

  const rowFor = space => {
    if (!rows.has(space)) {
      const row = document.createElement('div');
      row.className = 'ws';
      row.innerHTML = '<button type="button" class="ov-more left" tabindex="-1"></button><button type="button" class="ov-more right" tabindex="-1"></button>';
      // A pill pages the row by one column, like Defi's.
      row.querySelectorAll('.ov-more').forEach((pill, i) => pill.addEventListener('click', event => {
        event.stopPropagation();
        const from = space.ovOffset ?? firstVisible(space);
        space.ovOffset = Math.min(Math.max(from + (i ? 1 : -1), 0), space.cols.length - 1);
        render();
      }));
      track.append(row);
      rows.set(space, row);
    }
    return rows.get(space);
  };

  let dragged = false;
  function windowElement(win) {
    if (els.has(win)) return els.get(win);
    const el = document.createElement('div');
    el.className = 'win';
    el.innerHTML = windowMarkup(win);
    el.addEventListener('click', event => {
      event.stopPropagation();
      if (dragged) return void (dragged = false);
      const star = event.target.closest('.gh-star');
      if (star) {
        // Easter egg: the Star button works (locally), and the About count follows.
        const on = star.classList.toggle('on');
        star.querySelector('span').textContent = on ? 'Starred' : 'Star';
        el.querySelectorAll('.gh-star i, .gh-stars').forEach(count => { count.textContent = on ? 38 : 37; });
      }
      closeMenu();
      if (messy) launch({ quick: true });
      focusWin(win);
      overview = false;
      onCommand(null, 'click');
      render();
    });
    el.addEventListener('pointerdown', event => startDrag(event, win, el));
    els.set(win, el);
    return el;
  }

  function focusWin(win) {
    spaces.forEach((space, index) => {
      const float = space.floats.findIndex(f => f.win === win);
      const column = space.cols.findIndex(c => c.wins.includes(win));
      if (float >= 0) Object.assign(space, { floatFocus: float, layer: 'floating' });
      else if (column >= 0) {
        Object.assign(space, { focus: column, layer: 'tiled' });
        space.cols[column].focus = space.cols[column].wins.indexOf(win);
      } else return;
      active = index;
    });
  }

  // One empty trailing workspace; other empty workspaces go away once inactive.
  function normalize() {
    const current = spaces[active];
    for (let i = spaces.length - 2; i >= 0; i--) {
      if (isEmpty(spaces[i]) && spaces[i] !== current) spaces.splice(i, 1);
    }
    if (!isEmpty(spaces.at(-1))) spaces.push(workspace([]));
    active = spaces.indexOf(current);
    for (const [space, row] of rows) {
      if (spaces.includes(space)) continue;
      row.remove();
      rows.delete(space);
    }
  }

  function layout(space) {
    let x = GAP;
    return space.cols.map(column => {
      const w = column.w * (W - GAP) - GAP;
      const frame = { x, w };
      x += w + GAP;
      return frame;
    });
  }
  // A stack divides the usable height evenly, after gaps (CONFIGURATION.md, stacks).
  const USABLE = H - MENU - DOCK - 2 * GAP;
  const stackFrame = (x, w, k, n) => {
    const h = (USABLE - GAP * (n - 1)) / n;
    return { x: x + BORDER, y: MENU + GAP + k * (h + GAP) + BORDER, w: w - 2 * BORDER, h: h - 2 * BORDER };
  };
  // In the Overview a row scrolls by columns: its offset puts that column at the left edge.
  const firstVisible = space => Math.max(0, layout(space).findIndex(f => f.x + f.w > space.scroll));
  const shownScroll = (space, frames) => (overview && space.ovOffset != null && frames[space.ovOffset] ? frames[space.ovOffset].x - GAP : space.scroll);

  function place(win, frame, space, { z = '', delay = '', focused = false, floating = false }) {
    const el = windowElement(win);
    const row = rows.get(space);
    if (el.parentElement !== row) row.append(el);
    win.frame = frame;
    el.style.transform = `translate3d(${frame.x}px,${frame.y}px,0)`;
    el.style.width = `${frame.w}px`;
    el.style.height = `${frame.h}px`;
    el.style.zIndex = z;
    el.style.transitionDelay = delay;
    el.classList.toggle('is-focused', focused);
    el.classList.toggle('is-floating', floating);
  }

  function render() {
    normalize();
    const tidying = root.classList.contains('is-tidying');
    spaces.forEach((space, index) => {
      const row = rowFor(space);
      row.style.transform = `translate3d(0,${index * (overview ? OVERVIEW_ROW : H)}px,0)`;
      const frames = layout(space);
      const focused = frames[space.focus];
      // center_focused_column = "never": scroll only as far as needed to reveal the focused column.
      if (focused) {
        if (focused.w > W - 2 * GAP || focused.x - GAP < space.scroll) space.scroll = focused.x - GAP;
        else if (focused.x + focused.w + GAP > space.scroll + W) space.scroll = focused.x + focused.w + GAP - W;
      }
      const scroll = shownScroll(space, frames);
      const selected = !messy && index === active ? focusedWin(space) : null;
      space.cols.forEach((column, i) => column.wins.forEach((win, k) => place(win,
        messy ? { x: win.mess[0], y: win.mess[1] - index * H, w: win.mess[2], h: win.mess[3] } : stackFrame(frames[i].x - scroll, frames[i].w, k, column.wins.length),
        space,
        { z: messy ? win.mess[4] : '', delay: tidying ? `${(index * 4 + i) * 45}ms` : '', focused: win === selected },
      )));
      // Floating windows keep their own frame above the columns.
      space.floats.forEach(({ win, frame }) => place(win, frame, space, { z: 20, focused: win === selected, floating: true }));
      // Columns wholly past the panel's edges, counted on the row's pills.
      const [left, right] = row.querySelectorAll('.ov-more');
      const beyondLeft = frames.filter(f => f.x + f.w - scroll < -OVERVIEW_EDGE).length;
      const beyondRight = frames.filter(f => f.x - scroll > W + OVERVIEW_EDGE).length;
      left.textContent = beyondLeft ? `← ${beyondLeft}` : '';
      right.textContent = beyondRight ? `${beyondRight} →` : '';
    });
    const s = OVERVIEW_SCALE;
    // Opening and closing zoom over 0.22 s; moves inside the Overview take 0.16 s.
    if (overview !== root.classList.contains('is-overview')) {
      root.classList.add('ov-zoom');
      clearTimeout(zoomTimer);
      zoomTimer = setTimeout(() => root.classList.remove('ov-zoom'), 240);
    }
    track.style.transform = overview
      ? `translate3d(${(W * (1 - s)) / 2}px,${H / 2 - (active * OVERVIEW_ROW + H / 2) * s}px,0) scale(${s})`
      : `translate3d(0,${-active * H}px,0)`;
    root.classList.toggle('is-overview', overview);
    const shown = messy ? spaces[0].cols[0].wins[0] : focusedWin(spaces[active]);
    const app = APPS[shown ? shown.app : 'finder'];
    menuApp.textContent = app.name;
    menus.innerHTML = app.menus.map(menu => `<span>${menu}</span>`).join('');
    label.textContent = String(active + 1);
    root.querySelectorAll('.dock-item').forEach(item => item.classList.toggle('running', spaces.some(space => [...space.cols.flatMap(c => c.wins), ...space.floats.map(f => f.win)].some(win => win.app === item.dataset.app))));
    if (!defiMenu.hidden) fillMenu();
  }

  // Takes a window out of its column or the floating layer, as DefiCore's removeWindow does.
  function detach(space, win) {
    const float = space.floats.findIndex(f => f.win === win);
    if (float >= 0) {
      space.floats.splice(float, 1);
      space.floatFocus = Math.max(0, Math.min(space.floatFocus, space.floats.length - 1));
      if (!space.floats.length) space.layer = 'tiled';
      return;
    }
    const index = space.cols.findIndex(c => c.wins.includes(win));
    const column = space.cols[index];
    column.wins.splice(column.wins.indexOf(win), 1);
    if (column.wins.length) column.focus = Math.min(column.focus, column.wins.length - 1);
    else {
      space.cols.splice(index, 1);
      space.focus = Math.max(0, Math.min(space.focus, space.cols.length - 1));
    }
  }
  // A new column goes right after the focused one, at the default width.
  function insertColumn(space, win, w = DEFAULT_WIDTH) {
    const index = space.cols.length ? Math.min(space.focus + 1, space.cols.length) : 0;
    space.cols.splice(index, 0, { w, wins: [win], focus: 0 });
    Object.assign(space, { focus: index, layer: 'tiled' });
  }

  function act(command) {
    const space = spaces[active];
    const last = space.cols.length - 1;
    const column = space.cols[space.focus];
    const tiled = () => { space.layer = 'tiled'; };
    const moveTo = to => {
      if (!column || to < 0 || to > last || to === space.focus) return;
      space.cols.splice(space.focus, 1);
      space.cols.splice(to, 0, column);
      space.focus = to;
    };
    const moveColumnTo = target => {
      if (!column || target < 0 || target >= spaces.length || target === active) return;
      space.cols.splice(space.focus, 1);
      space.focus = Math.max(0, Math.min(space.focus, space.cols.length - 1));
      const into = spaces[target];
      into.cols.splice(into.cols.length ? into.focus + 1 : 0, 0, column);
      Object.assign(into, { focus: into.cols.indexOf(column), layer: 'tiled' });
      active = target;
    };
    const join = step => {
      const into = space.cols[space.focus + step];
      if (!column || !into || into.wins.length >= MAX_STACK) return;
      const win = column.wins[column.focus];
      detach(space, win);
      into.wins.push(win);
      into.focus = into.wins.length - 1;
      space.focus = space.cols.indexOf(into);
    };
    const position = command.match(/^(focus-workspace|move-column-to-workspace)-position (\d)$/);
    if (position) {
      const target = Math.min(spaces.length - 1, Number(position[2]) - 1);
      if (position[1] === 'focus-workspace') active = target;
      else moveColumnTo(target);
      return render();
    }
    switch (command) {
      case 'focus-column left': tiled(); space.focus = Math.max(0, space.focus - 1); break;
      case 'focus-column right': tiled(); space.focus = Math.min(Math.max(0, last), space.focus + 1); break;
      case 'focus-column first': tiled(); space.focus = 0; break;
      case 'focus-column last': tiled(); space.focus = Math.max(0, last); break;
      case 'focus-window up': if (column) { tiled(); column.focus = Math.max(0, column.focus - 1); } break;
      case 'focus-window down': if (column) { tiled(); column.focus = Math.min(column.wins.length - 1, column.focus + 1); } break;
      case 'move-window up':
      case 'move-window down': {
        if (!column) break;
        tiled();
        const to = Math.min(Math.max(column.focus + (command.endsWith('up') ? -1 : 1), 0), column.wins.length - 1);
        column.wins.splice(to, 0, ...column.wins.splice(column.focus, 1));
        column.focus = to;
        break;
      }
      case 'join-window left': tiled(); join(-1); break;
      case 'join-window right': tiled(); join(1); break;
      case 'unjoin-windows': {
        if (!column || column.wins.length < 2) break;
        const win = column.wins[column.focus];
        detach(space, win);
        insertColumn(space, win);
        break;
      }
      case 'toggle-floating': {
        const win = focusedWin(space);
        if (!win) break;
        const floating = space.layer === 'floating' && space.floats.length;
        detach(space, win);
        if (floating) insertColumn(space, win);
        else {
          // A window that starts floating keeps the frame it had in its column.
          space.floats.push({ win, frame: { ...win.frame } });
          Object.assign(space, { floatFocus: space.floats.length - 1, layer: 'floating' });
        }
        break;
      }
      case 'activate-floating': if (space.floats.length) space.layer = 'floating'; break;
      case 'focus-floating previous':
      case 'focus-floating next': {
        const n = space.floats.length;
        if (!n) break;
        space.floatFocus = space.layer !== 'floating' ? space.floatFocus : (space.floatFocus + (command.endsWith('next') ? 1 : -1) + n) % n;
        space.layer = 'floating';
        break;
      }
      case 'focus-workspace up': active = Math.max(0, active - 1); break;
      case 'focus-workspace down': active = Math.min(spaces.length - 1, active + 1); break;
      case 'toggle-overview':
        overview = !overview;
        // Each opening starts from the rows' real scroll.
        if (overview) spaces.forEach(s => { delete s.ovOffset; });
        break;
      case 'move-column left': moveTo(space.focus - 1); break;
      case 'move-column right': moveTo(space.focus + 1); break;
      case 'move-column first': moveTo(0); break;
      case 'move-column last': moveTo(last); break;
      case 'cycle-width next':
      case 'cycle-width previous': {
        if (!column) break;
        const step = command.endsWith('next') ? 1 : -1;
        const current = PRESETS.findIndex(p => Math.abs(p - column.w) < 0.01);
        column.w = current < 0 ? PRESETS[step > 0 ? 0 : PRESETS.length - 1] : PRESETS[(current + step + PRESETS.length) % PRESETS.length];
        break;
      }
      case 'maximize-column':
        if (!column) break;
        if (column.w === 1) column.w = column.restore ?? DEFAULT_WIDTH;
        else [column.restore, column.w] = [column.w, 1];
        break;
      case 'move-column-to-workspace up': moveColumnTo(active - 1); break;
      case 'move-column-to-workspace down': moveColumnTo(active + 1); break;
    }
    render();
  }

  function press(code, shift = false) {
    const digit = code.match(/^Digit([1-9])$/);
    const command = digit ? `${shift ? 'move-column-to-workspace' : 'focus-workspace'}-position ${digit[1]}` : (shift ? SHIFT_KEYS : KEYS)[code];
    if (!command) return false;
    hideSheet();
    closeMenu();
    if (messy) launch({ quick: true });
    act(command);
    onCommand(code, command);
    return true;
  }

  // In the Overview, plain arrows move the selection; Return and Escape close it.
  // Moving the selection puts its column at the row's left edge, as Defi's Overview does.
  function pressInOverview(code) {
    if (!overview) return false;
    if (code === 'Enter' || code === 'Escape') {
      overview = false;
      render();
      onCommand(null, 'toggle-overview');
      return true;
    }
    const command = { ArrowLeft: 'focus-column left', ArrowRight: 'focus-column right', ArrowUp: 'focus-workspace up', ArrowDown: 'focus-workspace down' }[code];
    if (!command) return false;
    act(command);
    if (command.startsWith('focus-column')) {
      spaces[active].ovOffset = spaces[active].focus;
      render();
    }
    onCommand(null, command);
    return true;
  }

  // Dragging a card in the Overview, as OverviewView does: past 5 pt it follows the pointer; the
  // edges of a card make a new column beside it, its central half joins its stack.
  let drag = null;
  const indicator = document.createElement('i');
  indicator.className = 'ov-drop';
  function trackPoint(event) {
    const box = root.getBoundingClientRect();
    const px = ((event.clientX - box.left) / box.width) * W;
    const py = ((event.clientY - box.top) / box.height) * H;
    const s = OVERVIEW_SCALE;
    const ty = H / 2 - (active * OVERVIEW_ROW + H / 2) * s;
    return { x: (px - (W * (1 - s)) / 2) / s, y: (py - ty) / s };
  }
  function dropTarget(point) {
    const index = Math.min(spaces.length - 1, Math.max(0, Math.round((point.y - H / 2) / OVERVIEW_ROW)));
    const space = spaces[index];
    const frames = layout(space);
    const x = point.x + shownScroll(space, frames);
    const y = point.y - index * OVERVIEW_ROW;
    const i = frames.findIndex(f => x >= f.x && x <= f.x + f.w);
    if (i < 0) return { space, at: x < (frames[0]?.x ?? 0) ? 0 : space.cols.length, frames };
    const rel = (x - frames[i].x) / frames[i].w;
    if (rel < 0.25) return { space, at: i, frames };
    if (rel > 0.75) return { space, at: i + 1, frames };
    const stack = space.cols[i];
    const slot = stack.wins.filter(win => win.frame && win.frame.y + win.frame.h / 2 < y).length;
    return { space, column: stack, slot, frames, i };
  }
  function showIndicator(target) {
    const row = rows.get(target.space);
    const scroll = shownScroll(target.space, target.frames);
    if (indicator.parentElement !== row) row.append(indicator);
    if (target.column) {
      const f = target.frames[target.i];
      const wins = target.column.wins;
      const y = target.slot < wins.length ? wins[target.slot].frame.y - GAP / 2 - BORDER : wins.at(-1).frame.y + wins.at(-1).frame.h + GAP / 2 + BORDER;
      indicator.style.cssText = `left:${f.x - scroll}px;top:${y - 4}px;width:${f.w}px;height:9px`;
      indicator.className = 'ov-drop stack';
    } else {
      const f = target.frames[target.at];
      const prev = target.frames[target.at - 1];
      const x = f ? f.x - GAP / 2 : prev ? prev.x + prev.w + GAP / 2 : GAP;
      indicator.style.cssText = `left:${x - scroll - 21}px;top:${MENU + GAP}px;width:43px;height:${USABLE}px`;
      indicator.className = 'ov-drop column';
    }
  }
  function startDrag(event, win, el) {
    if (!overview || event.button !== 0 || spaces.some(space => space.floats.some(f => f.win === win))) return;
    drag = { win, el, start: trackPoint(event), moving: false };
    el.setPointerCapture(event.pointerId);
  }
  root.addEventListener('pointermove', event => {
    if (!drag) return;
    const point = trackPoint(event);
    const dx = point.x - drag.start.x;
    const dy = point.y - drag.start.y;
    if (!drag.moving && Math.hypot(dx, dy) * OVERVIEW_SCALE < 5) return;
    drag.moving = true;
    drag.el.classList.add('is-dragging');
    drag.el.style.translate = `${dx}px ${dy}px`;
    drag.target = dropTarget(point);
    showIndicator(drag.target);
  });
  const endDrag = event => {
    if (!drag) return;
    const { win, el, moving, target, start } = drag;
    drag = null;
    indicator.remove();
    el.classList.remove('is-dragging');
    if (!moving) return;
    dragged = true;
    const point = trackPoint(event);
    const source = spaces.find(space => space.cols.some(c => c.wins.includes(win)));
    const from = space => space.cols.find(c => c.wins.includes(win));
    const alone = from(source).wins.length === 1;
    // Dropping a lone window beside its own column, or onto itself, changes nothing.
    const noop = target.column ? target.column === from(source) && alone : alone && [target.space.cols[target.at - 1], target.space.cols[target.at]].includes(from(source));
    // Start the move from where the card was let go, in the row it lands in.
    const rowShift = (spaces.indexOf(source) - spaces.indexOf(noop ? source : target.space)) * OVERVIEW_ROW;
    el.style.transition = 'none';
    el.style.translate = '';
    el.style.transform = `translate3d(${win.frame.x + point.x - start.x}px,${win.frame.y + point.y - start.y + rowShift}px,0)`;
    if (!noop) rows.get(target.space).append(el);
    void el.offsetWidth;
    el.style.transition = '';
    if (!noop) {
      const width = alone ? from(source).w : DEFAULT_WIDTH;
      const before = target.column ? null : target.space.cols[target.at];
      if (target.column) {
        // Reordering inside its own stack: the slot was counted with the window still in it.
        const own = target.column.wins.indexOf(win);
        const slot = own >= 0 && own < target.slot ? target.slot - 1 : target.slot;
        detach(source, win);
        target.column.wins.splice(Math.min(slot, target.column.wins.length), 0, win);
      } else {
        detach(source, win);
        const at = before ? target.space.cols.indexOf(before) : target.space.cols.length;
        target.space.cols.splice(at, 0, { w: width, wins: [win], focus: 0 });
      }
      focusWin(win);
      onCommand(null, 'drop');
    }
    render();
  };
  root.addEventListener('pointerup', endDrag);
  root.addEventListener('pointercancel', endDrag);

  // Defi's menu-bar item.
  function fillMenu() {
    defiMenu.innerHTML = `<p class="mh">Workspaces</p>${spaces.map((space, i) => `<button type="button" role="menuitemradio" aria-checked="${i === active}" data-ws="${i}"><span class="check">${i === active ? '✓' : ''}</span>${isEmpty(space) ? 'New Workspace' : i + 1}</button>`).join('')}<hr><button type="button" role="menuitem"><span class="check"></span>Settings…<kbd>⌘,</kbd></button><hr><button type="button" role="menuitem"><span class="check"></span>Quit Defi<kbd>⌘Q</kbd></button>`;
  }
  function closeMenu() {
    defiMenu.hidden = true;
    defiButton.classList.remove('open');
  }
  defiButton.addEventListener('click', event => {
    event.stopPropagation();
    if (!defiMenu.hidden) return closeMenu();
    fillMenu();
    defiMenu.hidden = false;
    defiButton.classList.add('open');
  });
  defiMenu.addEventListener('click', event => {
    event.stopPropagation();
    const item = event.target.closest('button');
    if (!item) return;
    if (item.dataset.ws) {
      if (messy) launch({ quick: true });
      active = Number(item.dataset.ws);
      overview = false;
      onCommand(null, `workspace ${active + 1}`);
      render();
    }
    closeMenu();
  });

  // The Dock activates the app's window: Defi follows it to its workspace and scrolls it into view.
  root.querySelectorAll('.dock-item').forEach(item => item.addEventListener('click', event => {
    event.stopPropagation();
    closeMenu();
    const app = item.dataset.app;
    const wins = space => [...space.cols.flatMap(c => c.wins), ...space.floats.map(f => f.win)];
    const win = wins(spaces[active]).find(w => w.app === app) ?? spaces.flatMap(wins).find(w => w.app === app);
    item.classList.remove('bounce');
    void item.offsetWidth;
    item.classList.add('bounce');
    if (!win) return;
    if (messy) launch({ quick: true });
    focusWin(win);
    overview = false;
    onCommand(null, `activate ${APPS[app].name}`);
    render();
  }));

  screen.addEventListener('click', () => {
    closeMenu();
    if (!overview) return;
    overview = false;
    render();
  });

  // Holding Control-Option alone for 600 ms shows the shortcuts, like Defi's cheatsheet.
  let sheetTimer;
  function hideSheet() {
    clearTimeout(sheetTimer);
    sheet.classList.remove('on');
  }
  function holdModifier() {
    clearTimeout(sheetTimer);
    sheetTimer = setTimeout(() => sheet.classList.add('on'), 600);
  }

  // Opening Defi from Spotlight: the windows leave the pile for their columns and workspaces.
  let launching = false;
  const spotlight = root.querySelector('.spotlight');
  const typed = root.querySelector('.sp-text');
  function launch({ quick = false, done = () => {} } = {}) {
    if (!messy) return done();
    const tidy = animate => {
      if (!messy) return;
      spotlight.classList.remove('on');
      root.classList.add('defi-running');
      root.classList.toggle('is-tidying', animate);
      messy = false;
      render();
      setTimeout(() => {
        root.classList.remove('is-tidying');
        render();
        done();
      }, animate ? 1300 : 0);
    };
    if (quick) return tidy(false);
    if (launching) return;
    launching = true;
    spotlight.classList.add('on');
    [...'Defi'].forEach((letter, i) => setTimeout(() => { typed.textContent = 'Defi'.slice(0, i + 1); }, 260 + i * 110));
    setTimeout(() => tidy(true), 1250);
  }
  if (!messy) root.classList.add('defi-running');

  const clock = root.querySelector('.mb-clock');
  const tick = () => {
    const now = new Date();
    clock.textContent = `${now.toLocaleDateString('en-US', { weekday: 'short' })} ${now.getDate()} ${now.toLocaleDateString('en-US', { month: 'short' })}  ${now.toLocaleTimeString('en-US', { hour: 'numeric', minute: '2-digit' })}`;
  };
  tick();
  setInterval(tick, 15000);

  new ResizeObserver(([entry]) => {
    root.style.setProperty('--scale', entry.contentRect.width / W);
  }).observe(root);
  const syncMotion = () => root.classList.toggle('no-anim', reducedMotion.matches);
  reducedMotion.addEventListener('change', syncMotion);
  syncMotion();
  render();
  return { press, pressInOverview, holdModifier, hideSheet, launch };
}
