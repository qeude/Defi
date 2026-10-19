import './style.css';
import './direction.css';
import { mountHeroField } from './hero-field.js';
import { mountHeroGrow } from './hero-grow.js';
const heroHorizon = `<div class="edge-world">
  <div class="edge-aura"></div>
  <img class="edge-artwork" src="${import.meta.env.BASE_URL}media/horizon-artwork.webp" width="1536" height="1024" alt="" decoding="async" fetchpriority="high">
  <div class="edge-reflection"></div>
</div>`;



const app = document.querySelector('#app');
const media = filename => `${import.meta.env.BASE_URL}media/${filename}`;
const repo = 'https://github.com/qeude/Defi';
const command = 'brew install --cask qeude/tap/defi';
const heroRecording = { poster: 'feature-hero.jpg', clip: 'feature-hero.mp4', clipHd: 'feature-hero-hd.mp4', description: 'Defi tidying a crowded desktop, then moving between window columns with a keypress' };
const features = {
  overview: {
    title: 'Find any window at a glance.',
    recording: { poster: 'feature-overview.jpg', clip: 'feature-overview.mp4', description: 'Defi Overview browsing workspace rows and their windows' },
  },
  widths: {
    title: 'Room for the window you’re using.',
    recording: { poster: 'feature-widths.jpg', clip: 'feature-widths.mp4', description: 'Defi widening a column while its neighbors reflow' },
  },
  workspaces: {
    title: 'As many workspaces as you want.',
    recording: { poster: 'feature-workspaces.jpg', clip: 'feature-workspaces.mp4', description: 'Defi switching between workspaces: a GitHub page, a T3 chat and a terminal row' },
  },
};
const reducedMotion = matchMedia('(prefers-reduced-motion: reduce)');
const mark = `<img class="brand-icon" src="${media('defi-icon.png')}" alt="" width="32" height="32">`;

function recording({ poster, clip, description }, { autoplay = false, frame = 'recording-frame' } = {}) {
  return `<figure class="recording"><div class="${frame}"><video muted loop playsinline preload="none"${autoplay ? ' data-autoplay' : ''} poster="${media(poster)}" aria-label="${description}" width="1920" height="1080"><source src="${media(clip)}" type="video/mp4"><a href="${media(clip)}">Open the recording</a></video><img class="error-poster" src="${media(poster)}" alt="${description}" width="1920" height="1080" hidden></div><p class="video-error" role="status" hidden>Recording unavailable. <a href="${media(clip)}">Open the clip directly</a> or <a href="${repo}#readme">view the project README</a>.</p></figure>`;
}

const videos = new Set();
const onScreen = new Set();
// Feature clips play only while visible in a visible tab; without autoplay (reduced motion), a clip started with the native controls is only paused once it leaves the view.
function syncPlayback(video) {
  if (!onScreen.has(video) || document.hidden) video.pause();
  else if ('autoplay' in video.dataset && !('userPaused' in video.dataset) && !reducedMotion.matches) video.play().catch(() => {});
}
const visibility = new IntersectionObserver(entries => {
  entries.forEach(({ target, isIntersecting }) => {
    if (isIntersecting) onScreen.add(target);
    else onScreen.delete(target);
    syncPlayback(target);
  });
});

function wireVideo(video) {
  videos.add(video);
  video.controls = reducedMotion.matches;
  visibility.observe(video);
  // A click or tap pauses or resumes the clip; a pause sticks until the next click. Native controls (reduced motion) handle their own clicks.
  video.addEventListener('click', () => {
    if (video.controls) return;
    if (video.paused) {
      delete video.dataset.userPaused;
      video.play().catch(() => {});
    } else {
      video.dataset.userPaused = '';
      video.pause();
    }
  });
  const showError = () => {
    video.pause();
    video.hidden = true;
    const figure = video.closest('figure');
    figure.querySelector('.error-poster').hidden = false;
    figure.querySelector('.video-error').hidden = false;
  };
  video.addEventListener('error', showError);
  video.querySelector('source').addEventListener('error', showError);
}

function installControl(id) {
  return `<div class="install-control"><div class="install-command"><code>${command.replace(/^brew/, '<span class="cmd-bin">brew</span>')}</code><button type="button" class="copy-button" aria-label="Copy Homebrew command" aria-describedby="${id}-status" title="Copy command"><svg aria-hidden="true" focusable="false" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><rect x="9" y="9" width="11" height="11" rx="2"/><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/></svg></button></div><p id="${id}-status" class="copy-status" role="status"></p></div>`;
}

function keys(shortcut) {
  return shortcut.split(' + ').map(key => `<kbd>${key}</kbd>`).join('');
}

function featureRow(feature) {
  return `<article class="feature-row"><h2 class="feature-title">${feature.title}</h2><div class="feature-visual">${recording(feature.recording, { autoplay: true, frame: 'panel-frame' })}</div></article>`;
}

const shortcuts = [
  ['Move between columns', 'Option + ← / →'],
  ['Switch workspace', 'Option + ↑ / ↓'],
  ['Open Overview', 'Option + O'],
  ['Change column width', 'Option + − / ='],
];

function scrollToSection(event) {
  const target = document.querySelector(event.currentTarget.getAttribute('href'));
  if (!target) return;
  event.preventDefault();
  target.tabIndex = -1;
  target.scrollIntoView();
  target.focus({ preventScroll: true });
}

function landing() {
  app.innerHTML = `<header class="site-nav"><a class="wordmark" href="#main">${mark}<span>Defi</span></a><nav aria-label="Main navigation"><a href="#product">Features</a><a href="#shortcuts">Shortcuts</a><a href="#faq">FAQ</a><a href="${repo}">GitHub</a></nav></header>
    <main id="main">
    <section class="hero"><div class="hero-atmosphere" aria-hidden="true">${heroHorizon}<canvas hidden></canvas></div><div class="hero-copy"><h1><span class="headline-line">Your desktop,</span><br><span class="headline-line">without the edges.</span></h1><p class="hero-description">A scrolling window manager for macOS. Keep windows side by side and switch tasks with your keyboard.</p>
    <div class="install-row">${installControl('hero')}</div>
    <p class="first-launch-note">Then open Defi from Applications. <a href="#install">First launch steps</a></p>
    <p class="requirements">Free and open source. For Apple Silicon Macs on macOS 26 or later. Experimental alpha.</p></div>
    <div class="hero-visual">${recording(heroRecording)}</div></section>
    <div class="below-hero"><section class="product-section" id="product" aria-label="Features"><div class="feature-rows">${['overview', 'widths', 'workspaces'].map(id => featureRow(features[id])).join('')}</div></section></div>
    <section class="start-section" id="install"><div><h2>First launch</h2><ol class="start-steps"><li>Open Defi from your Applications folder.</li><li>Allow Accessibility when prompted.</li></ol></div><div id="shortcuts"><h2>Shortcuts</h2><dl class="shortcut-list">${shortcuts.map(([name, keyset]) => `<div><dt>${name}</dt><dd>${keys(keyset)}</dd></div>`).join('')}</dl></div></section>
    <section class="faq-section" id="faq" aria-labelledby="faq-title"><div><h2 id="faq-title">Before you install.</h2><p class="section-description">Compatibility, permissions, and what to expect from the alpha.</p><a class="text-link" href="${repo}#troubleshooting">Read the troubleshooting notes</a></div><div class="faq-list">
    <details><summary>Which Macs does Defi support?</summary><p>Apple Silicon Macs running macOS 26 or newer. This alpha does not support Intel Macs.</p></details>
    <details><summary>Does it control macOS Spaces?</summary><p>No. Defi manages its own virtual workspaces and does not control native macOS Spaces. Your usual window clicks, Dock selection, and Command-Tab still work.</p></details>
    <details><summary>Do I need to configure it first?</summary><p>Defi works with built-in defaults. Add a TOML configuration when you want to change shortcuts, column widths, or application rules. See the <a href="${repo}/blob/main/CONFIGURATION.md">configuration reference</a>.</p></details>
    <details><summary>Which permissions does it need?</summary><p>Accessibility access lets Defi focus and arrange your windows. Screen Recording is only needed for window previews in Overview, which are on by default. Set <code>window_previews = false</code> in the <code>[overview]</code> config section to opt out of it.</p></details>
    <details><summary>Do workspaces survive a restart?</summary><p>Defi preserves each monitor's workspaces and layout across daemon restarts within the same macOS login session. Restoration does not extend across logout or reboot. See <a href="${repo}/blob/main/CONFIGURATION.md#workspaces">workspace configuration</a>.</p></details>
    <details><summary>Is the Homebrew build notarized?</summary><p>The app is self-signed and not notarized. The Homebrew cask removes its quarantine attribute so it can open. The <a href="${repo}#get-started">installation notes</a> explain how the build is distributed.</p></details>
    <details><summary>Is Defi ready for everyday use?</summary><p>Defi is an experimental alpha. Behavior and configuration may change before the first stable release. Apps can impose window-size constraints or expose limited Accessibility support. Read the <a href="${repo}#alpha-limitations">alpha limitations</a> before trying it.</p></details>
    <details><summary>Does it support several monitors?</summary><p>Yes. Each monitor keeps its own workspaces, active workspace, and layout. Switching workspaces on one monitor leaves the others as they are.</p></details>
    </div></section>
    <section class="cta-section" aria-labelledby="cta-title"><h2 id="cta-title">Try Defi on your Mac.</h2><div class="cta-actions"><button type="button" class="button-primary" data-copy>Copy the install command</button><a class="button-secondary hero-github" href="${repo}">Star on GitHub</a></div><p class="copy-status cta-status" role="status"></p></section>
</main>
    <footer class="site-footer"><a class="wordmark" href="#main">${mark}Defi</a><p>An experimental alpha, <a href="${repo}/blob/main/LICENSE">MIT licensed</a> and inspired by <a href="https://github.com/YaLTeR/niri">Niri</a>.</p><a href="${repo}">GitHub</a></footer>`;
}
landing();
const hero = app.querySelector('.hero');
// The hero opens to the full viewport width: serve the 2880 px clip wherever the frame is wider than the 1920 px one, unless the browser asks to save data.
if (devicePixelRatio * innerWidth >= 2200 && !navigator.connection?.saveData) {
  const heroVideo = hero.querySelector('video');
  heroVideo.querySelector('source').src = media(heroRecording.clipHd);
  heroVideo.load();
}
hero.querySelector('canvas').remove();
hero.querySelector('.first-launch-note').remove();
const navigation = app.querySelector('.site-nav nav');
const githubIcon = `<svg class="github-icon" aria-hidden="true" focusable="false" width="18" height="18" viewBox="0 0 16 16" fill="currentColor"><path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82a7.65 7.65 0 0 1 4 0c1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.01 8.01 0 0 0 16 8c0-4.42-3.58-8-8-8Z"/></svg>`;
const navGitHub = navigation.querySelector(`a[href="${repo}"]`);
navGitHub.innerHTML = `${githubIcon}<span>GitHub</span>`;
navGitHub.classList.add('nav-github');
navGitHub.title = 'Defi on GitHub';
app.querySelectorAll('.hero-github').forEach(link => link.insertAdjacentHTML('afterbegin', githubIcon));
for (const core of app.querySelectorAll('.recording-frame, .install-command')) {
  const shell = document.createElement('div');
  shell.className = core.matches('.recording-frame') ? 'media-bezel' : 'command-bezel';
  core.before(shell);
  shell.append(core);
}
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
const reveals = app.querySelectorAll('.product-section, .start-section, .faq-section, .cta-section');
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

mountHeroField(hero, reducedMotion);
mountHeroGrow(hero, reducedMotion);

document.querySelector('.skip-link').addEventListener('click', scrollToSection);
app.querySelectorAll('a[href="#main"], a[href="#product"], a[href="#shortcuts"], a[href="#faq"]').forEach(link => link.addEventListener('click', scrollToSection));
app.querySelector('[data-copy]').addEventListener('click', async event => {
  const status = app.querySelector('.cta-status');
  try {
    await navigator.clipboard.writeText(command);
    status.textContent = 'Copied. Paste into Terminal.';
  } catch {
    status.textContent = 'Copy failed. Use the command at the top of the page.';
  }
});
app.querySelectorAll('.copy-button').forEach(button => button.addEventListener('click', async () => {
  const status = button.closest('.install-control').querySelector('.copy-status');
  try {
    await navigator.clipboard.writeText(command);
    status.textContent = 'Copied. Paste into Terminal.';
  } catch {
    status.textContent = 'Select the command to copy it manually.';
  }
}));

document.addEventListener('visibilitychange', () => videos.forEach(syncPlayback));
reducedMotion.addEventListener('change', () => videos.forEach(video => {
  video.controls = reducedMotion.matches;
  delete video.dataset.userPaused;
  if (reducedMotion.matches) video.pause();
  else syncPlayback(video);
}));
app.querySelectorAll('video').forEach(wireVideo);
