// The hero recording starts as the framed card and opens to the full viewport width as it reaches the top.
export function mountHeroGrow(hero, reducedMotion) {
  const visual = hero.querySelector('.hero-visual');
  const video = visual.querySelector('video');

  // No player chrome: the clip is part of the page. The card rests on the first frame (a crowded desktop); the moment the page starts opening it, the clip plays, so Defi is tidying the windows as the frame reaches full width. Reduced motion never autoplays, so it gets native controls instead.
  video.controls = reducedMotion.matches;
  video.muted = true;
  video.loop = true;
  video.preload = 'auto';

  function sync(progress, rect) {
    const onScreen = !document.hidden && rect.bottom > 0 && rect.top < innerHeight;
    if (!onScreen) {
      if (!video.paused) video.pause();
      return;
    }
    if (reducedMotion.matches) return; // The native controls own playback.
    if (progress < .05) {
      if (!video.paused) video.pause();
      if (video.currentTime > .05) video.currentTime = 0;
    } else if (progress >= .1 && video.paused && !('userPaused' in video.dataset)) {
      video.play().catch(() => {});
    }
  }

  let frame = 0;
  function grow() {
    cancelAnimationFrame(frame);
    frame = 0;
    // Read layout before any write so the frame never forces a synchronous reflow.
    const rect = visual.getBoundingClientRect();
    if (reducedMotion.matches) {
      ['--grow', '--bezel', '--bezel-radius', '--frame-radius'].forEach(name => visual.style.removeProperty(name));
      return sync(0, rect);
    }
    // The 8px bezel is painted outside the scaled frame, so the card keeps its 1040px outer width at rest.
    const rest = (Math.min(1040, innerWidth - 32) - 16) / innerWidth;
    // Layout top is unaffected by the scale (origin at top), so this is stable while growing.
    const top = rect.top + scrollY;
    const end = Math.min(innerHeight * .12, 120);
    const progress = Math.min(1, Math.max(0, scrollY / Math.max(1, top - end)));
    const eased = 1 - (1 - progress) ** 3;
    const scale = rest + (1 - rest) * eased;
    visual.style.setProperty('--grow', scale.toFixed(4));
    // Bezel and radii shrink with the card so the frame has no edge left at full width.
    const open = (1 - eased) / scale;
    visual.style.setProperty('--bezel', `${(8 * open).toFixed(2)}px`);
    visual.style.setProperty('--bezel-radius', `${(32 * open).toFixed(2)}px`);
    visual.style.setProperty('--frame-radius', `${(24 * open).toFixed(2)}px`);
    sync(progress, rect);
  }
  // Scroll can fire several times per frame; render once per display refresh.
  const schedule = () => { frame ||= requestAnimationFrame(grow); };

  addEventListener('scroll', schedule, { passive: true });
  addEventListener('resize', schedule);
  reducedMotion.addEventListener('change', () => {
    video.controls = reducedMotion.matches;
    if (reducedMotion.matches) video.pause();
    grow();
  });
  document.addEventListener('visibilitychange', grow);
  grow();
}
