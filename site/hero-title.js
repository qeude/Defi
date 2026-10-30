// “edges.” comes apart: its letters blur towards the end of the word and shed a little dust, which the pointer pushes aside.
const FADE = [[0, 1, 0], [0.3, 0.97, 0.004], [1, 0.88, 0.014], [2.4, 0.7, 0.036], [3.2, 0.62, 0.06], [8, 0.26, 0.16]]; // blur at a 96 px title, opacity, drift in em
const clamp = (x, low, high) => Math.min(high, Math.max(low, x));
const lerp = (a, b, t) => a + (b - a) * t;

export function mountHeroTitle(hero, reducedMotion) {
  if (reducedMotion.matches) return;
  const h1 = hero.querySelector('h1');
  const word = h1.querySelector('[data-dissolve]');
  word.innerHTML = `<i class="hero-baseline"></i>${[...word.textContent].map(letter => `<span class="hletter">${letter}</span>`).join('')}`;
  const cells = [...word.querySelectorAll('.hletter')].map((el, i) => ({ el, fade: FADE[i], near: 0, x: 0, y: 0, shown: '' }));
  hero.insertAdjacentHTML('afterbegin', '<canvas class="hero-dust" aria-hidden="true"></canvas>');
  const canvas = hero.querySelector('.hero-dust');
  const ctx = canvas.getContext('2d');
  const pointer = { x: 0, y: 0, active: false };
  addEventListener('pointermove', event => {
    if (event.pointerType !== 'touch') Object.assign(pointer, { x: event.clientX, y: event.clientY, active: true });
  }, { passive: true });

  let width, height, source, left, right;
  let dust = [];
  // Points inside the real glyphs, so the dust leaves from the letters where the page drew them.
  const measure = () => {
    const home = hero.getBoundingClientRect();
    width = home.width;
    height = h1.getBoundingClientRect().bottom - home.top + 150;
    const dpr = Math.min(2, devicePixelRatio);
    canvas.width = width * dpr;
    canvas.height = height * dpr;
    canvas.style.height = `${height}px`;
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    // Glyph positions are read without the drift and blur the letters carry.
    const baseline = word.firstElementChild.getBoundingClientRect().bottom - home.top;
    const stencil = document.createElement('canvas');
    stencil.width = width;
    stencil.height = height;
    const paint = stencil.getContext('2d', { willReadFrequently: true });
    const style = getComputedStyle(h1);
    paint.font = `${style.fontWeight} ${style.fontSize} ${style.fontFamily}`;
    cells.forEach(cell => {
      const box = cell.el.getBoundingClientRect();
      const drift = (new DOMMatrix(getComputedStyle(cell.el).transform)).m41;
      cell.x = box.left - drift - home.left + box.width / 2;
      cell.y = box.top - home.top + box.height / 2;
      paint.fillText(cell.el.textContent, box.left - drift - home.left, baseline);
    });
    const data = paint.getImageData(0, 0, stencil.width, stencil.height).data;
    source = [];
    for (let y = 0; y < stencil.height; y += 2) for (let x = 0; x < stencil.width; x += 2) {
      if (data[(y * stencil.width + x) * 4 + 3] > 120) source.push({ x, y });
    }
    left = Math.min(...source.map(point => point.x));
    right = Math.max(...source.map(point => point.x));
    dust = [];
  };

  let start, previous;
  let visible = true;
  let running = false;
  const frame = now => {
    if (!visible || document.hidden || reducedMotion.matches) {
      running = false;
      if (reducedMotion.matches) {
        ctx.clearRect(0, 0, width, height);
        cells.forEach(cell => cell.el.removeAttribute('style'));
      }
      return;
    }
    const dt = Math.min(40, now - previous) / 16.7;
    previous = now;
    const box = hero.getBoundingClientRect();
    const px = pointer.x - box.left;
    const py = pointer.y - box.top;
    const size = parseFloat(getComputedStyle(h1).fontSize);
    // The letters settle into their blur over 3 s; the pointer brings them back into focus.
    cells.forEach((cell, i) => {
      const t = clamp((now - start - i * 90) / 3000, 0, 1);
      const close = pointer.active ? clamp(1 - Math.hypot(px - cell.x, py - cell.y) / (size * 1.5), 0, 1) : 0;
      cell.near = lerp(cell.near, close, 0.1);
      const amount = t * t * (3 - 2 * t) * (1 - cell.near * 0.85);
      const [fullBlur, opacity, drift] = cell.fade;
      const blur = fullBlur * size / 96; // a smaller title needs less blur to stay readable
      const next = `${(blur * amount).toFixed(2)}|${lerp(1, opacity, amount).toFixed(3)}|${(drift * amount).toFixed(4)}`;
      if (next === cell.shown) return;
      cell.shown = next;
      cell.el.style.filter = `blur(${(blur * amount).toFixed(2)}px)`;
      cell.el.style.opacity = lerp(1, opacity, amount).toFixed(3);
      cell.el.style.transform = `translateX(${(drift * amount).toFixed(4)}em)`;
    });
    for (let i = 0; i < 3; i++) {
      const point = source[Math.floor(Math.random() * source.length)];
      // Mostly from the end of the word, where the letters are already going.
      if ((point.x - left) / (right - left) < Math.random() * 1.25) continue;
      dust.push({ x: point.x, y: point.y, vx: 0.25 + Math.random() * 0.7, vy: 0, life: 0, max: 60 + Math.random() * 120, seed: Math.random() * 6.28 });
    }
    ctx.clearRect(0, 0, width, height);
    dust = dust.filter(mote => {
      mote.life += dt;
      if (mote.life > mote.max || mote.x > width) return false;
      if (pointer.active) {
        const dx = mote.x - px;
        const dy = mote.y - py;
        const distance = Math.hypot(dx, dy) || 1;
        const push = clamp(1 - distance / 120, 0, 1) * 0.34;
        mote.vx += (dx / distance) * push * dt;
        mote.vy += (dy / distance) * push * dt;
      }
      mote.vx = lerp(mote.vx, 0.55, 0.02 * dt);
      mote.vy *= Math.pow(0.95, dt);
      mote.x += mote.vx * dt;
      mote.y += (mote.vy + Math.sin(mote.x * 0.012 + mote.seed + now * 0.0006) * 0.24) * dt;
      const t = mote.life / mote.max;
      ctx.fillStyle = `rgba(${lerp(226, 120, t) | 0},${lerp(236, 172, t) | 0},255,${(t < 0.1 ? t / 0.1 : 1 - t) * 0.5})`;
      ctx.fillRect(mote.x, mote.y, 1.1, 1.1);
      return true;
    });
    requestAnimationFrame(frame);
  };
  const resume = () => {
    if (running || !start || !visible || document.hidden || reducedMotion.matches) return;
    running = true;
    previous = performance.now();
    requestAnimationFrame(frame);
  };
  new IntersectionObserver(([entry]) => {
    visible = entry.isIntersecting;
    resume();
  }).observe(h1);
  document.addEventListener('visibilitychange', resume);
  reducedMotion.addEventListener('change', resume);
  let lastWidth = innerWidth;
  addEventListener('resize', () => {
    if (innerWidth === lastWidth || !start) return;
    lastWidth = innerWidth;
    measure();
  });

  // The title's reveal ends at 1.4 s, then the word starts to go.
  document.fonts.load(`500 96px 'Cabinet Grotesk'`).catch(() => {}).then(() => document.fonts.ready).then(() => setTimeout(() => {
    measure();
    start = previous = performance.now();
    resume();
  }, 1400));
}
