"use strict";

/* The hero: a pair of forged tongs holding a red-hot key, shaded live from 2D distance fields.
   Steel near the key takes real temper colours (straw, bronze, violet, blue), the same ones the
   page uses as its palette. The pointer moves the light. */
(function forge() {
  const canvas = document.getElementById("forge");
  if (!canvas) return;
  const gl = canvas.getContext("webgl", { antialias: false, alpha: false, powerPreference: "low-power" });
  if (!gl) { canvas.remove(); return; }

  const fragment = `
    precision highp float;
    uniform vec2 res;
    uniform vec2 center;
    uniform vec2 light;
    uniform float scale;
    uniform float time;

    const float ANGLE = 0.46;
    const vec3 GROUND = vec3(0.0030, 0.0033, 0.0040);

    float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
    float noise(vec2 p) {
      vec2 i = floor(p), f = fract(p);
      f = f * f * (3.0 - 2.0 * f);
      return mix(mix(hash(i), hash(i + vec2(1, 0)), f.x),
                 mix(hash(i + vec2(0, 1)), hash(i + vec2(1, 1)), f.x), f.y);
    }
    float fbm(vec2 p) {
      return noise(p) * 0.55 + noise(p * 2.13 + 7.0) * 0.3 + noise(p * 4.31 + 13.0) * 0.15;
    }
    float smin(float a, float b, float k) {
      float h = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
      return mix(b, a, h) - k * h * (1.0 - h);
    }
    float seg(vec2 p, vec2 a, vec2 b, float ra, float rb) {
      vec2 pa = p - a, ba = b - a;
      float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
      return length(pa - ba * h) - mix(ra, rb, h);
    }
    float box(vec2 p, vec2 c, vec2 half_) {
      vec2 q = abs(p - c) - half_;
      return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0);
    }

    // One arm: a curved jaw above the axis, crossing at the pivot to a long rein below it.
    float arm(vec2 p) {
      float d = seg(p, vec2(-1.20, 0.335), vec2(-0.98, 0.450), 0.048, 0.072);
      d = smin(d, seg(p, vec2(-0.98, 0.450), vec2(-0.66, 0.470), 0.072, 0.090), 0.025);
      d = smin(d, seg(p, vec2(-0.66, 0.470), vec2(-0.30, 0.280), 0.090, 0.105), 0.025);
      d = smin(d, seg(p, vec2(-0.30, 0.280), vec2(0.00, 0.000), 0.105, 0.135), 0.025);
      d = smin(d, seg(p, vec2(0.00, 0.000), vec2(0.42, -0.185), 0.135, 0.095), 0.02);
      d = smin(d, seg(p, vec2(0.42, -0.185), vec2(1.30, -0.400), 0.095, 0.078), 0.012);
      d = smin(d, seg(p, vec2(1.30, -0.400), vec2(3.40, -0.640), 0.078, 0.066), 0.012);
      d = smin(d, seg(p, vec2(3.40, -0.640), vec2(9.00, -0.900), 0.066, 0.060), 0.012);
      return smin(d, length(p) - 0.215, 0.05);
    }

    // The key: bow, collar, shaft, and bit cut along its underside.
    float key(vec2 p) {
      vec2 c = vec2(-1.20, 0.0);
      float ring = abs(length(p - c) - 0.270) - 0.100;
      float shaft = box(p, vec2(-1.98, 0.0), vec2(0.52, 0.066)) - 0.012;
      float collar = box(p, vec2(-1.56, 0.0), vec2(0.040, 0.112)) - 0.012;
      float bit = box(p, vec2(-2.27, -0.175), vec2(0.215, 0.135)) - 0.010;
      bit = max(bit, -box(p, vec2(-2.38, -0.285), vec2(0.040, 0.085)));
      bit = max(bit, -box(p, vec2(-2.17, -0.310), vec2(0.040, 0.060)));
      bit = max(bit, -box(p, vec2(-2.27, -0.130), vec2(0.022, 0.032)));
      return min(min(min(ring, shaft), collar), bit);
    }

    float armA(vec2 p) { return arm(p); }
    float armB(vec2 p) { return arm(vec2(p.x, -p.y)); }
    float pin(vec2 p) { return length(p) - 0.078; }

    // Oxide colours of heated steel. t is 0 far from the heat and 1 at the jaw tip.
    vec3 temper(float t) {
      vec3 c = vec3(0.52, 0.55, 0.60);
      c = mix(c, vec3(0.09, 0.22, 0.62), smoothstep(0.12, 0.26, t));
      c = mix(c, vec3(0.30, 0.10, 0.48), smoothstep(0.26, 0.40, t));
      c = mix(c, vec3(0.56, 0.24, 0.07), smoothstep(0.40, 0.54, t));
      c = mix(c, vec3(0.92, 0.62, 0.22), smoothstep(0.54, 0.70, t));
      return c;
    }

    float softbox(vec3 r) {
      // A long strip light overhead and a dim fill from the far side.
      float strip = exp(-pow((r.y - 0.34 + r.x * 0.32) / 0.20, 2.0));
      float fill = exp(-pow((r.x + 0.55) / 0.34, 2.0)) * 0.22;
      return strip + fill;
    }

    vec3 shadeSteel(vec2 p, float d, vec2 g, vec2 dir, float heat, vec3 lightPos, float shade) {
      float x = clamp(-d / 0.042, 0.0, 1.0);
      float slope = (1.0 - x) / max(sqrt(max(1.0 - (1.0 - x) * (1.0 - x), 0.0)), 0.16);
      vec3 n = normalize(vec3(g * slope, 1.0));

      // Forging marks at a large scale, drawn-out grain at a fine one.
      vec2 across = vec2(-dir.y, dir.x);
      vec2 u = vec2(dot(p, dir), dot(p, across));
      float h0 = fbm(u * vec2(2.2, 6.0));
      float h1 = fbm(u * vec2(2.2, 6.0) + vec2(0.03, 0.0));
      float h2 = fbm(u * vec2(2.2, 6.0) + vec2(0.0, 0.03));
      n.xy += (dir * (h1 - h0) + across * (h2 - h0)) * 1.5;
      float grain = noise(vec2(u.x * 5.0, u.y * 190.0));
      n.xy += across * (grain - 0.5) * 0.09;
      n = normalize(n);

      vec3 pos = vec3(p, 0.0);
      vec3 toLight = lightPos - pos;
      float dist2 = dot(toLight, toLight);
      vec3 L = toLight / sqrt(dist2);
      vec3 V = vec3(0.0, 0.0, 1.0);
      vec3 H = normalize(L + V);
      float att = 7.0 / (dist2 + 2.5);

      float TH = dot(vec3(dir, 0.0), H);
      float aniso = pow(max(1.0 - TH * TH, 0.0), 180.0) * max(dot(n, L), 0.0);
      float spec = pow(max(dot(n, H), 0.0), 60.0);
      float diff = max(dot(n, L), 0.0);

      vec3 R = reflect(-V, n);
      float env = softbox(R);
      float scaleMark = smoothstep(0.34, 0.62, fbm(u * vec2(3.0, 11.0) + 21.0));
      vec3 tint = temper(heat);
      vec3 color = tint * (0.018 + env * (0.20 + 0.55 * slope) * mix(0.55, 1.0, scaleMark));
      color += tint * att * (diff * 0.055 + aniso * 0.75 + spec * 0.34);
      return color * shade;
    }

    vec3 tonemap(vec3 x) {
      return clamp((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14), 0.0, 1.0);
    }

    #define GRAD(F, q) normalize(vec2(F(q + e.xy) - F(q - e.xy), F(q + e.yx) - F(q - e.yx)) + 1e-5)

    void main() {
      float ca = cos(ANGLE), sa = sin(ANGLE);
      mat2 toLocal = mat2(ca, -sa, sa, ca);
      vec2 p = toLocal * ((gl_FragCoord.xy - center) / scale);
      vec3 lightPos = vec3(toLocal * ((light - center) / scale), 2.4);
      float px = 1.0 / scale;
      vec2 e = vec2(0.004, 0.0);

      vec3 color = GROUND;
      vec3 toLight = lightPos - vec3(p, 0.0);
      vec2 sh = toLight.xy / max(toLight.z, 0.5) * 0.055;
      float pool = 1.0 / (dot(toLight, toLight) * 0.55 + 1.0);

      // The floor: a faint grain that only shows where light reaches it.
      // Everything added to the floor dies out before the canvas ends, so there is no seam with the page.
      float settle = smoothstep(0.0, 0.16, gl_FragCoord.y / res.y);
      float floorGrain = noise(vec2(gl_FragCoord.x * 0.012, gl_FragCoord.y * 0.75));
      color += vec3(0.019, 0.020, 0.023) * pool * pool * (0.75 + 0.5 * floorGrain) * settle;

      float flick = 0.93 + 0.07 * sin(time * 1.3) * sin(time * 0.71 + 1.7);
      float kd = key(p);
      float kdist = max(kd, 0.0);
      float glow = exp(-kdist * 2.9) * 0.075 + exp(-kdist * 13.0) * 0.16;
      bool inside = p.x > -3.2 && abs(p.y) < 1.3;
      if (!inside) {
        color += vec3(1.0, 0.16, 0.02) * glow * flick * settle;
      } else {
        float a = armA(p), b = armB(p), pd = pin(p);

        // Glow on the floor, shadows, then each layer from the bottom up.
        float shadowD = min(armA(p + sh), armB(p + sh));
        float contact = smoothstep(-0.02, 0.17, min(a, b));
        color *= mix(0.25, 1.0, smoothstep(-0.03, 0.10, shadowD));
        color += vec3(1.0, 0.16, 0.02) * glow * flick * contact * settle;

        float aa = px * 1.2;
        if (kd < aa) {
          float cover = smoothstep(aa, -aa, kd);
          vec2 g = GRAD(key, p);
          float x = clamp(-kd / 0.05, 0.0, 1.0);
          float t = 0.50 + 0.50 * fbm(p * 1.7 + vec2(time * 0.035, -time * 0.02));
          float crust = smoothstep(0.50, 0.72, fbm(p * vec2(7.0, 9.0) + vec2(time * 0.015, 3.0)));
          t *= mix(1.0, 0.72, crust);
          t *= 0.46 + 0.54 * x;
          t *= flick;
          vec3 hotColor = mix(vec3(0.20, 0.006, 0.0), vec3(0.95, 0.085, 0.006), smoothstep(0.16, 0.55, t));
          hotColor = mix(hotColor, vec3(2.1, 0.52, 0.06), smoothstep(0.55, 0.95, t));
          // The upper bevel catches a little less heat, so the outline stays readable.
          hotColor *= 0.72 + 0.28 * dot(g, normalize(vec2(-0.3, -1.0))) * (1.0 - x) + 0.28 * x;
          color = mix(color, hotColor, cover);
        }

        float heatB = exp(-max(length(vec2(p.x + 1.22, -p.y - 0.34)) - 0.02, 0.0) * 1.72);
        if (b < aa) {
          float cover = smoothstep(aa, -aa, b);
          vec2 g = GRAD(armB, p);
          vec2 dir = normalize(vec2(1.0, p.x < 0.0 ? 0.42 : 0.16));
          float shade = mix(0.32, 1.0, smoothstep(-0.03, 0.05, armA(p + sh * 0.5)));
          vec3 c = shadeSteel(p, b, g, dir, heatB, lightPos, shade);
          c += vec3(1.0, 0.22, 0.035) * exp(-kdist * 5.0) * 0.20 * flick;
          color = mix(color, c, cover);
        }
        float heatA = exp(-max(length(vec2(p.x + 1.22, p.y - 0.34)) - 0.02, 0.0) * 1.72);
        if (a < aa) {
          float cover = smoothstep(aa, -aa, a);
          vec2 g = GRAD(armA, p);
          vec2 dir = normalize(vec2(1.0, p.x < 0.0 ? -0.42 : -0.16));
          float shade = mix(0.45, 1.0, smoothstep(-0.02, 0.05, pd));
          vec3 c = shadeSteel(p, a, g, dir, heatA, lightPos, shade);
          c += vec3(1.0, 0.22, 0.035) * exp(-kdist * 5.0) * 0.20 * flick;
          color = mix(color, c, cover);
        }
        if (pd < aa) {
          float cover = smoothstep(aa, -aa, pd);
          float x = clamp(-pd / 0.078, 0.0, 1.0);
          vec3 n = normalize(vec3(normalize(p + 1e-5) * (1.0 - x) * 1.3, 1.0));
          vec3 L = normalize(toLight);
          vec3 H = normalize(L + vec3(0.0, 0.0, 1.0));
          float env = softbox(reflect(vec3(0.0, 0.0, -1.0), n));
          vec3 c = vec3(0.52, 0.55, 0.60) * (0.02 + env * 0.55 + pow(max(dot(n, H), 0.0), 40.0) * 0.5);
          color = mix(color, c, cover);
        }
      }

      color = pow(tonemap(color * 1.5), vec3(1.0 / 2.2));
      color += (hash(gl_FragCoord.xy + fract(time)) - 0.5) / 255.0;
      gl_FragColor = vec4(color, 1.0);
    }`;

  function compile(type, source) {
    const shader = gl.createShader(type);
    gl.shaderSource(shader, source);
    gl.compileShader(shader);
    if (gl.getShaderParameter(shader, gl.COMPILE_STATUS)) return shader;
    console.warn(gl.getShaderInfoLog(shader));
    return null;
  }
  const vs = compile(gl.VERTEX_SHADER, "attribute vec2 a; void main(){ gl_Position = vec4(a, 0.0, 1.0); }");
  const fs = compile(gl.FRAGMENT_SHADER, fragment);
  if (!vs || !fs) { canvas.remove(); return; }
  const program = gl.createProgram();
  gl.attachShader(program, vs);
  gl.attachShader(program, fs);
  gl.linkProgram(program);
  if (!gl.getProgramParameter(program, gl.LINK_STATUS)) { canvas.remove(); return; }
  gl.useProgram(program);
  gl.bindBuffer(gl.ARRAY_BUFFER, gl.createBuffer());
  gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 3, -1, -1, 3]), gl.STATIC_DRAW);
  const position = gl.getAttribLocation(program, "a");
  gl.enableVertexAttribArray(position);
  gl.vertexAttribPointer(position, 2, gl.FLOAT, false, 0, 0);
  const u = {};
  for (const name of ["res", "center", "light", "scale", "time"]) u[name] = gl.getUniformLocation(program, name);

  const still = matchMedia("(prefers-reduced-motion: reduce)").matches;
  let ratio = Math.min(devicePixelRatio || 1, 1.5);
  const place = { x: 0, y: 0, scale: 100 };
  // Light in CSS pixels from the canvas's bottom left, eased toward the pointer.
  const lamp = { x: 0, y: 0 }, target = { x: 0, y: 0 };
  let visible = true, frame = 0, lastDraw = 0, slowFrames = 0, interval = 33;

  function layout() {
    const box = canvas.getBoundingClientRect();
    const width = Math.max(1, Math.round(box.width * ratio)), height = Math.max(1, Math.round(box.height * ratio));
    if (canvas.width !== width || canvas.height !== height) {
      canvas.width = width;
      canvas.height = height;
      gl.viewport(0, 0, width, height);
    }
    if (box.width >= 900) {
      place.scale = Math.min(Math.max(box.width / 9.4, 108), 172);
      place.x = box.width * 0.80;
      place.y = box.height * 0.585;
    } else {
      place.scale = Math.min(box.width / 4.6, 104);
      place.x = box.width * 0.70;
      place.y = box.height - place.scale * 1.45;
    }
    if (!lamp.x && !lamp.y) {
      lamp.x = target.x = place.x - place.scale * 0.8;
      lamp.y = target.y = place.y + place.scale * 1.7;
    }
  }
  function draw(now) {
    gl.uniform2f(u.res, canvas.width, canvas.height);
    gl.uniform2f(u.center, place.x * ratio, place.y * ratio);
    gl.uniform2f(u.light, lamp.x * ratio, lamp.y * ratio);
    gl.uniform1f(u.scale, place.scale * ratio);
    gl.uniform1f(u.time, now / 1000);
    gl.drawArrays(gl.TRIANGLES, 0, 3);
  }
  function tick(now) {
    frame = 0;
    if (!visible || document.hidden) return;
    frame = requestAnimationFrame(tick);
    const moving = Math.abs(target.x - lamp.x) + Math.abs(target.y - lamp.y) > 0.5;
    if (!moving && now - lastDraw < interval) return;
    // A machine that can't keep up gets fewer pixels, then a slower flicker.
    if (lastDraw && now - lastDraw > interval + 34) slowFrames++;
    if (slowFrames > 20) {
      slowFrames = 0;
      if (ratio > 0.75) { ratio = Math.max(0.75, ratio * 0.75); layout(); }
      else interval = 100;
    }
    lastDraw = now;
    lamp.x += (target.x - lamp.x) * 0.09;
    lamp.y += (target.y - lamp.y) * 0.09;
    draw(now);
  }
  function wake() { if (!frame && !still) frame = requestAnimationFrame(tick); }

  new ResizeObserver(() => { layout(); draw(performance.now()); }).observe(canvas);
  layout();
  draw(performance.now());
  if (still) return;

  new IntersectionObserver(([entry]) => {
    visible = entry.isIntersecting;
    if (visible) wake();
  }).observe(canvas);
  document.addEventListener("visibilitychange", wake);
  window.addEventListener("pointermove", (event) => {
    if (event.pointerType === "touch") return;
    const box = canvas.getBoundingClientRect();
    target.x = event.clientX - box.left;
    target.y = box.bottom - event.clientY;
  }, { passive: true });
  wake();
})();
