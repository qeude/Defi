export function mountOpticalMotion(stage) {
  const { gsap, ScrollTrigger, CustomEase } = window;
  if (!gsap || !ScrollTrigger || !CustomEase) return;
  gsap.registerPlugin(ScrollTrigger, CustomEase);
  CustomEase.create('defiSettle', '.32,.72,0,1');
  const world = stage.querySelector('.edge-world');
  const reflection = stage.querySelector('.edge-reflection');
  const guide = stage.querySelector('.feature-guide');
  const story = stage.querySelector('.feature-story');

  gsap.matchMedia().add('(min-width: 900px) and (min-height: 800px) and (prefers-reduced-motion: no-preference)', () => {
    const atmosphere = gsap.timeline({ scrollTrigger: {
      trigger: stage.querySelector('.hero-visual'),
      start: 'top 65%', end: 'bottom 10%', scrub: 1.4,
    } });
    atmosphere.fromTo(world, { y: 0, scale: 1.015 }, {
      y: -150, scale: 1.11, ease: 'defiSettle',
    }).fromTo(reflection, { y: 80, scale: .9, opacity: .35 }, {
      y: 0, scale: 1.15, opacity: .85, ease: 'defiSettle',
    }, 0);

    ScrollTrigger.create({
      trigger: guide, start: 'top 120px',
      end: () => `+=${Math.max(0, story.offsetHeight - guide.offsetHeight)}`,
      pin: guide, pinSpacing: false, anticipatePin: 1,
      invalidateOnRefresh: true,
    });
    const observer = new ResizeObserver(() => ScrollTrigger.refresh(true));
    observer.observe(stage);
    return () => observer.disconnect();
  });
  document.fonts.ready.then(() => ScrollTrigger.refresh(true));
}
