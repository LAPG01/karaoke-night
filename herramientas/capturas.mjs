// Genera las capturas y el GIF del README recorriendo la demo (?demo) en un
// Chromium sin ventana, manejado por el protocolo de DevTools. Sin dependencias:
// necesita Node 22+, Chromium, ffmpeg y (opcional) ImageMagick para achicar los PNG.
//
//   python3 -m http.server 8731      # en la carpeta del proyecto, en otra terminal
//   node herramientas/capturas.mjs   # deja todo en docs/
import { spawn, spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync, rmSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const BASE = process.env.BASE ?? "http://localhost:8731";
const DOCS = join(dirname(fileURLToPath(import.meta.url)), "..", "docs");
const TEMP = mkdtempSync(join(tmpdir(), "karaoke-capturas-"));
const PUERTO = 9333;
const dormir = (ms) => new Promise((r) => setTimeout(r, ms));
mkdirSync(DOCS, { recursive: true });

// ---------- Chromium + protocolo de DevTools ----------
async function navegador(perfil) {
  const proceso = spawn("chromium", [
    "--headless=new", `--remote-debugging-port=${PUERTO}`, `--user-data-dir=${perfil}`,
    "--no-first-run", "--hide-scrollbars", "--force-color-profile=srgb", "--lang=es-VE",
    "--disable-background-timer-throttling", "--disable-renderer-backgrounding", "about:blank",
  ], { stdio: "ignore" });
  process.on("exit", () => proceso.kill());

  let ws;
  for (let i = 0; i < 50 && !ws; i++) {
    try {
      const v = await (await fetch(`http://127.0.0.1:${PUERTO}/json/version`)).json();
      ws = new WebSocket(v.webSocketDebuggerUrl);
    } catch { await dormir(200); }
  }
  if (!ws) throw new Error("No arrancó Chromium");
  await new Promise((r) => ws.addEventListener("open", r, { once: true }));

  let sig = 0;
  const pendientes = new Map();
  ws.addEventListener("message", (e) => {
    const m = JSON.parse(e.data);
    if (!m.id || !pendientes.has(m.id)) return;
    const { ok, mal } = pendientes.get(m.id);
    pendientes.delete(m.id);
    m.error ? mal(new Error(m.error.message)) : ok(m.result);
  });
  const enviar = (method, params = {}, sessionId) => new Promise((ok, mal) => {
    const id = ++sig;
    pendientes.set(id, { ok, mal });
    ws.send(JSON.stringify({ id, method, params, sessionId }));
  });
  const cerrar = async () => {
    ws.close();
    proceso.kill();
    await dormir(500);
  };
  return { enviar, cerrar };
}

function pestaña(enviar, s) {
  const js = async (expresion) => {
    const r = await enviar("Runtime.evaluate", { expression: expresion, awaitPromise: true, returnByValue: true }, s);
    if (r.exceptionDetails) {
      throw new Error(expresion.slice(0, 80) + " → " + (r.exceptionDetails.exception?.description ?? r.exceptionDetails.text));
    }
    return r.result.value;
  };
  const clic = (selector) => js(`(() => {
    const e = document.querySelector(${JSON.stringify(selector)});
    if (!e) throw new Error("no está: " + ${JSON.stringify(selector)});
    e.click();
    return true;
  })()`);
  const captura = async (nombre) => {
    const { data } = await enviar("Page.captureScreenshot", { format: "png" }, s);
    const crudo = join(TEMP, nombre + ".png");
    writeFileSync(crudo, Buffer.from(data, "base64"));
    // 256 colores alcanzan para esta interfaz y el archivo pesa ~3 veces menos.
    const destino = join(DOCS, nombre + ".png");
    const r = spawnSync("magick", [crudo, "-strip", "-colors", "256", "PNG8:" + destino]);
    if (r.status !== 0) writeFileSync(destino, Buffer.from(data, "base64"));
    console.log("  captura", nombre);
  };
  return { s, js, clic, captura };
}

async function abrir({ enviar }, url, escala) {
  const { targetId } = await enviar("Target.createTarget", { url: "about:blank" });
  const { sessionId: s } = await enviar("Target.attachToTarget", { targetId, flatten: true });
  await enviar("Page.enable", {}, s);
  await enviar("Runtime.enable", {}, s);
  await enviar("Emulation.setDeviceMetricsOverride", { width: 390, height: 844, deviceScaleFactor: escala, mobile: true }, s);
  await enviar("Emulation.setTouchEmulationEnabled", { enabled: true, maxTouchPoints: 5 }, s);
  await enviar("Emulation.setFocusEmulationEnabled", { enabled: true }, s);
  await enviar("Page.navigate", { url }, s);
  await dormir(2500);
  const p = pestaña(enviar, s);
  await p.js("document.fonts.ready.then(() => true)");
  // El aviso de "demo" no es parte de la interfaz: fuera de las capturas.
  await p.js(`document.head.insertAdjacentHTML("beforeend", "<style>.banner-demo{display:none!important}</style>"); true`);
  await dormir(300);
  p.targetId = targetId;
  return p;
}

// Graba cuadros sin parar; cada uno con su hora para que el GIF respete el ritmo real.
function grabar({ enviar }, p, carpeta) {
  const lista = [];
  let activo = true;
  const hecho = (async () => {
    while (activo) {
      const t = Date.now();
      const { data } = await enviar("Page.captureScreenshot", { format: "jpeg", quality: 92 }, p.s);
      const archivo = join(carpeta, String(lista.length).padStart(4, "0") + ".jpg");
      writeFileSync(archivo, Buffer.from(data, "base64"));
      lista.push({ archivo, t });
    }
  })();
  return async () => {
    activo = false;
    await hecho;
    let txt = "";
    lista.forEach((c, i) => {
      const dur = ((lista[i + 1]?.t ?? c.t + 2500) - c.t) / 1000;
      txt += `file '${c.archivo}'\nduration ${dur.toFixed(3)}\n`;
    });
    txt += `file '${lista.at(-1).archivo}'\n`;
    writeFileSync(join(carpeta, "lista.txt"), txt);
    return lista.length;
  };
}

// ---------- Recorridos ----------
async function recorrerAdmin(nav) {
  const a = await abrir(nav, `${BASE}/admin.html?demo`, 2);
  await a.clic("#btnEntrar");
  await dormir(2500);
  await a.captura("admin-en-vivo");
  await a.clic('.nav [data-ir="lista"]');
  await dormir(1500);
  await a.captura("admin-participantes");
  await a.clic('.nav [data-ir="votos"]');
  await dormir(1800);
  await a.clic("#btnSospechosos");
  await dormir(800);
  await a.js(`(() => {
    const y = document.getElementById("cuentaBloqueados").getBoundingClientRect().top + scrollY - 90;
    scrollTo({ top: y });
    return true;
  })()`);
  await dormir(800);
  await a.captura("admin-sospechosos");
  await a.clic('.nav [data-ir="historial"]');
  await dormir(1800);
  await a.js(`document.querySelectorAll("#historial details").forEach((d) => (d.open = true)); true`);
  await dormir(600);
  await a.captura("admin-historial");
  await a.clic('.nav [data-ir="vivo"]');
  await dormir(800);
  // Editor de marca con otra identidad: solo la vista previa, no se guarda.
  await a.clic("#btnMarca");
  await dormir(900);
  await a.js(`(() => {
    const poner = (id, v) => {
      const e = document.getElementById(id);
      e.value = v;
      e.dispatchEvent(new Event("input", { bubbles: true }));
      e.dispatchEvent(new Event("change", { bubbles: true }));
    };
    poner("marcaEvento", "Noche de Talentos");
    poner("marcaOrganizador", "Colegio Los Andes");
    poner("colorPrincipal", "#7c3aed");
    poner("colorDestacado", "#22d3ee");
    return true;
  })()`);
  await dormir(1200);
  await a.captura("admin-marca");
  await nav.enviar("Target.closeTarget", { targetId: a.targetId });
}

// Del lado del público: nombre, voto, cierre y revelación del último al primero.
// Las acciones del admin se hacen por la misma API, desde la misma pestaña.
async function recorrerPublico(nav, { gif }) {
  const p = await abrir(nav, `${BASE}/?demo`, gif ? 1 : 2);
  const captura = gif ? async () => {} : p.captura;
  const detener = gif ? grabar(nav, p, gif) : null;

  await dormir(1600);
  for (const letra of "Mariana") {
    await p.js(`(() => {
      const e = document.getElementById("nombreVotante");
      e.value += ${JSON.stringify(letra)};
      e.dispatchEvent(new Event("input", { bubbles: true }));
      return true;
    })()`);
    await dormir(140);
  }
  await dormir(700);
  await p.js(`document.getElementById("formNombre").requestSubmit(); true`);
  await dormir(2600);
  await captura("publico-votar");

  const botonValeria = `document.querySelector('[data-votar="' + ultimaLista.find((x) => x.nombre.startsWith("Valeria")).id + '"]')`;
  await p.js(`${botonValeria}.scrollIntoView({ behavior: "smooth", block: "center" }); true`);
  await dormir(1300);
  await p.js(`${botonValeria}.click(); true`);
  await dormir(1500);
  await captura("publico-confirmar");
  await p.clic("#hojaConfirmar");
  await dormir(2600);

  await p.js(`(async () => {
    window.__sesion = (await supabaseClient.rpc("iniciar_sesion", { p_usuario: "demo", p_clave: "demo" })).data;
    await supabaseClient.rpc("cerrar_votacion", { p_clave: window.__sesion });
    scrollTo({ top: 0 });
    await cargar();
    return true;
  })()`);
  await dormir(2400);
  const total = await p.js("revelacion.total");
  for (let i = 1; i <= total; i++) {
    await p.js(`(async () => {
      await supabaseClient.rpc("revelar_siguiente", { p_clave: window.__sesion });
      await cargar();
      return true;
    })()`);
    await dormir(i <= total - 3 ? 1000 : i < total ? 2000 : 3800);
  }
  if (gif) return detener();

  await p.js("scrollTo({ top: 0 }); true");
  await dormir(600);
  await captura("publico-resultados");

  // Otra marca guardada de verdad (en la demo): el público la toma sola.
  await p.js(`(async () => {
    await supabaseClient.rpc("reabrir_votacion", { p_clave: window.__sesion });
    await supabaseClient.rpc("guardar_marca", {
      p_clave: window.__sesion, p_evento: "Noche de Talentos", p_organizador: "Colegio Los Andes",
      p_logo: null, p_color_principal: "#7c3aed", p_color_destacado: "#22d3ee",
    });
    scrollTo({ top: 0 });
    await cargar();
    return true;
  })()`);
  await dormir(2500);
  await captura("publico-otra-marca");
}

try {
  console.log("Capturas (cada pasada arranca la demo desde cero):");
  let nav = await navegador(join(TEMP, "perfil-1"));
  await recorrerAdmin(nav);
  await recorrerPublico(nav, { gif: null });
  await nav.cerrar();

  console.log("GIF:");
  const cuadros = join(TEMP, "cuadros");
  mkdirSync(cuadros);
  nav = await navegador(join(TEMP, "perfil-2"));
  const n = await recorrerPublico(nav, { gif: cuadros });
  await nav.cerrar();
  const r = spawnSync("ffmpeg", [
    "-loglevel", "error", "-y", "-f", "concat", "-safe", "0", "-i", join(cuadros, "lista.txt"),
    "-vf", "fps=10,scale=360:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=128:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=3:diff_mode=rectangle",
    join(DOCS, "demo.gif"),
  ], { stdio: "inherit" });
  if (r.status !== 0) throw new Error("ffmpeg falló");
  console.log(`  demo.gif (${n} cuadros)`);
} finally {
  rmSync(TEMP, { recursive: true, force: true });
}
process.exit(0);
