"use strict";
const $ = id => document.getElementById(id);
let contacts = [], selected = new Set(), current = null, poll = null;

async function api(path, body) {
  const opt = body === undefined ? {} : {
    method: "POST", headers: {"X-Requested-With": "ICE", "Content-Type": "application/json"},
    body: JSON.stringify(body)};
  const r = await fetch(path, opt);
  if (!r.ok) {
    let e = {error: "HTTP " + r.status, kind: "error"};
    try { e = await r.json(); } catch (_) {}
    throw Object.assign(new Error(e.error), {kind: e.kind, status: r.status});
  }
  return r;
}
const json = async (p, b) => (await api(p, b)).json();
const el = (tag, props = {}, ...kids) => {
  const e = Object.assign(document.createElement(tag), props);
  kids.forEach(k => e.append(k)); return e;
};

$("password").addEventListener("input", () => {
  const v = $("password").value.trim();
  $("pwWarn").hidden = !v || /^[a-z]{4}-[a-z]{4}-[a-z]{4}-[a-z]{4}$/i.test(v);
});

$("loginForm").addEventListener("submit", async ev => {
  ev.preventDefault();
  $("loginErr").hidden = true; $("loginBtn").disabled = true; $("loginBtn").textContent = "Verbinde …";
  try {
    const r = await json("/api/login", {appleId: $("appleId").value, password: $("password").value});
    $("password").value = "";
    start(r);
  } catch (e) {
    $("loginErr").textContent = e.message; $("loginErr").hidden = false;
  } finally { $("loginBtn").disabled = false; $("loginBtn").textContent = "Verbinden"; }
});

function start(r) {
  $("login").hidden = true; $("app").hidden = false; $("logout").hidden = false;
  $("who").textContent = r.user;
  const sel = $("book"); sel.replaceChildren();
  r.books.forEach(b => sel.append(el("option", {value: b.url, textContent: b.name})));
  loadBook();
}

function loggedOut(msg) {
  $("app").hidden = true; $("login").hidden = false; $("logout").hidden = true; $("who").textContent = "";
  contacts = []; selected.clear(); current = null; clearInterval(poll);
  if (msg) { $("loginErr").textContent = msg; $("loginErr").hidden = false; }
}

$("logout").onclick = async () => { try { await api("/api/logout", {}); } catch (_) {} loggedOut(); };
$("reload").onclick = () => loadBook();
$("book").onchange = () => loadBook();

async function loadBook() {
  $("loadErr").hidden = true; selected.clear(); contacts = []; render(); showDetail(null);
  try { await api("/api/load", {book: $("book").value}); } catch (e) { return fail(e); }
  clearInterval(poll);
  poll = setInterval(async () => {
    try {
      const s = await json("/api/state");
      const j = s.job;
      if (j.state === "loading") $("status").textContent = `Lade … ${j.done}/${j.total}`;
      else {
        clearInterval(poll);
        if (j.state === "error") { $("status").textContent = ""; $("loadErr").textContent = j.error; $("loadErr").hidden = false; }
        else { contacts = await json("/api/contacts"); $("status").textContent = `${contacts.length} Kontakte geladen`; render(); }
      }
    } catch (e) { clearInterval(poll); fail(e); }
  }, 500);
}

function fail(e) {
  if (e.kind === "session") return loggedOut("Sitzung abgelaufen – bitte erneut anmelden.");
  $("loadErr").textContent = e.message; $("loadErr").hidden = false;
}

const key = c => ({name: (c.family || c.fn), given: (c.given || c.fn), org: (c.org || "￿")})[$("sort").value].toLowerCase();
function visible() {
  const q = $("search").value.trim().toLowerCase();
  const list = contacts.filter(c => !q || [c.fn, c.org, c.phone, c.email].some(v => (v || "").toLowerCase().includes(q)));
  return list.sort((a, b) => key(a).localeCompare(key(b), "de"));
}

function render() {
  const list = visible(), ul = $("items"); ul.replaceChildren();
  list.slice(0, 1000).forEach(c => {
    const cb = el("input", {type: "checkbox", checked: selected.has(c.id)});
    cb.onclick = ev => { ev.stopPropagation(); cb.checked ? selected.add(c.id) : selected.delete(c.id); upd(); };
    const li = el("li", {className: c.id === current ? "sel" : ""}, cb,
      el("div", {}, el("strong", {textContent: c.fn}), el("small", {textContent: [c.org, c.phone, c.email].filter(Boolean).join(" · ")})));
    li.onclick = () => showDetail(c.id);
    ul.append(li);
  });
  $("count").textContent = `${list.length} von ${contacts.length}` + (list.length > 1000 ? " (erste 1000 angezeigt – Suche nutzen)" : "");
  upd();
}
function upd() { $("expSel").disabled = !selected.size; $("expSel").textContent = `Auswahl exportieren (${selected.size})`; }
$("search").oninput = $("sort").onchange = render;
$("selAll").onchange = ev => { visible().forEach(c => ev.target.checked ? selected.add(c.id) : selected.delete(c.id)); render(); };

async function showDetail(id) {
  current = id; const d = $("detail"); d.replaceChildren();
  if (id === null) { d.append(el("p", {className: "muted", textContent: "Kontakt auswählen."})); return; }
  document.querySelectorAll("#items li").forEach(li => li.classList.remove("sel"));
  let c;
  try { c = await json("/api/contact/" + id); } catch (e) { return fail(e); }
  if (current !== id) return;
  if (c.hasPhoto) d.append(el("img", {src: "/api/photo/" + id, alt: ""}));
  d.append(el("h2", {textContent: c.fn}), el("div", {className: "muted", textContent: [c.title, c.org].filter(Boolean).join(" – ")}));
  const dl = el("dl");
  const add = (label, items) => items.forEach(i => {
    dl.append(el("dt", {textContent: label + (i.type ? ` (${i.type})` : "")}), el("dd", {textContent: i.value}));
  });
  add("Telefon", c.phones); add("E-Mail", c.emails); add("Adresse", c.addresses); add("Web", c.urls);
  if (c.birthday) add("Geburtstag", [{value: c.birthday}]);
  if (c.note) add("Notiz", [{value: c.note}]);
  dl.append(el("dt", {textContent: "vCard-Version"}), el("dd", {textContent: c.version}));
  d.append(dl);
  const one = el("button", {textContent: "Diesen Kontakt exportieren"}); one.onclick = () => exportIds([id]);
  d.append(one);
  render();
}

async function exportIds(ids) {
  $("loadErr").hidden = true;
  try {
    const r = await api("/api/export", {ids, format: $("fmt").value});
    const name = /filename="([^"]+)"/.exec(r.headers.get("Content-Disposition") || "")?.[1] || "kontakte.vcf";
    const a = el("a", {href: URL.createObjectURL(await r.blob()), download: name});
    document.body.append(a); a.click(); a.remove();
  } catch (e) { fail(e); }
}
$("expSel").onclick = () => exportIds([...selected]);
$("expAll").onclick = () => exportIds("all");

(async () => {
  try { const s = await json("/api/state"); start({user: s.user, books: s.books}); } catch (_) {}
})();
