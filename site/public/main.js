"use strict";

const isZh = () => document.documentElement.lang.startsWith("zh");

/* Language toggle */
document.getElementById("lang-toggle").addEventListener("click", () => {
  const next = isZh() ? "en" : "zh-CN";
  document.documentElement.lang = next;
  try { localStorage.setItem("tongs-lang", next); } catch (e) {}
  renderScrub();
});

/* Copy buttons */
document.querySelectorAll("[data-copy]").forEach((button) => {
  button.addEventListener("click", async () => {
    const source = document.getElementById(button.dataset.copy);
    const original = button.innerHTML;
    try {
      await navigator.clipboard.writeText(source.textContent);
      button.textContent = isZh() ? "已复制" : "Copied";
    } catch (e) {
      const range = document.createRange();
      range.selectNodeContents(source);
      const selection = getSelection();
      selection.removeAllRanges();
      selection.addRange(range);
      button.textContent = isZh() ? "请按 ⌘C" : "Press ⌘C";
    }
    setTimeout(() => { button.innerHTML = original; }, 1600);
  });
});

/* Scrubber demo: the same rules as Sources/TongsCore/Scrubber.swift. */
const utf8 = (s) => new TextEncoder().encode(s);
const base64 = (bytes) => btoa(String.fromCharCode(...bytes));
const percent = (s) => encodeURIComponent(s).replace(/[!'()*]/g, (c) => "%" + c.charCodeAt(0).toString(16).toUpperCase());

function variants(value) {
  const out = new Set();
  const bytes = utf8(value);
  if (bytes.length >= 4) out.add(value);
  if (bytes.length < 8) return [...out];
  if (percent(value) !== value) out.add(percent(value));
  // Base64 of the value at any offset: for each of the 3 byte alignments,
  // keep only the characters fully determined by the value.
  for (let k = 0; k < 3; k++) {
    const data = new Uint8Array(k + bytes.length);
    data.set(bytes, k);
    const encoded = base64(data);
    const start = Math.floor((4 * k + 2) / 3);
    const end = Math.floor((8 * data.length - 6) / 6);
    if (end - start + 1 < 8) continue;
    const core = encoded.slice(start, end + 1);
    out.add(core);
    out.add(core.replaceAll("+", "-").replaceAll("/", "_"));
  }
  return [...out].sort((a, b) => b.length - a.length);
}

function scrubInto(cell, text, patterns) {
  cell.textContent = "";
  let plain = "";
  const flush = () => { if (plain) { cell.append(plain); plain = ""; } };
  for (let i = 0; i < text.length;) {
    const hit = patterns.find((p) => text.startsWith(p, i));
    if (hit) {
      flush();
      const mark = document.createElement("span");
      mark.className = "mask";
      mark.textContent = "‹redacted:GH_TOKEN›";
      cell.append(mark);
      i += hit.length;
    } else {
      plain += text[i++];
    }
  }
  flush();
  return cell.querySelector(".mask") !== null;
}

const scrubInput = document.getElementById("scrub-value");
const scrubRows = document.getElementById("scrub-rows");

function renderScrub() {
  const value = scrubInput.value;
  const patterns = variants(value);
  const reversed = [...value].reverse().join("");
  const rows = [
    [["echo", "echo"], `token is ${value}`],
    [["curl -v", "curl -v"], `> Authorization: Bearer ${value}`],
    [["Basic auth", "Basic auth"], `> Authorization: Basic ${base64(utf8(`bot:${value}`))}`],
    [["URL", "URL"], `GET /v1/items?token=${percent(value)}`],
    [["Reversed", "倒过来打印"], reversed, true],
  ];
  scrubRows.textContent = "";
  for (const [label, text, escapes] of rows) {
    const row = scrubRows.insertRow();
    const head = document.createElement("th");
    head.scope = "row";
    head.textContent = label[isZh() ? 1 : 0];
    row.append(head);
    const cell = row.insertCell();
    const caught = scrubInto(cell, text, patterns);
    if (escapes && !caught && value) {
      const leak = document.createElement("span");
      leak.className = "hot";
      leak.textContent = text;
      cell.textContent = "";
      cell.append(leak, isZh() ? "  这种抓不到" : "  not caught");
    }
  }
}
scrubInput.addEventListener("input", renderScrub);
renderScrub();

/* Hero: brushed steel with heat tint, lit by the pointer. Draws only when the light moves. */
(function steel() {
  const canvas = document.getElementById("steel");
  const gl = canvas.getContext("webgl", { antialias: false, alpha: false, powerPreference: "low-power" });
  if (!gl) { canvas.remove(); return; }

  const fragment = `
    precision highp float;
    uniform vec2 res;
    uniform vec2 light;

    float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
    float noise(vec2 p) {
      vec2 i = floor(p), f = fract(p);
      f = f * f * (3.0 - 2.0 * f);
      return mix(mix(hash(i), hash(i + vec2(1, 0)), f.x),
                 mix(hash(i + vec2(0, 1)), hash(i + vec2(1, 1)), f.x), f.y);
    }
    float fbm(vec2 p) {
      float v = 0.0, a = 0.5;
      for (int i = 0; i < 5; i++) { v += a * noise(p); p = p * 2.03 + 7.0; a *= 0.5; }
      return v;
    }
    // Oxide colours in the order steel takes them on as it heats.
    vec3 temper(float t) {
      vec3 bare   = vec3(0.078, 0.090, 0.110);
      vec3 straw  = vec3(0.470, 0.385, 0.245);
      vec3 bronze = vec3(0.360, 0.215, 0.125);
      vec3 violet = vec3(0.215, 0.135, 0.320);
      vec3 blue   = vec3(0.100, 0.190, 0.370);
      vec3 oxide  = vec3(0.105, 0.135, 0.180);
      if (t < 0.22) return mix(bare, straw, smoothstep(0.0, 0.22, t));
      if (t < 0.42) return mix(straw, bronze, smoothstep(0.22, 0.42, t));
      if (t < 0.60) return mix(bronze, violet, smoothstep(0.42, 0.60, t));
      if (t < 0.80) return mix(violet, blue, smoothstep(0.60, 0.80, t));
      return mix(blue, oxide, smoothstep(0.80, 1.0, t));
    }
    void main() {
      vec2 uv = gl_FragCoord.xy / res;
      float aspect = res.x / res.y;
      vec2 p = vec2(uv.x * aspect, uv.y);
      float scale = res.y / 700.0;

      // Long brushing marks along x.
      float grain = noise(vec2(p.x * 22.0, uv.y * 1500.0 * scale)) * 0.45
                  + noise(vec2(p.x * 60.0 + 3.0, uv.y * 2600.0 * scale)) * 0.35
                  + noise(vec2(p.x * 9.0, uv.y * 520.0 * scale)) * 0.2;

      // Heat comes in from the lower right; the warp makes the bands flow like real tint.
      vec2 hot = vec2(aspect * 1.10, 0.16 - 0.20 * smoothstep(1.3, 0.7, aspect));
      float warp = fbm(p * 1.7 + 3.0) * 0.40;
      float d = length((p - hot) * vec2(0.86, 1.05)) + warp;
      float t = 1.0 - smoothstep(0.26, 1.14, d);
      t = clamp(t + (grain - 0.5) * 0.02, 0.0, 1.0);

      vec3 metal = temper(t);

      // Brushed steel reflects light as a soft vertical band that breaks up along the grain.
      float x = uv.x - light.x;
      float band = exp(-x * x * 7.0) * (0.6 + 0.4 * (1.0 - abs(uv.y - light.y)));
      float sparkle = pow(grain, 3.0);

      vec3 color = metal * (0.70 + grain * 0.42);
      color += (metal * 0.65 + vec3(0.075, 0.085, 0.100)) * band * (0.26 + sparkle * 1.05);

      // Keep the text side quiet. On a tall screen the text spans the plate, so calm all of it.
      color *= mix(0.62, 1.0, smoothstep(0.08, 0.66, uv.x));
      color *= mix(0.58, 1.0, smoothstep(0.7, 1.3, aspect));
      gl_FragColor = vec4(color, 1.0);
    }`;

  function compile(type, source) {
    const shader = gl.createShader(type);
    gl.shaderSource(shader, source);
    gl.compileShader(shader);
    return gl.getShaderParameter(shader, gl.COMPILE_STATUS) ? shader : null;
  }
  const vs = compile(gl.VERTEX_SHADER, "attribute vec2 a; void main(){ gl_Position = vec4(a, 0.0, 1.0); }");
  const fs = compile(gl.FRAGMENT_SHADER, fragment);
  const program = gl.createProgram();
  if (!vs || !fs) { canvas.remove(); return; }
  gl.attachShader(program, vs);
  gl.attachShader(program, fs);
  gl.linkProgram(program);
  if (!gl.getProgramParameter(program, gl.LINK_STATUS)) { canvas.remove(); return; }
  gl.useProgram(program);
  gl.bindBuffer(gl.ARRAY_BUFFER, gl.createBuffer());
  gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 3, -1, -1, 3]), gl.STATIC_DRAW);
  gl.enableVertexAttribArray(0);
  gl.bindAttribLocation(program, 0, "a");
  gl.vertexAttribPointer(gl.getAttribLocation(program, "a"), 2, gl.FLOAT, false, 0, 0);
  const uRes = gl.getUniformLocation(program, "res");
  const uLight = gl.getUniformLocation(program, "light");

  const still = matchMedia("(prefers-reduced-motion: reduce)").matches;
  const light = { x: still ? 0.68 : -0.25, y: 0.55 };
  const target = { x: 0.68, y: 0.55 };
  let frame = 0;

  function draw() {
    gl.uniform2f(uRes, canvas.width, canvas.height);
    gl.uniform2f(uLight, light.x, light.y);
    gl.drawArrays(gl.TRIANGLES, 0, 3);
  }
  function tick() {
    frame = 0;
    light.x += (target.x - light.x) * 0.055;
    light.y += (target.y - light.y) * 0.055;
    draw();
    if (Math.abs(target.x - light.x) + Math.abs(target.y - light.y) > 0.0015) {
      frame = requestAnimationFrame(tick);
    }
  }
  const wake = () => { if (!frame && !still) frame = requestAnimationFrame(tick); };

  function resize() {
    const box = canvas.getBoundingClientRect();
    const ratio = Math.min(devicePixelRatio || 1, 1.5);
    const width = Math.round(box.width * ratio), height = Math.round(box.height * ratio);
    if (canvas.width === width && canvas.height === height) return;
    canvas.width = width;
    canvas.height = height;
    gl.viewport(0, 0, width, height);
    draw();
  }
  new ResizeObserver(resize).observe(canvas);
  resize();

  // The light sweeps across once on load, then follows the pointer over the plate.
  wake();
  if (!still) {
    canvas.parentElement.addEventListener("pointermove", (event) => {
      if (event.pointerType === "touch") return;
      const box = canvas.getBoundingClientRect();
      target.x = (event.clientX - box.left) / box.width;
      target.y = 1 - (event.clientY - box.top) / box.height;
      wake();
    });
  }
})();
