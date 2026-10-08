const $ = id => document.getElementById(id);
const reduce = matchMedia("(prefers-reduced-motion: reduce)").matches;

// Scroll: soft wheel/trackpad lerp (Lenis-like), plus ease-out for hash links.
// No scroll-snap. Off when prefers-reduced-motion. Snappy lerp so trackpads don't feel rubbery.
const PAD = 72;
let scrollAnim = 0, hashing = false;
let y = scrollY, target = scrollY, wheelRaf = 0, dragging = false, lastWheel = 0;

function maxY() {
  return Math.max(0, document.documentElement.scrollHeight - innerHeight);
}
function clampY(v) { return Math.max(0, Math.min(v, maxY())); }
function easeOutQuint(t) { return 1 - (1 - t) ** 5; }

function syncFromWindow() {
  y = target = scrollY;
}

function wheelTick() {
  wheelRaf = 0;
  if (dragging || hashing) return;
  // ~0.16 ≈ elegant without lagging behind a fast trackpad
  y += (target - y) * 0.16;
  if (Math.abs(target - y) < 0.35) y = target;
  scrollTo(0, y);
  if (y !== target) {
    wheelRaf = requestAnimationFrame(wheelTick);
  }
}

function nudgeWheel(dy) {
  if (reduce) return;
  target = clampY(target + dy);
  if (!wheelRaf) wheelRaf = requestAnimationFrame(wheelTick);
}

if (!reduce) {
  addEventListener("wheel", e => {
    if (e.ctrlKey) return; // pinch-zoom
    // Nested scrollables (code blocks, etc.): let them handle overflow
    let node = e.target;
    while (node && node !== document.body) {
      if (node instanceof HTMLElement) {
        const oy = getComputedStyle(node).overflowY;
        if ((oy === "auto" || oy === "scroll") && node.scrollHeight > node.clientHeight + 1) {
          const atTop = node.scrollTop <= 0 && e.deltaY < 0;
          const atBot = node.scrollTop + node.clientHeight >= node.scrollHeight - 1 && e.deltaY > 0;
          if (!atTop && !atBot) return;
        }
      }
      node = node.parentElement;
    }
    e.preventDefault();
    // Cancel in-flight hash tween; continue from where we are
    scrollAnim++;
    hashing = false;
    y = scrollY;
    // Line-mode mice: scale up. Pixel trackpads: use delta as-is (OS already inertias).
    const scale = e.deltaMode === 1 ? 16 : e.deltaMode === 2 ? innerHeight : 1;
    let dy = e.deltaY * scale;
    // Soft-clamp huge spikes (some mice) without killing trackpad flicks
    const now = performance.now();
    const dt = Math.max(8, now - lastWheel);
    lastWheel = now;
    const cap = 2.8 * dt; // px per ms budget
    if (Math.abs(dy) > cap) dy = Math.sign(dy) * cap;
    nudgeWheel(dy);
  }, { passive: false });

  // Scrollbar / touch / keyboard: adopt the new position (don't fight)
  addEventListener("scroll", () => {
    if (wheelRaf || hashing) return;
    syncFromWindow();
  }, { passive: true });
  addEventListener("mousedown", e => {
    if (e.target === document.documentElement || e.offsetX >= document.documentElement.clientWidth) dragging = true;
  });
  addEventListener("mouseup", () => { if (dragging) { dragging = false; syncFromWindow(); } });
  addEventListener("keydown", e => {
    const keys = ["ArrowUp", "ArrowDown", "PageUp", "PageDown", "Home", "End", " ", "Spacebar"];
    if (keys.includes(e.key)) {
      scrollAnim++;
      hashing = false;
      cancelAnimationFrame(wheelRaf);
      wheelRaf = 0;
      requestAnimationFrame(syncFromWindow);
    }
  });
}

function scrollToY(to, ms) {
  to = clampY(to);
  const start = scrollY, dist = to - start;
  if (Math.abs(dist) < 2 || reduce) {
    scrollTo(0, to);
    syncFromWindow();
    return;
  }
  cancelAnimationFrame(wheelRaf);
  wheelRaf = 0;
  hashing = true;
  const dur = ms ?? Math.min(720, Math.max(280, Math.abs(dist) * 0.42));
  const t0 = performance.now();
  const id = ++scrollAnim;
  (function frame(now) {
    if (id !== scrollAnim) return;
    const k = easeOutQuint(Math.min(1, (now - t0) / dur));
    const pos = start + dist * k;
    scrollTo(0, pos);
    y = target = pos;
    if (k < 1) requestAnimationFrame(frame);
    else hashing = false;
  })(t0);
}
function scrollToHash(hash, push) {
  if (!hash || hash === "#") return scrollToY(0);
  const el = document.querySelector(hash);
  if (!el) return;
  const dest = Math.max(0, el.getBoundingClientRect().top + scrollY - PAD);
  scrollToY(dest);
  if (push !== false) history.pushState(null, "", hash);
}
document.addEventListener("click", e => {
  const a = e.target.closest('a[href^="#"]');
  if (!a || a.getAttribute("href") === "#") return;
  const href = a.getAttribute("href");
  if (!href || href.length < 2) return;
  if (e.metaKey || e.ctrlKey || e.shiftKey || e.altKey || a.target === "_blank") return;
  e.preventDefault();
  scrollToHash(href);
});
addEventListener("popstate", () => {
  if (location.hash) scrollToHash(location.hash, false);
});
if (location.hash) {
  requestAnimationFrame(() => scrollToHash(location.hash, false));
}


const seen = new IntersectionObserver(es => es.forEach(e => {
  if (!e.isIntersecting) return;
  e.target.classList.add("in");
  seen.unobserve(e.target);
  if (!reduce) e.target.querySelectorAll("[data-n]").forEach(count);
}), { threshold: .15 });
document.querySelectorAll(".rv").forEach(el => seen.observe(el));
function count(el) {
  const n = +el.dataset.n, pre = el.dataset.pre || "", t0 = performance.now();
  (function tick(t) {
    const k = Math.min(1, (t - t0) / 900);
    el.textContent = pre + Math.round(n * (1 - (1 - k) ** 3));
    if (k < 1) requestAnimationFrame(tick);
  })(t0);
}

document.querySelectorAll(".card").forEach(c => c.addEventListener("pointermove", e => {
  const r = c.getBoundingClientRect();
  c.style.setProperty("--x", e.clientX - r.left + "px");
  c.style.setProperty("--y", e.clientY - r.top + "px");
}));

$("track").innerHTML += $("track").innerHTML;

const tabs = [...document.querySelectorAll("[role=tab]")];
function pick(tab) {
  for (const t of tab.parentNode.children) {
    const on = t === tab;
    t.setAttribute("aria-selected", on);
    t.tabIndex = on ? 0 : -1;
    $(t.getAttribute("aria-controls")).hidden = !on;
  }
}
tabs.forEach(t => {
  t.addEventListener("click", () => pick(t));
  t.addEventListener("keydown", e => {
    const d = { ArrowRight: 1, ArrowLeft: -1 }[e.key];
    if (!d) return;
    const row = [...t.parentNode.children], next = row[(row.indexOf(t) + d + row.length) % row.length];
    pick(next);
    next.focus();
  });
});

$("copy").addEventListener("click", async () => {
  await navigator.clipboard.writeText("curl -fsSL https://gwen-chi.vercel.app/install.sh | sh");
  $("copy").textContent = "Copied";
  setTimeout(() => $("copy").textContent = "Copy", 1500);
});

const desk = $("desk"), bar = $("bar");
const TINT = { talk: "var(--cherry)", reply: "var(--cherry)", clean: "var(--cherry)", dictate: "var(--cherry)", translate: "var(--cherry)" };
function say(mode, text = "", chip = "") {
  bar.dataset.mode = mode;
  bar.style.setProperty("--tint", TINT[mode] || "");
  bar.classList.remove("off");
  $("say").textContent = text;
  $("chip").textContent = chip;
  level();
}
const waves = [...bar.querySelectorAll(".wave i")];
let levels = [];
function level(v) {
  levels = v == null ? [] : [...levels, v].slice(-5);
  bar.classList.toggle("live", v != null);
  waves.forEach((w, i) => w.style.transform = v == null ? "" : `scaleY(${levels[levels.length - 5 + i] ?? .25})`);
}
// a phone's bar holds fewer words; cut from the left so the newest stay in view
const tail = (t, max = innerWidth < 600 ? 24 : 60) => t.length > max ? "…" + t.slice(-max).replace(/^\S* /, "") : t;
async function type(s, el, text, ms = 34) {
  const heard = el === $("say");
  for (let i = 1; i <= text.length; i++) {
    const c = text[i - 1], n = c.charCodeAt();
    if (heard) level(/[aeiou]/i.test(c) ? .7 + n % 4 / 10 : /\w/.test(c) ? .4 + n % 3 / 10 : .2);
    el.textContent = heard ? tail(text.slice(0, i)) : text.slice(0, i);
    await s(ms);
  }
  if (heard) for (let i = 0; i < 5; i++) level(.25);
}
function held(keys = "", how = "") { $("held").innerHTML = [...keys].map(k => `<kbd>${k}</kbd>`).join("") + how; }
function peek(who, line) {
  $("peek").classList.toggle("up", !!who);
  if (!who) return;
  const b = bar.getBoundingClientRect(), d = desk.getBoundingClientRect();
  $("peek").style.left = b.right - d.left - 60 + "px";
  $("line").style.right = d.right - b.right + 66 + "px";
  $("line").textContent = line;
}
function page(text, title = "Notes") {
  $("win").classList.add("on");
  $("win").querySelector("span").textContent = title;
  $("doc").innerHTML = text;
}
function reset() {
  for (const id of ["win", "peek"]) $(id).classList.remove("on", "up");
  bar.classList.add("off");
  $("mb").textContent = "Ready";
  held();
}

const SCENES = [
  { name: "Dictate", async play(s) {
    page("");
    await s(700);
    held("⌃", "hold and talk");
    say("dictate");
    await type(s, $("say"), "The login fix is ready for review. I'll pick up the flaky test after lunch.");
    held();
    say("clean");
    await s(900);
    bar.classList.add("off");
    await s(350);
    page("The login fix is ready for review. I'll pick up the flaky test after lunch.");
  } },
  { name: "Translate", async play(s) {
    page("Standup: <mark>the deploy is ready for review.</mark>");
    await s(1300);
    held("⌃⇧", "tap");
    say("translate", "Translating…", "Español");
    peek("gwen", "One moment.");
    await s(1900);
    held();
    peek();
    page("Standup: <mark>el despliegue está listo para revisión.</mark>");
    bar.classList.add("off");
  } },
  { name: "Hey Gwen", async play(s) {
    page("");
    await s(600);
    say("dictate");
    await type(s, $("say"), "Hey Gwen type a short note for later");
    say("clean");
    await s(1000);
    peek("gwen", "Got it.");
    page("Type a short note for later.");
    await s(1600);
    peek();
    bar.classList.add("off");
  } },
  { name: "Hands-free", async play(s) {
    page("");
    await s(500);
    held("⌃⌃", "tap twice");
    await s(800);
    held();
    say("dictate");
    await type(s, $("say"), "Ship the release notes and ping design.");
    say("clean");
    await s(900);
    bar.classList.add("off");
    page("Ship the release notes and ping design.");
  } },
];

const STOP = Symbol();
let run = 0, now = -1, idle = true, inView = false;
$("scenes").innerHTML = SCENES.map((d, i) => `<button data-i="${i}" aria-pressed="false"><i class="swatch" style="--c:var(--cherry)"></i>${d.name}</button>`).join("");
const picks = [...$("scenes").children];
async function show(i) {
  const me = ++run;
  const s = ms => new Promise((ok, no) => setTimeout(() => me === run ? ok() : no(STOP), reduce ? 0 : ms));
  now = i;
  idle = false;
  picks.forEach((b, j) => b.setAttribute("aria-pressed", j === i));
  reset();
  try {
    await s(500);
    await SCENES[i].play(s);
    await s(3000);
  } catch (e) {
    if (e === STOP) return;
    throw e;
  }
  idle = true;
  if (inView && !reduce) show((i + 1) % SCENES.length);
}
picks.forEach((b, i) => b.addEventListener("click", () => show(i)));
new IntersectionObserver(es => {
  inView = es[0].isIntersecting;
  if (inView && idle && !(reduce && now >= 0)) show((now + 1) % SCENES.length);
}, { threshold: .4 }).observe(desk);
