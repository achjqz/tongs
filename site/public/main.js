"use strict";

const isZh = () => document.documentElement.lang.startsWith("zh");

/* Language toggle */
document.getElementById("lang-toggle").addEventListener("click", () => {
  const next = isZh() ? "en" : "zh-CN";
  document.documentElement.lang = next;
  try { localStorage.setItem("tongs-lang", next); } catch (e) {}
  renderScrub();
  restartDemo();
});
let restartDemo = () => {};

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

/* Demo: a scripted session using the CLI's real output strings. */
(function demo() {
  const $ = (id) => document.getElementById(id);
  const term = $("demo-term"), panel = $("demo-panel"), touch = $("demo-touch");
  const field = { placeholder: $("demo-placeholder"), dots: $("demo-dots"), summary: $("demo-summary"), save: $("demo-save") };
  const print = $("demo-print"), chapters = $("chapters"), caption = $("demo-caption"), pauseButton = $("demo-pause");
  const still = matchMedia("(prefers-reduced-motion: reduce)").matches;
  const tr = (en, zh) => (isZh() ? zh : en);

  const line = (cls, text, gap) => ({ k: "line", cls, text, gap });
  const scenes = () => [
    {
      label: tr("Request", "请求"),
      caption: tr("The agent runs tongs request. You paste the key into the panel. The agent gets back only the name, length and kind of key.",
                  "agent 运行 tongs request，你在面板里粘贴 key。agent 只会拿到名字、长度和 key 的类型。"),
      steps: [
        line("user", tr("› deploy the payment link script", "› 部署支付链接脚本")),
        { k: "wait", ms: 500 },
        line("say", tr("The deploy script needs a Stripe key, and this project doesn't have one yet.", "部署脚本需要 Stripe key，这个项目里还没有。"), true),
        { k: "wait", ms: 500 },
        { k: "cmd", text: `tongs request STRIPE_SECRET_KEY --why "${tr("Deploy script creates a Stripe payment link", "部署脚本要创建 Stripe 支付链接")}"`, gap: true },
        { k: "panel" },
        { k: "wait", ms: 1100 },
        { k: "paste" },
        { k: "wait", ms: 1300 },
        { k: "save" },
        line("out", `stored shop/STRIPE_SECRET_KEY (${tr("project", "项目")} shop, 107 chars, looks like a Stripe live secret key). Use it with: tongs run STRIPE_SECRET_KEY -- <command>`),
        { k: "wait", ms: 1000 },
      ],
    },
    {
      label: tr("Approve", "批准"),
      caption: tr("The first time this agent uses this key in this project, macOS asks for Touch ID. The approval lasts 12 hours.",
                  "这个 agent 第一次在这个项目里用这个 key 时，macOS 会要求 Touch ID。批准有效 12 小时。"),
      steps: [
        { k: "cmd", text: "tongs run STRIPE_SECRET_KEY -- npm run deploy", gap: true },
        line("out", "tongs: waiting for Touch ID: Claude Code in shop wants shop/STRIPE_SECRET_KEY for `npm run deploy` (approval lasts 12h)"),
        { k: "wait", ms: 400 },
        { k: "touch" },
        { k: "wait", ms: 1500 },
        { k: "touch-ok" },
        { k: "wait", ms: 550 },
        { k: "touch-close" },
        { k: "wait", ms: 300 },
      ],
    },
    {
      label: tr("Run", "运行"),
      caption: tr("The command printed the key. tongs replaces it before the output reaches the agent, so the agent reads only the marker.",
                  "命令把 key 打印了出来。tongs 在输出到达 agent 之前把它替换掉，agent 读到的只有标记。"),
      steps: [
        line("out-strong", "POST https://api.stripe.com/v1/payment_links"),
        { k: "wait", ms: 500 },
        { k: "leak", before: "Authorization: Bearer ", value: "sk_live_EXAMPLE…", mask: "‹redacted:STRIPE_SECRET_KEY›" },
        { k: "wait", ms: 700 },
        line("out-strong", "200 OK  plink_EXAMPLE"),
        { k: "wait", ms: 1300 },
      ],
    },
    {
      label: tr("Block", "拦截"),
      caption: tr("If the agent tries to read the Keychain itself, the hook blocks the call and points it back to tongs.",
                  "如果 agent 想自己去读钥匙串，hook 会拦下这次调用，并让它改用 tongs。"),
      steps: [
        { k: "cmd", text: "security find-generic-password -s dev.tongs.secrets -a shop/STRIPE_SECRET_KEY -w", gap: true },
        { k: "wait", ms: 350 },
        line("guard", "tongs guard: this call reads the macOS Keychain directly. Secrets are stored in tongs: use `tongs run NAME -- <command>` to use one, `tongs request NAME` to add or replace one, `tongs ls` to see what exists."),
        { k: "wait", ms: 4500 },
      ],
    },
  ];

  const STOP = Symbol("stop");
  let script = [], current = 0, runId = 0, paused = false, offscreen = false, wake = null;

  async function pause(ms, id) {
    await new Promise((done) => setTimeout(done, ms));
    while ((paused || offscreen) && id === runId) await new Promise((done) => { wake = done; });
    if (id !== runId) throw STOP;
  }
  const scrollDown = () => { term.scrollTop = term.scrollHeight; };

  function reset() {
    term.textContent = "";
    panel.hidden = touch.hidden = true;
    panel.classList.remove("leaving");
    touch.classList.remove("leaving");
    print.classList.remove("ok");
    field.placeholder.hidden = false;
    field.dots.hidden = field.summary.hidden = true;
    field.save.classList.remove("ready", "pressed");
  }
  async function closeSheet(sheet, instant, id) {
    if (!instant) {
      sheet.classList.add("leaving");
      await pause(160, id);
      sheet.classList.remove("leaving");
    }
    sheet.hidden = true;
  }

  async function exec(step, instant, id) {
    switch (step.k) {
      case "wait":
        if (!instant) await pause(step.ms, id);
        break;
      case "line": {
        const row = document.createElement("div");
        row.className = step.cls + (step.gap ? " gap" : "");
        row.textContent = step.text;
        term.append(row);
        scrollDown();
        break;
      }
      case "cmd": {
        const row = document.createElement("div");
        if (step.gap) row.className = "gap";
        const prompt = document.createElement("span");
        prompt.className = "dim";
        prompt.textContent = "$ ";
        const typed = document.createElement("span");
        row.append(prompt, typed);
        term.append(row);
        if (instant) { typed.textContent = step.text; scrollDown(); break; }
        const caret = document.createElement("span");
        caret.className = "caret";
        row.append(caret);
        const chars = [...step.text];
        for (let i = 0; i < chars.length; i++) {
          typed.textContent += chars[i];
          scrollDown();
          await pause(chars.length > 60 ? 14 : 26, id);
        }
        await pause(320, id);
        caret.remove();
        break;
      }
      case "panel":
        panel.hidden = false;
        break;
      case "paste":
        field.placeholder.hidden = true;
        field.dots.hidden = field.summary.hidden = false;
        field.save.classList.add("ready");
        break;
      case "save":
        if (!instant) {
          field.save.classList.add("pressed");
          await pause(170, id);
        }
        await closeSheet(panel, instant, id);
        break;
      case "touch":
        touch.hidden = false;
        break;
      case "touch-ok":
        print.classList.add("ok");
        break;
      case "touch-close":
        await closeSheet(touch, instant, id);
        break;
      case "leak": {
        const row = document.createElement("div");
        row.className = "out-strong";
        row.append(step.before);
        const value = document.createElement("span");
        term.append(row);
        row.append(value);
        scrollDown();
        if (!instant) {
          value.className = "hot";
          value.textContent = step.value;
          await pause(1200, id);
        }
        value.className = instant ? "mask" : "mask mask-in";
        value.textContent = step.mask;
        scrollDown();
        break;
      }
    }
  }

  function show(index) {
    current = index;
    [...chapters.children].forEach((button, i) => {
      if (i === index) button.setAttribute("aria-current", "step");
      else button.removeAttribute("aria-current");
    });
    caption.textContent = script[index].caption;
  }

  // Replays everything before the chosen chapter instantly, then runs from there.
  async function playFrom(index) {
    const id = ++runId;
    if (wake) { const done = wake; wake = null; done(); }
    reset();
    for (let i = 0; i < index; i++) for (const step of script[i].steps) await exec(step, true, id);
    show(index);
    if (still) {
      for (const step of script[index].steps) await exec(step, true, id);
      closeOpenSheets();
      return;
    }
    try {
      for (let i = index; ; i = (i + 1) % script.length) {
        if (i === 0 && i !== index) reset();
        show(i);
        for (const step of script[i].steps) await exec(step, false, id);
        if (i === script.length - 1) index = -1;
      }
    } catch (e) {
      if (e !== STOP) throw e;
    }
  }
  function closeOpenSheets() { panel.hidden = touch.hidden = true; }

  function build() {
    script = scenes();
    chapters.textContent = "";
    script.forEach((scene, i) => {
      const button = document.createElement("button");
      button.type = "button";
      button.textContent = scene.label;
      button.addEventListener("click", () => { setPaused(false); playFrom(i); });
      chapters.append(button);
    });
    renderPause();
  }
  function renderPause() {
    pauseButton.hidden = still;
    pauseButton.textContent = paused ? tr("Play", "播放") : tr("Pause", "暂停");
  }
  function setPaused(value) {
    paused = value;
    renderPause();
    if (!paused && !offscreen && wake) { const done = wake; wake = null; done(); }
  }
  pauseButton.addEventListener("click", () => setPaused(!paused));

  new IntersectionObserver(([entry]) => {
    offscreen = !entry.isIntersecting;
    if (!paused && !offscreen && wake) { const done = wake; wake = null; done(); }
  }).observe($("stage"));

  restartDemo = () => { build(); playFrom(current); };
  build();
  playFrom(0);
})();

/* The plate under the demo: brushed metal that follows the system theme, lit by the pointer. */
(function plate() {
  const canvas = document.getElementById("steel");
  const gl = canvas.getContext("webgl", { antialias: false, alpha: false, powerPreference: "low-power" });
  if (!gl) { canvas.remove(); return; }

  const fragment = `
    precision highp float;
    uniform vec2 res;
    uniform vec2 light;
    uniform float tone;

    float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
    float noise(vec2 p) {
      vec2 i = floor(p), f = fract(p);
      f = f * f * (3.0 - 2.0 * f);
      return mix(mix(hash(i), hash(i + vec2(1, 0)), f.x),
                 mix(hash(i + vec2(0, 1)), hash(i + vec2(1, 1)), f.x), f.y);
    }
    void main() {
      vec2 uv = gl_FragCoord.xy / res;
      float px = gl_FragCoord.y;
      // Long brushing marks along x, a few pixels tall whatever the plate's size.
      float grain = noise(vec2(uv.x * 26.0, px * 1.15)) * 0.45
                  + noise(vec2(uv.x * 70.0 + 3.0, px * 2.1)) * 0.35
                  + noise(vec2(uv.x * 10.0, px * 0.42)) * 0.2;

      vec3 base = mix(vec3(0.082, 0.094, 0.114), vec3(0.760, 0.772, 0.790), tone);
      float contrast = mix(0.34, 0.11, tone);
      vec3 color = base * (1.0 - contrast * 0.5 + grain * contrast);

      // Brushed metal reflects light as a soft vertical band that breaks up along the grain.
      float x = uv.x - light.x;
      float band = exp(-x * x * 7.0) * (0.65 + 0.35 * (1.0 - abs(uv.y - light.y)));
      color += mix(vec3(0.075, 0.082, 0.095), vec3(0.150, 0.150, 0.150), tone) * band * (0.35 + pow(grain, 3.0) * 1.1);
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
  const uRes = gl.getUniformLocation(program, "res");
  const uLight = gl.getUniformLocation(program, "light");
  const uTone = gl.getUniformLocation(program, "tone");

  const dark = matchMedia("(prefers-color-scheme: dark)");
  const still = matchMedia("(prefers-reduced-motion: reduce)").matches;
  const light = { x: 0.3, y: 0.7 }, target = { x: 0.3, y: 0.7 };
  let frame = 0;

  function draw() {
    gl.uniform2f(uRes, canvas.width, canvas.height);
    gl.uniform2f(uLight, light.x, light.y);
    gl.uniform1f(uTone, dark.matches ? 0 : 1);
    gl.drawArrays(gl.TRIANGLES, 0, 3);
  }
  function tick() {
    frame = 0;
    light.x += (target.x - light.x) * 0.07;
    light.y += (target.y - light.y) * 0.07;
    draw();
    if (Math.abs(target.x - light.x) + Math.abs(target.y - light.y) > 0.002) frame = requestAnimationFrame(tick);
  }
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
  dark.addEventListener("change", draw);
  if (!still) {
    canvas.parentElement.addEventListener("pointermove", (event) => {
      if (event.pointerType === "touch") return;
      const box = canvas.getBoundingClientRect();
      target.x = (event.clientX - box.left) / box.width;
      target.y = 1 - (event.clientY - box.top) / box.height;
      if (!frame) frame = requestAnimationFrame(tick);
    });
  }
})();

