import './style.css';
import { mountHeroTitle } from './hero-title.js';
import { mountDesk, windowMarkup, appIcon, cheatsheetMarkup, DEMO } from './desk.js';

const app = document.querySelector('#app');
const media = filename => `${import.meta.env.BASE_URL}media/${filename}`;
const repo = 'https://github.com/qeude/Defi';
const command = 'brew install --cask qeude/tap/defi';
const reducedMotion = matchMedia('(prefers-reduced-motion: reduce)');
const icon = (size = 28) => `<img class="brand-icon" src="${media('defi-icon.png')}" alt="" width="${size}" height="${size}">`;
const githubIcon = `<svg aria-hidden="true" width="16" height="16" viewBox="0 0 16 16" fill="currentColor"><path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82a7.65 7.65 0 0 1 4 0c1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.01 8.01 0 0 0 16 8c0-4.42-3.58-8-8-8Z"/></svg>`;
const copyIcon = `<svg aria-hidden="true" width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><rect x="9" y="9" width="11" height="11" rx="2"/><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/></svg>`;
const arrow = '<span aria-hidden="true">→</span>';
const kbd = keys => keys.map(key => `<kbd>${key}</kbd>`).join('');

const curlCommand = 'curl -fsSL https://raw.githubusercontent.com/qeude/Defi/main/script/install.sh | sh';
const chevron = `<svg aria-hidden="true" width="12" height="12" viewBox="0 0 12 12" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="m2.5 4.5 3.5 3.5 3.5-3.5"/></svg>`;
const installMenu = `<details class="install-more"><summary aria-label="Other ways to install" title="Other ways to install">${chevron}</summary><div class="install-menu"><p><b>With curl</b></p><button type="button" class="copy-line" data-copy="${curlCommand}" title="Copy the curl command"><code>${curlCommand}</code>${copyIcon}<span class="visually-hidden" role="status"></span></button><p><b>With the DMG.</b> Download it from the <a href="${repo}/releases/latest">latest release</a> and drag Defi to Applications. macOS blocks its first launch: open Defi, close the warning, click Open Anyway in System Settings › Privacy &amp; Security, and confirm.</p><p class="note">Defi is self-signed and not notarized, so only install it if you trust this source.</p></div></details>`;
const installButton = () => `<div class="install"><button type="button" class="install-button" data-copy title="Copy the Homebrew command"><code>${command}</code>${copyIcon}<span class="visually-hidden" role="status"></span></button>${installMenu}</div>`;

function recording(clip, poster, description) {
  return `<video muted loop playsinline preload="none" data-autoplay poster="${media(poster)}" aria-label="${description}" width="1920" height="1080"><source src="${media(clip)}" type="video/mp4"></video>`;
}

const keypad = [
  ['ArrowLeft', '←', 'Left'], ['ArrowRight', '→', 'Right'], ['ArrowUp', '↑', 'Workspace up'], ['ArrowDown', '↓', 'Workspace down'],
  ['Minus', '−', 'Narrower'], ['Equal', '=', 'Wider'], ['KeyO', 'O', 'Overview'], ['KeyF', 'F', 'Maximize'],
];

const faq = [
  ['Is Defi free?', 'Yes. Defi is free and open source under the MIT license. There is no account and nothing to buy.'],
  ['How do I start?', `Run <code>${command}</code>, then open Defi from Applications. Allow Accessibility when macOS asks, then Screen Recording for window pictures and animations. Defi works with built-in defaults.`],
  ['Which Macs does Defi support?', 'Apple Silicon Macs running macOS 26 or newer. This alpha does not support Intel Macs.'],
  ['Does it control macOS Spaces?', 'No. Defi manages its own virtual workspaces and leaves native Spaces alone. Clicks, the Dock and Command-Tab still work.'],
  ['Which permissions does it need, and why?', `<span class="perm"><b>Accessibility</b> (required). It is the public macOS interface for reading, moving, resizing and focusing other apps' windows. Defi uses it to place every window in its column, focus the one you choose and park other workspaces off screen. Defi asks on first launch and starts as soon as you allow it in System Settings › Privacy & Security.</span><span class="perm"><b>Screen Recording</b> (optional). Many apps apply a move late, so moving real windows frame by frame stutters. Defi animates pictures of your windows instead and moves each real window once underneath; Overview shows the same pictures. Without it, windows move at once and Overview shows cards without pictures.</span><span class="perm"><b>Your data.</b> The pictures stay in memory on your Mac, never on disk. Defi has no network code, no analytics and no account. <code>defi uninstall --purge</code> removes the app, its data and its permissions.</span>`],
  ['Does it support several monitors?', 'Yes. Each monitor keeps its own workspaces, active workspace and layout. Switching on one leaves the others as they are.'],
  ['Can I change the shortcuts?', `Yes. Defi's Settings window changes shortcuts, gaps, column widths and app rules. The same options live in a TOML file; see the <a href="${repo}/blob/main/CONFIGURATION.md">configuration reference</a>.`],
  ['Is it ready for everyday use?', `Defi is an experimental alpha, self-signed and not notarized. Behavior and configuration may change before the first stable release. Read the <a href="${repo}#alpha-limitations">alpha limitations</a>.`],
];

const heroTitle = 'Your desktop, without the edges.';
const word = (text, delay) => `<span class="hword" style="--d:${delay}ms">${text}</span>`;

// The closing light: Defi's columns (equal heights, preset widths, 8 px gaps), one focused, scrolling past in a loop.
const lightColumns = [0.5, 0.33, 0.8, 0.5, 0.66, 0.33, 0.66, 0.5, 0.33, 0.66, 0.5, 0.8].map((w, i) => `<i class="${i === 2 ? 'on' : ''}" style="width:${Math.round(w * 420)}px"></i>`).join('');

// A window in the feature illustrations: title bar, app icon and, when focused, Defi's border.
const miniWin = (app, cls = '') => `<span class="mw ${cls}">${appIcon(app)}</span>`;
const card = (cls, illustration, title, text) => `<article class="card ${cls}"><div class="card-art">${illustration}</div><div class="card-copy"><h3>${title}</h3><p>${text}</p></div></article>`;

app.innerHTML = `
<header class="nav"><a class="wordmark" href="#top">${icon()}<span>Defi</span></a>
  <nav aria-label="Main navigation" class="nav-pill"><a href="#features">Features</a><a href="#shortcuts">Shortcuts</a><a href="#faq">FAQ</a></nav>
  <div class="nav-actions"><a class="pill pill-dark" href="${repo}">${githubIcon}<span>GitHub</span></a><a class="pill pill-light" href="#install">Install</a></div></header>
<main id="main">
  <section class="hero" id="top">
    <div class="hero-bg" aria-hidden="true"><i class="hb-cols"></i><i class="hb-aurora"></i></div>
    <p class="badge"><span>ALPHA</span>For Apple Silicon Macs on macOS 26</p>
    <h1 aria-label="${heroTitle}"><span aria-hidden="true">${word('Your', 80)} ${word('desktop,', 160)}<br>${word('without', 400)} ${word('the', 480)} <span class="hword" data-dissolve style="--d:560ms">edges.</span></span></h1>
    <p class="lede">Defi is a scrolling window manager for macOS: windows line up side by side on one strip, and the keyboard takes you along it.</p>
    <div class="actions">${installButton()}<a class="pill pill-dark pill-lg" href="${repo}">${githubIcon}<span>GitHub</span></a></div>
    <div class="desk-stage"><div class="desk-horizon" aria-hidden="true"></div><div class="desk-bezel" aria-hidden="true"></div><div class="desk" tabindex="0" role="application" aria-label="Interactive Defi preview. Use Control-Option with the arrow keys, minus, equal, O or F. Hold Control-Option to see the shortcuts."></div></div>
    <div class="keypad" role="group" aria-label="Try Defi shortcuts">${keypad.map(([code, glyph, label]) => `<button type="button" data-code="${code}" aria-label="Control-Option ${label}">${kbd(['⌃', '⌥', glyph])}<span>${label}</span></button>`).join('')}<button type="button" class="keypad-hold" aria-label="Hold Control-Option to see all shortcuts">${kbd(['⌃', '⌥'])}<span>${matchMedia('(hover:none)').matches ? 'All shortcuts' : 'Hold for all shortcuts'}</span></button></div>
    <p class="desk-caption visually-hidden" aria-live="polite"></p>
</section>

  <section class="features" id="features" aria-labelledby="features-title">
    <h2 id="features-title">What Defi does</h2>
    <p class="section-lede left">A tiling window manager built around one idea from Niri: columns that scroll, on the Mac you already use.</p>
    <div class="bento">
      ${card('b-hero card-video', recording('feature-overview.mp4', 'feature-overview.jpg', 'Defi Overview browsing workspace rows and their windows'), 'Every window at a glance', 'Zoom out to every workspace, with live pictures of your windows. Click one to go there.')}
      ${card('b-side', `<div class="ill-native"><div class="cmdtab">${['safari', 'ghostty', 'xcode', 'messages', 'music'].map((a, i) => `<span class="${i === 2 ? 'on' : ''}">${appIcon(a)}${i === 2 ? '<em>Xcode</em>' : ''}</span>`).join('')}</div><p>${kbd(['⌘'])}<span>+</span>${kbd(['⇥'])}</p></div>`, 'Still a Mac', 'Clicks, the Dock and Command-Tab take you to the right workspace.')}
      ${card('b-split', `<div class="hz-light" aria-hidden="true">${[0.33, 0.5, 0.8, 0.5, 0.33].map((w, i) => `<i class="${i === 2 ? 'on' : ''}" style="flex:${w}"></i>`).join('')}</div><p class="ill-hz" aria-label="120 Hz"><b aria-hidden="true">120</b><span>Hz</span></p>`, 'Fast as your keys', 'Animations at up to 120 Hz. Commands never wait for a slow app.')}
      ${card('b-5', `<div class="mini ill-reflow">${miniWin('safari')}${miniWin('xcode', 'on new')}${miniWin('ghostty')}${miniWin('notes')}</div>`, 'Columns that reflow', 'Open a window and it joins the strip. Widen or close one and the others make room.')}
      ${card('b-4', `<div class="ill-monitors"><div class="mini mon">${miniWin('safari', 'on')}${miniWin('ghostty')}${miniWin('notes')}</div><div class="mini mon small">${miniWin('music', 'on')}${miniWin('mail')}</div></div>`, 'One layout per monitor', 'Each display keeps its own workspaces, focus and scroll.')}
      ${card('b-3', `<div class="mini ill-float">${miniWin('safari')}${miniWin('ghostty')}${miniWin('notes')}${miniWin('music', 'on float')}</div>`, 'Floating when you need it', 'One key lifts a window above the columns.')}
    </div>
  </section>

  <section class="shortcuts" id="shortcuts" aria-labelledby="shortcuts-title">
    <h2 id="shortcuts-title">Hold <span class="key-pair"><kbd class="key-option" aria-label="Control"><small>⌃</small><span>control</span></kbd><kbd class="key-option" aria-label="Option"><small>⌥</small><span>option</span></kbd></span></h2><div><p class="section-lede left">Forget a shortcut? Hold Control and Option for a moment and Defi shows them all on the screen you are using. Release them and they are gone.</p><a class="text-link" href="${repo}/blob/main/CONFIGURATION.md">Change them in Settings or the config ${arrow}</a></div>
    <div class="sheet-shot" aria-hidden="true"><div class="sheet-screen"><div class="win" style="left:8px;width:944px">${windowMarkup({ app: 'safari', title: 'GitHub — qeude/Defi' })}</div><div class="win" style="left:960px;width:472px">${windowMarkup({ app: 'ghostty', title: '~' })}</div><div class="cheatsheet on">${cheatsheetMarkup()}</div></div></div>
  </section>

  <section class="faq" id="faq" aria-labelledby="faq-title">
    <div><h2 id="faq-title">Questions</h2><p class="section-lede left">Short answers about compatibility, permissions and the alpha.</p><a class="text-link" href="${repo}#troubleshooting">Troubleshooting notes ${arrow}</a></div>
    <div class="faq-list">${faq.map(([q, a]) => `<details><summary>${q}<i aria-hidden="true"></i></summary><p>${a}</p></details>`).join('')}</div>
  </section>

  <section class="cta" id="install" aria-labelledby="cta-title">
    ${icon(72)}
    <h2 id="cta-title">Try Defi on your Mac.</h2>
    <p class="section-lede">Paste the command into Terminal, then open Defi from Applications.</p>
    <div class="actions">${installButton()}<a class="pill pill-dark pill-lg" href="${repo}">${githubIcon}<span>Star on GitHub</span></a></div>
  </section>
</main>
<div class="closing">
<div class="foot-art" aria-hidden="true"><div class="fl-track">${lightColumns}${lightColumns}</div></div>
<footer class="footer"><a class="wordmark" href="#top">${icon(22)}<span>Defi</span></a><p>Experimental alpha · <a href="${repo}/blob/main/LICENSE">MIT</a> · Inspired by <a href="https://github.com/YaLTeR/niri">Niri</a></p><a href="${repo}">GitHub</a></footer>
</div>`;

// Copy buttons
const bindCopy = button => button.addEventListener('click', async () => {
  const status = button.querySelector('[role=status]');
  const text = button.dataset.copy || command;
  try {
    await navigator.clipboard.writeText(text);
    button.dataset.copied = '';
    status.textContent = 'Copied. Paste into Terminal.';
    setTimeout(() => delete button.dataset.copied, 1600);
  } catch {
    status.textContent = `Copy failed. The command is ${text}`;
  }
});
app.querySelectorAll('[data-copy]').forEach(bindCopy);

// The install menu closes like a menu: on a click elsewhere or Escape.
const closeInstallMenus = (except) => app.querySelectorAll('.install-more[open]').forEach(menu => { if (!menu.contains(except)) menu.open = false; });
document.addEventListener('click', event => closeInstallMenus(event.target));
document.addEventListener('keydown', event => { if (event.key === 'Escape') closeInstallMenus(); });

mountHeroTitle(app.querySelector('.hero'), reducedMotion);

// Interactive desk: a short demo plays until the visitor takes over.
const desk = app.querySelector('.desk');
const caption = app.querySelector('.desk-caption');
const keypadButtons = new Map([...app.querySelectorAll('.keypad button[data-code]')].map(button => [button.dataset.code, button]));
let demoTimer;
let demoStep = 0;
let userDriven = false;
let deskVisible = false;
let deskOnScreen = false;
let deskHovered = false;
const onCommand = (code, command) => {
  const button = keypadButtons.get(code);
  if (button) {
    button.classList.add('pressed');
    setTimeout(() => button.classList.remove('pressed'), 450);
  }
  if (command === 'click') return;
  // Screen readers hear the visitor's commands, not the demo's; the keypad shows the press.
  if (userDriven) caption.textContent = command;
};
const controller = mountDesk(desk, { reducedMotion, onCommand });
const touchOnly = matchMedia('(hover:none)').matches;
desk.insertAdjacentHTML('beforeend', `<p class="desk-invite" aria-hidden="true">${touchOnly ? 'Go on, tap a key below' : `<span class="desk-invite-line">Go on, press <span class="desk-invite-keys">${kbd(['⌃', '⌥', '→'])}</span></span><small>Right</small>`}</p>`);
const invite = desk.querySelector('.desk-invite');
let demoPress;
let demoRelease;
// The demo plays its shortcuts on the invitation's keys: the modifiers go down and stay, then the key lands and the desk moves.
const demoKeys = new Map([...keypad.map(([code, glyph, label]) => [code, [glyph, label]]), ['Semicolon', [';', 'Join left column']], ['KeyK', ['K', 'Window up']], ['KeyJ', ['J', 'Window down']], ['KeyR', ['R', 'Unjoin']], ['BracketLeft', ['[', 'First column']]]);
const playDemoKey = code => {
  const key = invite.querySelector('kbd:last-child');
  if (key) {
    [key.textContent, invite.querySelector('small').textContent] = demoKeys.get(code);
    invite.classList.add('held');
  }
  demoPress = setTimeout(() => {
    controller.press(code);
    invite.classList.add('press');
    demoRelease = setTimeout(() => invite.classList.remove('held', 'press'), 350);
  }, 450);
};
const clearDemo = () => {
  clearInterval(demoTimer);
  clearTimeout(demoPress);
  clearTimeout(demoRelease);
  invite.classList.remove('held', 'press');
};
const stopDemo = () => {
  invite.classList.add('gone');
  introDone = true;
  userDriven = true;
  clearDemo();
};
// The desk opens on an ordinary crowded desktop; Defi starts from Spotlight when the visitor scrolls or after a moment.
let introDone = false;
let introTimer;
const startIntro = () => {
  clearTimeout(introTimer);
  controller.launch({ done: () => setTimeout(() => { introDone = true; syncDemo(); }, 600) });
};
const syncDemo = () => {
  clearDemo();
  if (deskVisible && !introDone) introTimer ||= setTimeout(startIntro, 1600);
  if (!introDone || userDriven || reducedMotion.matches || !deskVisible || document.hidden) return;
  demoTimer = setInterval(() => playDemoKey(DEMO[demoStep++ % DEMO.length]), 1500);
};
new IntersectionObserver(([entry]) => {
  deskVisible = entry.intersectionRatio >= 0.2;
  deskOnScreen = entry.isIntersecting;
  syncDemo();
}, { threshold: [0, 0.2] }).observe(desk);
document.addEventListener('visibilitychange', syncDemo);
reducedMotion.addEventListener('change', syncDemo);

desk.addEventListener('pointerenter', () => { deskHovered = true; });
desk.addEventListener('pointerleave', () => { deskHovered = false; });
desk.addEventListener('pointerdown', stopDemo);
// Capture: Dock and menu handlers stop propagation, and keyboard activation sends no pointerdown.
desk.addEventListener('click', () => {
  stopDemo();
  // Tidied on click, not pointerdown, so a click on a window in the pile still lands on it.
  controller.launch({ quick: true });
}, true);
keypadButtons.forEach((button, code) => button.addEventListener('click', () => {
  stopDemo();
  controller.press(code);
}));
const showSheet = () => {
  stopDemo();
  controller.launch({ quick: true });
  controller.holdModifier();
};
const holdButton = app.querySelector('.keypad-hold');
if (!touchOnly) {
  holdButton.addEventListener('pointerdown', showSheet);
  ['pointerup', 'pointerleave'].forEach(type => holdButton.addEventListener(type, controller.hideSheet));
}
holdButton.addEventListener('blur', controller.hideSheet);
// Touch and keyboard cannot hold a button, so for them it opens and closes.
holdButton.addEventListener('click', event => {
  if (!touchOnly && event.detail) return;
  if (desk.querySelector('.cheatsheet').classList.contains('on')) controller.hideSheet();
  else showSheet();
});
// Every shortcut works while the preview is on screen, no click needed; plain keys only act inside the Overview.
const modifierKeys = ['Control', 'Alt'];
document.addEventListener('keydown', event => {
  if (event.metaKey || event.target.closest('input, textarea, select')) return;
  // Any sliver of the desk counts: the invitation at its top shows long before a fifth of it does.
  const engaged = deskOnScreen || document.activeElement === desk || deskHovered;
  const mod = event.ctrlKey && event.altKey;
  if (modifierKeys.includes(event.key)) {
    if (mod && engaged && !event.repeat) {
      showSheet();
    }
    return;
  }
  // The hold entry's own Return and Space toggle the sheet in its click handler.
  if (!(event.target.closest('.keypad-hold') && ['Enter', ' '].includes(event.key))) controller.hideSheet();
  if (event.ctrlKey !== event.altKey) return;
  if (!engaged) return;
  // Before the visitor takes over, plain keys still scroll; Return still activates a focused link or button.
  if (!mod && (!userDriven || (['Enter', ' '].includes(event.key) && event.target.closest('a, button, summary')))) return;
  const handled = mod ? controller.press(event.code, event.shiftKey) : controller.pressInOverview(event.code);
  if (handled) {
    event.preventDefault();
    stopDemo();
  } else if (!mod && event.key === 'Escape') desk.blur();
});
document.addEventListener('keyup', event => {
  if (modifierKeys.includes(event.key)) controller.hideSheet();
});
addEventListener('blur', () => controller.hideSheet());

// The desk opens to the full width as it reaches the top, and the light columns rise, as the page scrolls.
const closing = app.querySelector('.closing');
const footArt = closing.querySelector('.foot-art');
const stage = app.querySelector('.desk-stage');
const growing = [desk, stage.querySelector('.desk-bezel')];
const opening = [stage.querySelector('.desk-bezel'), stage.querySelector('.desk-horizon')];
let scrollFrame = 0;
const clamp01 = x => Math.min(1, Math.max(0, x));
const updateScroll = () => {
  scrollFrame = 0;
  // Read all geometry before writing, so a frame never forces a second layout.
  const stageBox = stage.getBoundingClientRect();
  const rise = closing.getBoundingClientRect();
  const rest = Math.min(1060, stageBox.width - 40) / stageBox.width;
  const eased = reducedMotion.matches ? 0 : 1 - (1 - clamp01(scrollY / Math.max(1, stageBox.top + scrollY - Math.min(innerHeight * 0.1, 90)))) ** 3;
  const grow = (rest + (1 - rest) * eased).toFixed(4);
  const open = (1 - eased).toFixed(4);
  for (const element of growing) element.style.setProperty('--grow', grow);
  for (const element of opening) element.style.setProperty('--open', open);
  // Square the corners once the desk is about 96% wide, not at the very end of the scroll.
  desk.classList.toggle('is-open', eased > 0.85);
  if (eased > 0.17 && !introDone) startIntro();
  footArt.firstElementChild.style.setProperty('--rise', reducedMotion.matches ? 1 : clamp01((innerHeight - rise.top) / rise.height).toFixed(4));
};
addEventListener('scroll', () => { scrollFrame ||= requestAnimationFrame(updateScroll); }, { passive: true });
addEventListener('resize', updateScroll);
new ResizeObserver(([entry]) => entry.target.style.setProperty('--scale', entry.contentRect.width / 1440)).observe(app.querySelector('.sheet-shot'));
updateScroll();

// The page's own rubber band: pulled past an end, the content moves away and the glow behind it stretches to fill the
// gap, where the native one would show flat background. style.css turns the native one off.
const main = app.querySelector('main');
const footer = closing.querySelector('.footer');
const heroBg = app.querySelector('.hero-bg');
let stretch = 0;
let settleTimer = 0;
let settleFrame = 0;
let pullClock = 0;
const applyPull = () => {
  const pull = 180 * (1 - 1 / (1 + Math.abs(stretch) * 0.55 / 180));
  const y = Math.sign(stretch) * pull;
  main.style.translate = y ? `0 ${y}px` : '';
  footer.style.translate = stretch < 0 ? `0 ${y}px` : '';
  footArt.style.scale = stretch < 0 ? `1 ${1 + pull / footArt.offsetHeight}` : '';
  heroBg.style.translate = stretch > 0 ? `0 ${-y}px` : '';
  heroBg.style.scale = stretch > 0 ? `1 ${1 + pull / heroBg.offsetHeight}` : '';
};
const settlePull = time => {
  const elapsed = time - pullClock;
  pullClock = time;
  stretch *= Math.exp(-(elapsed || 16) / 110);
  if (Math.abs(stretch) < 1) stretch = 0;
  applyPull();
  settleFrame = stretch ? requestAnimationFrame(settlePull) : 0;
};
addEventListener('wheel', event => {
  if (reducedMotion.matches || event.ctrlKey || Math.abs(event.deltaX) > Math.abs(event.deltaY)) return;
  const delta = event.deltaY * (event.deltaMode ? 16 : 1);
  const atTop = scrollY <= 0;
  const atBottom = scrollY >= document.documentElement.scrollHeight - innerHeight - 1;
  // Positive stretch is a pull past the top, negative past the bottom; turning back lets the page scroll and settles.
  const pulling = (delta < 0 && atTop) || (delta > 0 && atBottom);
  if (!pulling && (!stretch || settleFrame)) return;
  cancelAnimationFrame(settleFrame);
  settleFrame = 0;
  clearTimeout(settleTimer);
  if (pulling) { stretch -= delta; applyPull(); }
  settleTimer = setTimeout(() => { pullClock = performance.now(); settleFrame = requestAnimationFrame(settlePull); }, pulling ? 90 : 0);
}, { passive: true });

// Feature clips play while on screen in a visible tab; reduced motion shows controls instead.
const videos = [...app.querySelectorAll('video')];
const onScreen = new Set();
const syncVideo = video => {
  video.controls = reducedMotion.matches;
  if (!onScreen.has(video) || document.hidden || reducedMotion.matches || video.dataset.userPaused) video.pause();
  else video.play().catch(() => {});
};
const videoObserver = new IntersectionObserver(entries => entries.forEach(({ target, isIntersecting }) => {
  if (isIntersecting) onScreen.add(target);
  else onScreen.delete(target);
  syncVideo(target);
}));
videos.forEach(video => videoObserver.observe(video));
// A click or tap pauses or resumes a clip, and the pause sticks; native controls handle this under reduced motion.
videos.forEach(video => video.addEventListener('click', () => {
  if (video.controls) return;
  if (video.paused) delete video.dataset.userPaused;
  else video.dataset.userPaused = 'true';
  syncVideo(video);
}));
document.addEventListener('visibilitychange', () => videos.forEach(syncVideo));
reducedMotion.addEventListener('change', () => videos.forEach(syncVideo));

// The speed card snaps from 0 to 120 Hz: the count races up and brakes on an exponential curve while the number
// rises into place from a blur; Hz settles in just after. It plays once, when the card comes into view.
const hz = app.querySelector('.ill-hz');
const [hzValue, hzUnit] = hz.children;
const settle = 'cubic-bezier(.16,1,.3,1)';
const countHz = () => {
  const start = performance.now();
  const step = now => {
    const t = Math.min(1, (now - start) / 600);
    hzValue.textContent = Math.round(120 * (1 - 2 ** (-10 * t)) / (1 - 2 ** -10));
    if (t < 1) requestAnimationFrame(step);
  };
  requestAnimationFrame(step);
  hzValue.animate([{ filter: 'blur(10px)', transform: 'translateY(.12em)', opacity: 0 }, { filter: 'blur(0)', transform: 'none', opacity: 1 }], { duration: 700, easing: settle });
  hzUnit.animate([{ transform: 'translateY(-.3em)', opacity: 0 }, { transform: 'none', opacity: 1 }], { duration: 500, delay: 380, easing: settle, fill: 'backwards' });
  // Defi's columns, as the footer's light, rise behind the number in a quick stagger, the focused one in the middle first.
  hz.parentElement.querySelectorAll('.hz-light i').forEach((column, i) => column.animate([{ transform: 'scaleY(0)', opacity: 0 }, { transform: 'none', opacity: 1 }], { duration: 650, delay: Math.abs(i - 2) * 60, easing: settle, fill: 'backwards' }));
};
if (!reducedMotion.matches) {
  hzValue.textContent = '0';
  new IntersectionObserver(([entry], observer) => {
    if (!entry.isIntersecting) return;
    observer.disconnect();
    setTimeout(countHz, 150);
  }, { threshold: 0.6 }).observe(hz);
}

// The reflow and floating illustrations start looping once their card is well in view.
if (!reducedMotion.matches) {
  const player = new IntersectionObserver(entries => entries.forEach(({ target, isIntersecting }) => {
    if (!isIntersecting) return;
    player.unobserve(target);
    target.classList.add('play');
  }), { threshold: 0.6 });
  app.querySelectorAll('.bento .card').forEach(card => player.observe(card));
}

// Reveal on scroll.
if (!reducedMotion.matches) {
  const reveal = new IntersectionObserver(entries => entries.forEach(entry => {
    if (!entry.isIntersecting) return;
    entry.target.classList.add('in');
    reveal.unobserve(entry.target);
  }), { threshold: 0.12 });
  app.querySelectorAll('.card, .shortcuts, .faq, .cta, .features > h2').forEach(element => {
    element.classList.add('reveal');
    reveal.observe(element);
  });
}
