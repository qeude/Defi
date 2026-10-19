import { mountOpticalMotion } from './optical-motion.js';
import { createLightSurface } from './light-surface.js';

export function mountHeroField(hero, reducedMotion) {
  const stage = document.createElement('div');
  stage.className = 'experience-stage';
  hero.before(stage);
  const field = hero.querySelector('.hero-atmosphere');
  stage.append(field, hero, document.querySelector('.below-hero'));
  const finePointer = matchMedia('(min-width: 768px) and (pointer: fine)');
  const profile = new URL(location.href).searchParams.get('light') || 'velours';
  let surface; // undefined until the first attempt; null when WebGL is unavailable
  let frame = 0;
  let visible = true;

  function enabled() {
    return finePointer.matches && !reducedMotion.matches;
  }
  function paint(time) {
    frame = 0;
    if (surface?.paint(time) && enabled()) schedule();
  }
  function schedule() {
    if (!frame && visible && !document.hidden) frame = requestAnimationFrame(paint);
  }
  function reset() {
    if (enabled()) {
      if (surface === undefined) surface = createLightSurface(field.querySelector('img'), schedule, profile);
      surface?.reset();
    } else surface?.settle();
    schedule();
  }
  function suspend() {
    cancelAnimationFrame(frame);
    frame = 0;
    surface?.settle();
  }
  stage.addEventListener('pointermove', event => {
    if (!enabled()) return;
    surface?.move(event.clientX, event.clientY, event.timeStamp);
    schedule();
  }, { passive: true });
  stage.addEventListener('pointerleave', reset);
  reducedMotion.addEventListener('change', reset);
  finePointer.addEventListener('change', reset);
  document.addEventListener('visibilitychange', () => {
    if (document.hidden) suspend();
    else schedule();
  });
  new IntersectionObserver(([entry]) => {
    visible = entry.isIntersecting;
    if (visible) schedule();
    else suspend();
  }).observe(stage);
  reset();
  mountOpticalMotion(stage);
}
