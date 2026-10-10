import './style.css';
import './direction.css';
import { mountHeroField } from './hero-field.js';
const heroHorizon = `<div class="edge-world">
  <div class="edge-aura"></div>
  <img class="edge-artwork" src="${import.meta.env.BASE_URL}media/horizon-artwork.webp" width="1536" height="1024" alt="" decoding="async" fetchpriority="high">
  <div class="edge-reflection"></div>
</div>`;



const app = document.querySelector('#app');
const media = filename => `${import.meta.env.BASE_URL}media/${filename}`;
const repo = 'https://github.com/qeude/Defi';
const command = 'brew install --cask qeude/tap/defi';
const features = {
  columns: {
    title: 'Move between windows', subtitle: 'Scrolling columns',
    caption: 'Your next window is a keypress away.', description: 'Focus a column and the whole strip moves with it. The next window comes into view.',
    defaultShortcut: 'Option + ← / →',
    illustration: {
      description: 'A horizontal ribbon pans left to bring the selected column into the center. Neighboring columns remain on the same strip.',
      windows: [
        { label: 'Reference', from: [4, 16, 30, 72], to: [-16, 16, 30, 72] },
        { label: 'Your focus', focus: true, from: [36, 13, 42, 78], to: [16, 13, 42, 78] },
        { label: 'Notes', from: [80, 16, 30, 72], to: [60, 16, 30, 72] },
        { label: 'Next', from: [112, 16, 30, 72], to: [92, 16, 30, 72] },
      ],
    },
    recording: { poster: 'defi-columns.jpg', clip: 'defi-columns-clip.mp4', description: 'Defi scrolling between native macOS window columns' },
  },
  workspaces: {
    title: 'Give each task its own space', subtitle: 'Virtual workspaces',
    caption: 'Pick up where you left off.', description: 'Switch from code to research, then return to the windows and widths you left in place.',
    defaultShortcut: 'Option + ↑ / ↓',
    illustration: {
      description: 'A workspace with Reference and Notes moves up and out. A separate arrangement with Project and Research takes its place.',
      windows: [
        { label: 'Reference', from: [5, 16, 54, 72], to: [5, -94, 54, 72] },
        { label: 'Notes', from: [61, 16, 34, 72], to: [61, -94, 34, 72] },
        { label: 'Project', focus: true, from: [5, 126, 34, 72], to: [5, 16, 34, 72] },
        { label: 'Research', from: [41, 126, 54, 72], to: [41, 16, 54, 72] },
      ],
    },
  },
  overview: {
    title: 'Find a window at a glance', subtitle: 'Workspace Overview',
    caption: 'See your windows across workspaces.', description: 'Open Overview to browse your workspace rows. Select a window to return to it.',
    defaultShortcut: 'Option + O',
    illustration: {
      description: 'The view pulls back from one workspace to three separate workspace groups. The selected window stays highlighted in its group.',
      pullback: true,
      groups: ['Project', 'Research', 'Next task'],
      windows: [
        { label: 'Editor', focus: true, to: [9, 15, 35, 18] },
        { label: 'Notes', to: [46, 15, 26, 18] },
        { label: 'Reference', to: [9, 45, 26, 18] },
        { label: 'Browser', to: [37, 45, 43, 18] },
        { label: 'Draft', to: [9, 75, 43, 18] },
      ],
    },
    recording: { poster: 'defi-overview.jpg', clip: 'defi-overview-clip.mp4', description: 'Defi Overview browsing workspace rows and their windows' },
    chapter: { title: 'See where everything is.', description: 'Overview brings your workspaces into one view. Choose a window and return to that task.' },
  },
  widths: {
    title: 'Make room for the current window', subtitle: 'Column widths',
    caption: 'More room for the window you’re using.', description: 'Widen your editor or browser. The neighboring columns reflow to make room.',
    defaultShortcut: 'Option + − / =',
    illustration: {
      description: 'The selected column widens. The reference column shifts left and the notes column shifts right to make room.',
      windows: [
        { label: 'Reference', from: [5, 16, 27, 72], to: [-13, 16, 27, 72] },
        { label: 'Your focus', focus: true, from: [34, 13, 32, 78], to: [16, 13, 54, 78] },
        { label: 'Notes', from: [68, 16, 27, 72], to: [72, 16, 27, 72] },
      ],
    },
  },
};
let selectedId = 'columns';
const reducedMotion = matchMedia('(prefers-reduced-motion: reduce)');
const mark = `<img class="brand-icon" src="${media('defi-icon.png')}" alt="" width="32" height="32">`;

function geometry([left, top, width, height]) {
  return { left: `${left}%`, top: `${top}%`, width: `${width}%`, height: `${height}%` };
}

function illustration(scene) {
  return `<div class="diagram" role="img" aria-label="${scene.description}"><div class="scene-map" aria-hidden="true">
    ${(scene.groups || []).map((label, i) => `<div class="workspace-group" style="top:${i * 30 + 5}%"><span>${label}</span></div>`).join('')}
    ${scene.windows.map(window => `<div class="diagram-window${window.focus ? ' is-focus' : ''}" style="${Object.entries(geometry(window.to)).map(([key, value]) => `${key}:${value}`).join(';')}"><span>${window.label}</span><i></i><i></i><i></i></div>`).join('')}
  </div></div>`;
}

function recording({ poster, clip, description }) {
  return `<figure class="recording"><div class="recording-frame"><video controls playsinline preload="none" poster="${media(poster)}" aria-label="${description}" width="1920" height="1246"><source src="${media(clip)}" type="video/mp4"><a href="${media(clip)}">Open the recording</a></video><img class="error-poster" src="${media(poster)}" alt="${description}" width="1920" height="1246" hidden></div><p class="video-error" role="status" hidden>Recording unavailable. <a href="${media(clip)}">Open the clip directly</a> or <a href="${repo}#readme">view the project README</a>.</p></figure>`;
}

function installControl(id) {
  return `<div class="install-control"><div class="install-command"><code>${command}</code><button type="button" class="copy-button" aria-label="Copy Homebrew command" aria-describedby="${id}-status" title="Copy command"><svg aria-hidden="true" focusable="false" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><rect x="9" y="9" width="11" height="11" rx="2"/><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/></svg></button></div><p id="${id}-status" class="copy-status" role="status"></p></div>`;
}

function cancelMotion() {
  app.querySelector('#feature-panel').getAnimations({ subtree: true }).forEach(animation => animation.cancel());
}

function replay() {
  cancelMotion();
  if (reducedMotion.matches) return;
  const scene = features[selectedId].illustration;
  const options = { duration: 750, easing: 'cubic-bezier(.22,.7,.25,1)' };
  app.querySelectorAll('#feature-panel .diagram-window').forEach((element, index) => {
    const window = scene.windows[index];
    if (window.from) element.animate([geometry(window.from), geometry(window.to)], options);
  });
  if (scene.pullback) app.querySelector('#feature-panel .scene-map').animate([
    { transform: 'translate(-5%, -3%) scale(1.85)' }, { transform: 'translate(0, 0) scale(1)' },
  ], options);
}

function selectFeature(id) {
  if (!Object.hasOwn(features, id) || id === selectedId) return;
  cancelMotion();
  selectedId = id;
  const feature = features[selectedId];
  app.querySelector('.scene-content').innerHTML = illustration(feature.illustration);
  app.querySelector('#panel-title').textContent = feature.caption;
  app.querySelector('#panel-description').textContent = feature.description;
  app.querySelector('#panel-shortcut').textContent = feature.defaultShortcut;
  app.querySelectorAll('[data-feature]').forEach(button => button.setAttribute('aria-pressed', String(button.dataset.feature === selectedId)));
  app.querySelector('#feature-status').textContent = `${feature.title} selected.`;
  replay();
}

function scrollToSection(event) {
  const target = document.querySelector(event.currentTarget.getAttribute('href'));
  if (!target) return;
  event.preventDefault();
  target.tabIndex = -1;
  target.scrollIntoView();
  target.focus({ preventScroll: true });
}

function landing() {
  const selected = features[selectedId];
  const overview = features.overview;
  app.innerHTML = `<header class="site-nav"><a class="wordmark" href="#main">${mark}<span>Defi</span></a><nav aria-label="Main navigation"><a href="#product">Features</a><a href="#install">First launch</a><a href="${repo}">GitHub</a></nav></header>
    <main id="main">
    <section class="hero"><div class="hero-atmosphere" aria-hidden="true">${heroHorizon}<canvas hidden></canvas></div><div class="hero-copy"><h1><span class="headline-line">Your desktop,</span><br><span class="headline-line">without the edges.</span></h1><p class="hero-description">A scrolling window manager for macOS. Keep windows side by side and switch tasks with your keyboard.</p>
    <div class="install-row">${installControl('hero')}<a class="hero-github" href="${repo}">GitHub</a></div>
    <p class="first-launch-note">Then open Defi from Applications. <a href="#install">First launch steps</a></p>
    <p class="requirements">For Apple Silicon Macs on macOS 26 or later.</p></div>
    <div class="hero-visual">${recording(features.columns.recording)}</div></section>
    <div class="project-proof"><p>Built for native macOS windows.</p><p>An experimental alpha. <a href="${repo}/blob/main/LICENSE">MIT licensed and open source.</a></p></div>
    <section class="product-section" id="product" aria-labelledby="product-title"><div class="section-intro"><h2 id="product-title">Keep your work within reach.</h2><p>Move through your windows in a continuous strip.<br>Keep each task in its own workspace.</p></div>
    <div class="feature-theatre"><div class="feature-choices" aria-label="Explore features">${Object.entries(features).map(([id, feature]) => `<button type="button" data-feature="${id}" aria-pressed="${id === selectedId}" aria-controls="feature-panel"><span>${feature.title}</span><small>${feature.subtitle}</small></button>`).join('')}</div>
    <section id="feature-panel" class="feature-panel" aria-labelledby="panel-title"><div class="scene-toolbar"><span>Interactive illustration</span><button type="button" class="replay-button">Replay</button></div><div class="scene-content">${illustration(selected.illustration)}</div><div class="panel-caption"><h3 id="panel-title">${selected.caption}</h3><p id="panel-description">${selected.description}</p><p class="shortcut">Default shortcut <kbd id="panel-shortcut">${selected.defaultShortcut}</kbd></p></div></section></div>
    <p id="feature-status" class="visually-hidden" role="status" aria-live="polite" aria-atomic="true"></p>
    <div class="monitor-fact"><h3>Each monitor keeps its own space.</h3><p>Switch workspaces on one monitor.<br>The other keeps its own layout.</p></div></section>
    <section class="overview-chapter" aria-labelledby="overview-title"><div><h2 id="overview-title">${overview.chapter.title}</h2><p>${overview.chapter.description}</p><p class="shortcut">Default shortcut <kbd>${overview.defaultShortcut}</kbd></p></div>${recording(overview.recording)}</section>
    <section class="faq-section" id="faq" aria-labelledby="faq-title"><div><h2 id="faq-title">Before you install.</h2><p class="section-description">Compatibility, permissions, and what to expect from the alpha.</p><a class="text-link" href="${repo}#troubleshooting">Read the troubleshooting notes</a></div><div class="faq-list">
    <details><summary>Which Macs does Defi support?</summary><p>Apple Silicon Macs running macOS 26 or newer. This alpha does not support Intel Macs.</p></details>
    <details><summary>Does it control macOS Spaces?</summary><p>No. Defi manages its own virtual workspaces and does not control native macOS Spaces. Your usual window clicks, Dock selection, and Command-Tab still work.</p></details>
    <details><summary>Do I need to configure it first?</summary><p>Defi works with built-in defaults. Add a TOML configuration when you want to change shortcuts, column widths, or application rules. See the <a href="${repo}/blob/main/CONFIGURATION.md">configuration reference</a>.</p></details>
    <details><summary>Which permissions does it need?</summary><p>Accessibility access lets Defi focus and arrange your windows. Screen Recording is optional and only needed for window previews in Overview. Previews are off by default.</p></details>
    <details><summary>Do workspaces survive a restart?</summary><p>Defi preserves each monitor's workspaces and layout across daemon restarts within the same macOS login session. Restoration does not extend across logout or reboot. See <a href="${repo}/blob/main/CONFIGURATION.md#workspaces">workspace configuration</a>.</p></details>
    <details><summary>Is the Homebrew build notarized?</summary><p>The app is self-signed and not notarized. The Homebrew cask removes its quarantine attribute so it can open. The <a href="${repo}#get-started">installation notes</a> explain how the build is distributed.</p></details>
    <details><summary>Is Defi ready for everyday use?</summary><p>Defi is an experimental alpha. Behavior and configuration may change before the first stable release. Apps can impose window-size constraints or expose limited Accessibility support. Read the <a href="${repo}#alpha-limitations">alpha limitations</a> before trying it.</p></details>
    </div></section>
    <section class="setup-section" id="install" aria-labelledby="setup-title"><div><h2 id="setup-title">Try Defi on your Mac.</h2><p class="section-description">Built-in defaults are ready to use.<br>Move between columns with Option and the left or right arrow key.</p><p class="shortcut"><kbd>Option + ← / →</kbd></p><a class="text-link" href="${repo}#get-started">Read the installation notes</a></div><ol class="setup-steps">
    <li><h3><span aria-hidden="true">1</span> Install Defi</h3><p>Paste this command into Terminal.</p>${installControl('setup')}</li>
    <li><h3><span aria-hidden="true">2</span> Open Defi</h3><p>Launch Defi from your Applications folder.</p></li>
    <li><h3><span aria-hidden="true">3</span> Allow Accessibility</h3><p>Grant access in System Settings when prompted. Defi starts arranging your windows automatically.</p></li>
    </ol></section></main>
    <footer class="site-footer"><a class="wordmark" href="#main">${mark}Defi</a><p>Inspired by <a href="https://github.com/YaLTeR/niri">Niri</a>. Built for macOS.</p><a href="${repo}">Explore the project</a></footer>`;
}

landing();
const hero = app.querySelector('.hero');
hero.querySelector('canvas').remove();
hero.querySelectorAll('.first-launch-note, .requirements').forEach(element => element.remove());
const navigation = app.querySelector('.site-nav nav');
navigation.querySelector('a[href="#install"]').remove();
const githubIcon = `<svg class="github-icon" aria-hidden="true" focusable="false" width="18" height="18" viewBox="0 0 16 16" fill="currentColor"><path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82a7.65 7.65 0 0 1 4 0c1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.01 8.01 0 0 0 16 8c0-4.42-3.58-8-8-8Z"/></svg>`;
const navGitHub = navigation.querySelector(`a[href="${repo}"]`);
navGitHub.innerHTML = `${githubIcon}<span>GitHub</span>`;
navGitHub.classList.add('nav-github');
navGitHub.title = 'Defi on GitHub';
hero.querySelector('.hero-github').insertAdjacentHTML('afterbegin', githubIcon);
const sections = [
  ['#overview-title', 'Workspace Overview'],
  ['#setup-title', 'First launch'],
];
for (const [selector, title] of sections) {
  const heading = app.querySelector(selector);
  const lead = document.createElement('p');
  lead.className = 'section-lead';
  lead.textContent = heading.textContent;
  heading.textContent = title;
  heading.after(lead);
}
for (const button of app.querySelectorAll('[data-feature]')) {
  const title = button.querySelector('span');
  const subtitle = button.querySelector('small');
  [title.textContent, subtitle.textContent] = [subtitle.textContent, title.textContent];
}
for (const core of app.querySelectorAll('.recording-frame, .install-command')) {
  const shell = document.createElement('div');
  shell.className = core.matches('.recording-frame') ? 'media-bezel' : 'command-bezel';
  core.before(shell);
  shell.append(core);
}
const panel = app.querySelector('.feature-panel');
const core = document.createElement('div');
core.className = 'panel-core';
core.append(...panel.childNodes);
panel.append(core);
for (const button of app.querySelectorAll('.copy-button')) {
  const glyph = document.createElement('span');
  glyph.className = 'copy-glyph';
  glyph.append(...button.childNodes);
  button.append(glyph);
  button.querySelector('svg').setAttribute('stroke-width', '1.4');
}
const heroCopy = hero.querySelector('.copy-button');
const heroStatus = hero.querySelector('.copy-status');
heroCopy.querySelector('svg').classList.add('copy-symbol');
heroCopy.querySelector('.copy-glyph').insertAdjacentHTML('beforeend', '<svg class="copy-confirmation" aria-hidden="true" focusable="false" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"><path d="m5 12 4 4L19 6"/></svg>');
heroStatus.classList.add('visually-hidden');
const copyFeedback = new MutationObserver(() => {
  const success = heroStatus.textContent.startsWith('Copied.');
  heroCopy.dataset.copied = String(success);
  heroCopy.title = success ? 'Command copied' : 'Copy command';
  heroStatus.classList.toggle('visually-hidden', !heroStatus.textContent || success);
});
copyFeedback.observe(heroStatus, { childList: true, characterData: true, subtree: true });
app.querySelector('.site-footer').append(app.querySelector('.project-proof'));
const reveals = app.querySelectorAll('.product-section, .overview-chapter, .faq-section, .setup-section');
if (!reducedMotion.matches) {
  const observer = new IntersectionObserver(entries => {
    for (const entry of entries) {
      if (!entry.isIntersecting) continue;
      entry.target.classList.add('is-revealed');
      observer.unobserve(entry.target);
    }
  }, { threshold: .08 });
  reveals.forEach(element => {
    element.classList.add('design-reveal');
    observer.observe(element);
  });
  reducedMotion.addEventListener('change', event => {
    if (!event.matches) return;
    reveals.forEach(element => element.classList.add('is-revealed'));
    observer.disconnect();
  });
}
const product = app.querySelector('.product-section');
const theatre = product.querySelector('.feature-theatre');
const guide = document.createElement('div');
guide.className = 'feature-guide';
guide.append(product.querySelector('.section-intro'), theatre.querySelector('.feature-choices'));
const story = document.createElement('div');
story.className = 'feature-story';
story.append(panel, product.querySelector('.monitor-fact'));
theatre.append(guide, story);
product.classList.remove('design-reveal');

const footer = app.querySelector('.site-footer');
footer.querySelector('.wordmark').remove();
const overviewHeading = app.querySelector('#overview-title');
overviewHeading.innerHTML = `Workspace <span class="overview-heading-line"><span class="title-thumbnail" aria-hidden="true"><img src="${media(features.overview.recording.poster)}" width="64" height="40" alt="" loading="lazy"></span>Overview</span>`;
const signature = document.createElement('a');
signature.className = 'footer-signature';
signature.href = '#main';
signature.textContent = 'Defi';
signature.setAttribute('aria-label', 'Defi — back to top');
footer.prepend(signature);
mountHeroField(hero, reducedMotion);

document.querySelector('.skip-link').addEventListener('click', scrollToSection);
app.querySelectorAll('a[href="#main"], a[href="#product"], a[href="#install"]').forEach(link => link.addEventListener('click', scrollToSection));
app.querySelectorAll('[data-feature]').forEach(button => button.addEventListener('click', () => selectFeature(button.dataset.feature)));
app.querySelector('.replay-button').addEventListener('click', replay);
reducedMotion.addEventListener('change', cancelMotion);
app.querySelectorAll('.copy-button').forEach(button => button.addEventListener('click', async () => {
  const status = button.closest('.install-control').querySelector('.copy-status');
  try {
    await navigator.clipboard.writeText(command);
    status.textContent = 'Copied. Paste into Terminal.';
  } catch {
    status.textContent = 'Select the command to copy it manually.';
  }
}));

const videos = [...app.querySelectorAll('video')];
document.addEventListener('play', event => {
  if (!videos.includes(event.target)) return;
  videos.forEach(video => { if (video !== event.target) video.pause(); });
  const frame = event.target.getBoundingClientRect();
  if (document.hidden || frame.bottom <= 0 || frame.top >= innerHeight) event.target.pause();
}, true);
document.addEventListener('visibilitychange', () => {
  if (document.hidden) videos.forEach(video => video.pause());
});
const observer = new IntersectionObserver(entries => {
  entries.forEach(({ target, isIntersecting }) => { if (!isIntersecting) target.pause(); });
});
videos.forEach(video => {
  observer.observe(video);
  const showError = () => {
    video.pause();
    video.hidden = true;
    const figure = video.closest('figure');
    figure.querySelector('.error-poster').hidden = false;
    figure.querySelector('.video-error').hidden = false;
  };
  video.addEventListener('error', showError);
  video.querySelector('source').addEventListener('error', showError);
});
