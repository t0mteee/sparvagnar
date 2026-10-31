// Reseplanering på sidan: från, till, när, och reseförslag från Västtrafik via
// servern (server/resa.py). Samma sak som i appen, i en egen panel. Sidan
// (index.html) öppnar den med knappen uppe till höger och med "Res härifrån"
// och "Res hit" på hållplatsens tavla, via window.Resa.
(() => {
  const $ = id => document.getElementById(id);
  const panel = $("resa"), innehall = $("r-innehall");
  const esc = s => String(s ?? "").replace(/[&<>"]/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);
  const kort = s => String(s ?? "").split(", ")[0];
  const klocka = iso => iso ? new Date(iso).toLocaleTimeString("sv-SE", { hour: "2-digit", minute: "2-digit" }) : "–";
  const restid = m => m == null ? "" : m < 60 ? `${m} min` : m % 60 ? `${Math.floor(m / 60)} tim ${m % 60} min` : `${m / 60} tim`;
  const sen = (t, p) => { if (!t || !p) return 0; const m = Math.round((new Date(t) - new Date(p)) / 60000); return m >= 1 ? m : 0; };
  const ljus = f => { const n = parseInt(String(f).slice(1), 16) || 0; return (0.299 * (n >> 16 & 255) + 0.587 * (n >> 8 & 255) + 0.114 * (n & 255)) / 255; };
  const bricka = d => `<span class="bricka liten" style="background:${d.farg};color:${d.text};${ljus(d.farg) > 0.9 || ljus(d.farg) < 0.25 ? "box-shadow:inset 0 0 0 1px #7b8a99" : ""}">${esc(d.linje)}</span>`;
  const ikon = { hallplats: "🚋", adress: "🏠", plats: "⭐" };

  const s = { fran: null, till: null, soker: null, text: "", traffar: [], nar: "nu", tid: "", framme: false,
              forslag: [], hamtar: false, fel: null, valt: null, detaljer: null, info: null };
  let sokTimer = null, sokNr = 0;

  async function hamta(vag, fraga) {
    const r = await fetch(`${vag}?${new URLSearchParams(fraga)}`);
    const j = await r.json().catch(() => ({}));
    if (!r.ok) throw new Error(j.fel || `Servern svarade ${r.status}.`);
    return j;
  }

  async function narmast(lat, lon, namn) {
    const j = await hamta("api/platser", { lat: lat.toFixed(5), lon: lon.toFixed(5) }).catch(() => ({ platser: [] }));
    return (namn && j.platser.find(p => kort(p.namn) === namn)) || j.platser[0] || null;
  }

  async function hallplats(namn, lat, lon) {
    if (lat != null) { const p = await narmast(lat, lon, namn); if (p) return p; }
    const j = await hamta("api/platser", { q: namn }).catch(() => ({ platser: [] }));
    return j.platser.find(p => p.typ === "hallplats") || null;
  }

  function franMig() {
    if (!navigator.geolocation) { s.info = "Den här webbläsaren kan inte säga var du är."; return visa(); }
    s.info = "Letar efter dig"; visa();
    navigator.geolocation.getCurrentPosition(async pos => {
      const p = await narmast(pos.coords.latitude, pos.coords.longitude);
      s.info = p ? null : "Hittade ingen hållplats nära dig.";
      if (p) { s.fran = p; if (s.soker === "fran") s.soker = null; }
      visa(); sok();
    }, () => { s.info = "Sidan får inte veta var du är. Skriv var du är i stället."; visa(); }, { timeout: 15000, maximumAge: 60000 });
  }

  async function sok() {
    if (!s.fran || !s.till) { s.forslag = []; return visa(); }
    const nr = ++sokNr, fraga = { fran: s.fran.id, till: s.till.id };
    if (s.nar === "vald" && s.tid) { fraga.tid = new Date(s.tid).toISOString(); fraga.avser = s.framme ? "ankomst" : "avgang"; }
    s.hamtar = true; s.fel = null; visa();
    try {
      const j = await hamta("api/resa", fraga);
      if (nr !== sokNr) return;
      s.forslag = j.forslag;
      if (!j.forslag.length) s.fel = "Hittade ingen resa. Prova en annan tid.";
    } catch (e) { if (nr === sokNr) { s.forslag = []; s.fel = e.message; } }
    if (nr === sokNr) { s.hamtar = false; visa(); }
  }

  function skriv(text) {
    s.text = text;
    clearTimeout(sokTimer);
    const q = text.trim();
    if (q.length < 2) { s.traffar = []; return visaTraffar(); }
    sokTimer = setTimeout(async () => {
      const j = await hamta("api/platser", { q }).catch(() => ({ platser: [] }));
      if (s.text.trim() === q) { s.traffar = j.platser; visaTraffar(); }
    }, 300);
  }

  async function visaDetalj(f) {
    s.valt = f; s.detaljer = null; visa();
    if (!f.ref) return;
    const d = await hamta("api/resa/detaljer", { ref: f.ref }).catch(() => null);
    if (s.valt === f) { s.detaljer = d; visa(); }
  }

  // ---------- Ritning ----------

  function falt(namn, etikett, p) {
    if (s.soker === namn) {
      return `<label class="r-falt aktiv"><span>${etikett}</span><input id="r-text" autocomplete="off" placeholder="${namn === "fran" ? "Skriv var du är" : "Skriv vart du ska"}" value="${esc(s.text)}"></label>`;
    }
    return `<button class="r-falt" data-falt="${namn}"><span>${etikett}</span><b class="${p ? "" : "tomt"}">${esc(p ? kort(p.namn) : namn === "fran" ? "Var är du?" : "Vart ska du?")}</b></button>`;
  }

  function traffarHtml() {
    let h = s.soker === "fran" ? `<li data-mig>📍 <b>Närmast mig</b></li>` : "";
    h += s.traffar.map((p, i) => `<li data-i="${i}">${ikon[p.typ] || "⭐"} <b>${esc(kort(p.namn))}</b> <small>${esc(p.namn.split(", ").slice(1).join(", "))}</small></li>`).join("");
    if (!s.traffar.length && s.text.trim().length >= 2) h += `<li class="tom">Hittade inget som heter så.</li>`;
    return h;
  }

  function visaTraffar() {
    const ul = $("r-traffar");
    if (!ul) return;
    ul.innerHTML = traffarHtml();
    ul.querySelectorAll("li[data-i]").forEach(li => li.onclick = () => valjPlats(s.traffar[+li.dataset.i]));
    const mig = ul.querySelector("li[data-mig]");
    if (mig) mig.onclick = franMig;
  }

  function valjPlats(p) {
    s[s.soker] = p; s.soker = null; s.text = ""; s.traffar = []; s.info = null;
    visa(); sok();
  }

  function rad(f, i) {
    const delar = f.delar.map(d => d.typ === "gang" ? `<span class="r-gang">🚶${d.minuter}</span>` : bricka(d)).join(`<span class="r-pil">›</span>`);
    const start = f.delar.find(d => d.typ === "fard");
    const tid = (t, p) => `<b class="${sen(t, p) ? "sen" : ""}">${klocka(t)}</b>${sen(t, p) ? `<s>${klocka(p)}</s>` : ""}`;
    const om = Math.floor((new Date(f.avgang) - Date.now()) / 60000);
    return `<li class="r-forslag${f.installd ? " installd" : ""}" data-i="${i}">
      <div class="r-tider">${tid(f.avgang, f.avgangPlan)} → ${tid(f.ankomst, f.ankomstPlan)}<span>${restid(f.minuter)}</span></div>
      <div class="r-delar">${delar}</div>
      <div class="r-om">${f.installd ? `<b class="r-rod">Inställd</b>` : `${!start ? "Gå hela vägen" : f.byten ? f.byten === 1 ? "1 byte" : `${f.byten} byten` : "Inga byten"}${start ? ` · från ${esc(kort(start.fran.namn))}${start.fran.lage ? `, läge ${esc(start.fran.lage)}` : ""}` : ""}`}
        ${!f.installd && om >= 0 && om < 60 ? `<b class="${om < 3 ? "sen" : "itid"}">${om ? `om ${om} min` : "Gå nu!"}</b>` : ""}</div>
    </li>`;
  }

  function stopp(d) {
    const det = s.detaljer?.delar.find(x => x.index === d.index);
    return det?.stopp.length ? det.stopp : [d.fran, d.till];
  }

  function detalj(f) {
    let h = `<button class="r-tillbaka" id="r-tillbaka">‹ Alla resor</button>
      <div class="titel">${klocka(f.avgang)} – ${klocka(f.ankomst)}<small>${restid(f.minuter)}${f.byten ? `, ${f.byten === 1 ? "1 byte" : `${f.byten} byten`}` : ", inga byten"}</small></div>`;
    if (f.installd) h += `<p class="r-rod">Någon del av resan är inställd. Välj en annan resa.</p>`;
    for (const d of f.delar) {
      if (d.typ === "gang") { h += `<p class="r-gangrad">🚶 Gå ${d.minuter} min${d.meter ? `, ${Math.round(d.meter)} meter` : ""}${!d.till ? "" : kort(d.till) === kort(d.fran) ? " till nästa läge" : ` till ${esc(kort(d.till))}`}</p>`; continue; }
      const st = stopp(d);
      h += `<div class="r-fard"><div class="r-fardhuvud">${bricka(d)} <b>mot ${esc(kort(d.mot))}</b>${d.installd ? ` <b class="r-rod">Inställd</b>` : d.delvisInstalld ? ` <b class="r-rod">Delvis inställd</b>` : ""}</div>
        <ol class="linjeband" style="--linjefarg:${d.farg}">${st.map((p, i) => {
          const kant = i === 0 || i === st.length - 1, m = sen(p.tid, p.plan);
          return `<li class="${kant ? "" : "passerad"}"><span class="nod"><i></i></span><span>${kant ? "<b>" : ""}${esc(kort(p.namn))}${kant ? "</b>" : ""}${kant && p.lage ? ` <small>läge ${esc(p.lage)}</small>` : ""}</span>`
            + `<span class="tidsiffra">${m ? `<span class="sen">+${m}</span> ` : ""}${klocka(p.tid)}</span></li>`;
        }).join("")}</ol>${(d.info || []).map(t => `<p class="r-info">${esc(t)}</p>`).join("")}</div>`;
    }
    h += `<p class="r-framme">🏁 <b>Framme vid ${esc(kort(s.till?.namn || f.delar.at(-1)?.till?.namn || f.delar.at(-1)?.till))}</b> ${klocka(f.ankomst)}</p>`;
    return h;
  }

  function visa() {
    if (panel.hidden) return;
    if (s.valt) {
      innehall.innerHTML = detalj(s.valt);
      $("r-tillbaka").onclick = () => { s.valt = null; s.detaljer = null; visa(); };
      return;
    }
    let h = `<div class="titel">Vart vill du åka?</div>
      <div class="r-faltrad"><div class="r-falten">${falt("fran", "Från", s.fran)}${falt("till", "Till", s.till)}</div>
        <button class="r-byt" id="r-byt" aria-label="Byt håll">⇅</button></div>`;
    if (s.info) h += `<p class="tom">${esc(s.info)}</p>`;
    if (s.soker) {
      h += `<ul class="tavla r-traffar" id="r-traffar">${traffarHtml()}</ul><button id="r-avbryt">Avbryt</button>`;
    } else {
      h += `<div class="knapprad r-nar"><button data-nar="nu" aria-pressed="${s.nar === "nu"}">Åka nu</button><button data-nar="vald" aria-pressed="${s.nar === "vald"}">Välj tid</button></div>`;
      if (s.nar === "vald") {
        h += `<div class="knapprad r-nar"><button data-framme="0" aria-pressed="${!s.framme}">Åka då</button><button data-framme="1" aria-pressed="${s.framme}">Vara framme då</button></div>
          <input type="datetime-local" id="r-tid" value="${esc(s.tid)}">`;
      }
      if (s.hamtar && !s.forslag.length) h += `<p class="tom">Letar efter resor …</p>`;
      else if (s.fel) h += `<p class="tom">${esc(s.fel)}</p>`;
      else if (s.forslag.length) h += `<ol class="r-lista${s.hamtar ? " hamtar" : ""}">${s.forslag.map(rad).join("")}</ol><button id="r-uppdatera">↻ Uppdatera</button>`;
    }
    innehall.innerHTML = h;

    innehall.querySelectorAll("[data-falt]").forEach(b => b.onclick = () => { s.soker = b.dataset.falt; s.text = ""; s.traffar = []; visa(); });
    $("r-byt").onclick = () => { [s.fran, s.till] = [s.till, s.fran]; visa(); sok(); };
    const inp = $("r-text");
    if (inp) {
      inp.focus();
      inp.oninput = () => skriv(inp.value);
      inp.onkeydown = e => { if (e.key === "Enter" && s.traffar[0]) valjPlats(s.traffar[0]); if (e.key === "Escape") { s.soker = null; visa(); } };
      visaTraffar();
    }
    if ($("r-avbryt")) $("r-avbryt").onclick = () => { s.soker = null; s.text = ""; s.traffar = []; visa(); };
    innehall.querySelectorAll("[data-nar]").forEach(b => b.onclick = () => {
      s.nar = b.dataset.nar;
      if (s.nar === "vald" && !s.tid) { const d = new Date(Date.now() - new Date().getTimezoneOffset() * 60000); s.tid = d.toISOString().slice(0, 16); }
      visa(); sok();
    });
    innehall.querySelectorAll("[data-framme]").forEach(b => b.onclick = () => { s.framme = b.dataset.framme === "1"; visa(); sok(); });
    if ($("r-tid")) $("r-tid").onchange = e => { s.tid = e.target.value; sok(); };
    if ($("r-uppdatera")) $("r-uppdatera").onclick = sok;
    innehall.querySelectorAll(".r-forslag").forEach(li => li.onclick = () => visaDetalj(s.forslag[+li.dataset.i]));
  }

  function oppna() {
    panel.hidden = false;
    if (!$("kort").hidden) $("stang").click();
    visa();
  }

  window.Resa = {
    /// Knappen uppe till höger.
    oppna() {
      oppna();
      if (!s.fran) { if (!s.till) s.soker = "till"; franMig(); }
      visa();
    },
    /// Från hållplatsens tavla: res härifrån eller hit.
    async hallplats(namn, hit, lat, lon) {
      s.valt = null; s.soker = null;
      oppna();
      const p = await hallplats(namn, lat, lon);
      if (!p) { s.info = "Hittade inte hållplatsen hos Västtrafik."; return visa(); }
      if (hit) { s.till = p; if (!s.fran) franMig(); } else { s.fran = p; if (!s.till) { s.soker = "till"; s.text = ""; } }
      visa(); sok();
    },
    stang() { panel.hidden = true; },
  };
  $("r-stang").onclick = () => { panel.hidden = true; };
  $("resa-knapp").onclick = () => window.Resa.oppna();
  // Kortet med en vagn eller hållplats och reseplaneringen ligger på samma plats; bara ett åt gången.
  new MutationObserver(() => { if (!$("kort").hidden) panel.hidden = true; }).observe($("kort"), { attributes: true, attributeFilter: ["hidden"] });
})();
