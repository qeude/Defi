const vertexSource = 'attribute vec2 position;varying vec2 uv;void main(){uv=position*.5+.5;gl_Position=vec4(position,0.,1.);}';
const fragmentSource = `precision highp float;
varying vec2 uv;
uniform sampler2D artwork;
uniform vec4 touches[6];
uniform float energy[6];
uniform float aspect;
uniform vec3 profileShape;
void main(){
  vec2 displacement=vec2(0.);
  for(int i=0;i<6;i++){
    vec2 delta=(uv-touches[i].xy)*vec2(aspect,1.);
    float influence=exp(-dot(delta,delta)/profileShape.x)*energy[i];
    displacement+=touches[i].zw*influence;
    displacement+=delta/vec2(aspect,1.)*influence*profileShape.y;
    displacement+=vec2(-delta.y,delta.x)/vec2(aspect,1.)*influence*profileShape.z;
  }
  gl_FragColor=texture2D(artwork,clamp(uv-displacement,vec2(0.),vec2(1.)));
}`;

const profiles = {
  original: { radius: .16, radial: .5, twist: 0, drag: 2.4, strength: .8, decay: .045, count: 6, held: false },
  velours: { radius: .19, radial: .18, twist: 0, drag: .8, strength: .45, decay: .04, count: 6, held: false, inertia: true },
  lentille: { radius: .15, radial: -.16, twist: 0, drag: 0, strength: .6, decay: .1, count: 1, held: true },
  sillage: { radius: .13, radial: .015, twist: .065, drag: 1.3, strength: .55, decay: .095, count: 4, held: false },
};

export function createLightSurface(image, schedule, profileName = 'velours') {
  const profile = Object.hasOwn(profiles, profileName) ? profiles[profileName] : profiles.velours;
  const heldStrength = Math.fround(profile.strength);
  const canvas = document.createElement('canvas');
  canvas.className = 'edge-artwork edge-surface';
  canvas.setAttribute('aria-hidden', 'true');
  canvas.width = 1536;
  canvas.height = 1024;
  const gl = canvas.getContext('webgl', { alpha: false, antialias: false, powerPreference: 'low-power' });
  if (!gl) return null;

  let program;
  let buffer;
  let texture;
  let ready = false;
  let lost = false;
  let dirty = true;
  let previousTime = 0;
  let previousPointer = null;
  let held = false;
  let slot = 0;
  let lastImpulse = -Infinity;
  const touches = new Float32Array(24);
  const centers = new Float32Array(12);
  const centerVelocity = new Float32Array(12);
  const dragTargets = new Float32Array(12);
  const energyTargets = new Float32Array(6);
  const energy = new Float32Array(6);
  const shaders = [];
  let uniforms;

  function fallback() {
    ready = false;
    image.style.display = '';
    canvas.remove();
    for (const shader of shaders) gl.deleteShader(shader);
    if (program) gl.deleteProgram(program);
    if (buffer) gl.deleteBuffer(buffer);
    if (texture) gl.deleteTexture(texture);
  }

  function compile(kind, source) {
    const shader = gl.createShader(kind);
    shaders.push(shader);
    gl.shaderSource(shader, source);
    gl.compileShader(shader);
    if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) throw new Error('Light surface shader unavailable');
    return shader;
  }

  image.decode().then(() => {
    if (lost) return;
    try {
      program = gl.createProgram();
      gl.attachShader(program, compile(gl.VERTEX_SHADER, vertexSource));
      gl.attachShader(program, compile(gl.FRAGMENT_SHADER, fragmentSource));
      gl.linkProgram(program);
      if (!gl.getProgramParameter(program, gl.LINK_STATUS)) throw new Error('Light surface program unavailable');
      gl.useProgram(program);
      buffer = gl.createBuffer();
      gl.bindBuffer(gl.ARRAY_BUFFER, buffer);
      gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1,-1,1,-1,-1,1,-1,1,1,-1,1,1]), gl.STATIC_DRAW);
      const position = gl.getAttribLocation(program, 'position');
      gl.enableVertexAttribArray(position);
      gl.vertexAttribPointer(position, 2, gl.FLOAT, false, 0, 0);
      texture = gl.createTexture();
      gl.bindTexture(gl.TEXTURE_2D, texture);
      gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL, true);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
      const softened = document.createElement('canvas');
      softened.width = image.naturalWidth;
      softened.height = image.naturalHeight;
      const context = softened.getContext('2d');
      if (!context) throw new Error('Light texture preparation unavailable');
      const blur = 6 * image.naturalWidth / Math.max(1, image.getBoundingClientRect().width);
      context.filter = `grayscale(80%) brightness(75%) blur(${Math.min(18, blur)}px)`;
      context.drawImage(image, 0, 0);
      gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, softened);
      uniforms = Object.fromEntries(['artwork', 'touches[0]', 'energy[0]', 'aspect', 'profileShape'].map(name => [name, gl.getUniformLocation(program, name)]));
      gl.uniform1i(uniforms.artwork, 0);
      gl.uniform1f(uniforms.aspect, 1.5);
      gl.uniform3f(uniforms.profileShape, profile.radius ** 2, profile.radial, profile.twist);
      gl.viewport(0, 0, canvas.width, canvas.height);
      image.before(canvas);
      ready = true;
      paint(0);
      image.style.display = 'none';
      schedule();
    } catch { fallback(); }
  }).catch(fallback);

  function move(clientX, clientY, time) {
    if (!ready) return;
    const rect = canvas.getBoundingClientRect();
    const next = [(clientX - rect.left) / rect.width, 1 - (clientY - rect.top) / rect.height];
    const dx = previousPointer ? (next[0] - previousPointer[0]) * rect.width : 0;
    const dy = previousPointer ? (next[1] - previousPointer[1]) * rect.height : 0;
    if (profile.inertia && previousPointer && time - lastImpulse < 45) return;
    if (previousPointer && Math.hypot(dx, dy) < 4 && time - lastImpulse < 80) return;
    slot = (slot + 1) % profile.count;
    const limit = profileName === 'sillage' ? 24 : 48;
    centers.set(next, slot * 2);
    if (profile.inertia) {
      if (energy[slot] === 0 && energyTargets[slot] === 0) {
        touches.set(previousPointer || next, slot * 4);
        centerVelocity.fill(0, slot * 2, slot * 2 + 2);
      }
      dragTargets.set([Math.max(-limit, Math.min(limit, dx)) / rect.width * profile.drag, Math.max(-limit, Math.min(limit, dy)) / rect.height * profile.drag], slot * 2);
      energyTargets[slot] = profile.strength;
    } else if (profile.held && previousPointer) {
      held = true;
    } else {
      touches.set([next[0], next[1], Math.max(-limit, Math.min(limit, dx)) / rect.width * profile.drag, Math.max(-limit, Math.min(limit, dy)) / rect.height * profile.drag], slot * 4);
      if (!profile.held) energy[slot] = profile.strength;
      held = profile.held;
    }
    previousPointer = next;
    lastImpulse = time;
    dirty = true;
  }

  function reset() {
    previousPointer = null;
    held = false;
    dirty = true;
  }

  function settle() {
    energy.fill(0);
    energyTargets.fill(0);
    centerVelocity.fill(0);
    dragTargets.fill(0);
    previousTime = 0;
    reset();
    dirty = true;
    paint(0);
  }

  function paint(time) {
    if (!ready || !dirty) return false;
    const step = previousTime ? Math.min(2, Math.max(.25, (time - previousTime) / (1000 / 60))) : 1;
    previousTime = time;
    let moving = false;
    for (let i = 0; i < energy.length; i++) {
      if (profile.inertia) {
        energyTargets[i] *= Math.exp(-profile.decay * step);
        energy[i] += (energyTargets[i] - energy[i]) * (1 - Math.exp(-.16 * step));
        if (energyTargets[i] < .002 && energy[i] < .003) {
          energy[i] = energyTargets[i] = 0;
          centerVelocity.fill(0, i * 2, i * 2 + 2);
        } else {
          for (let axis = 0; axis < 2; axis++) {
            const index = i * 4 + axis;
            const motion = i * 2 + axis;
            centerVelocity[motion] = (centerVelocity[motion] + (centers[motion] - touches[index]) * .035 * step) * Math.exp(-.32 * step);
            touches[index] += centerVelocity[motion] * step;
            touches[index + 2] += (dragTargets[motion] - touches[index + 2]) * (1 - Math.exp(-.16 * step));
            dragTargets[motion] *= Math.exp(-.055 * step);
          }
          moving = true;
        }
      } else if (profile.held && i === 0 && held) {
        energy[i] += (heldStrength - energy[i]) * (1 - Math.exp(-.14 * step));
        if (Math.abs(heldStrength - energy[i]) < .004) energy[i] = heldStrength;
        moving ||= energy[i] !== heldStrength;
        for (let axis = 0; axis < 2; axis++) {
          const index = i * 4 + axis;
          touches[index] += (centers[i * 2 + axis] - touches[index]) * (1 - Math.exp(-.24 * step));
          if (Math.abs(centers[i * 2 + axis] - touches[index]) < .00005) touches[index] = centers[i * 2 + axis];
          moving ||= touches[index] !== centers[i * 2 + axis];
        }
      } else {
        energy[i] *= Math.exp(-profile.decay * step);
        if (energy[i] < .004) energy[i] = 0;
        moving ||= energy[i] > 0;
      }
    }
    gl.uniform4fv(uniforms['touches[0]'], touches);
    gl.uniform1fv(uniforms['energy[0]'], energy);
    gl.drawArrays(gl.TRIANGLES, 0, 6);
    dirty = moving;
    if (!moving) previousTime = 0;
    return moving;
  }

  canvas.addEventListener('webglcontextlost', event => {
    event.preventDefault();
    lost = true;
    fallback();
  });
  return { move, reset, settle, paint };
}
