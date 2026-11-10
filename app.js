// ?demo en la dirección: todo corre en el navegador con datos inventados (demo.js).
const MODO_DEMO = new URLSearchParams(location.search).has("demo");
const supabaseClient = MODO_DEMO
  ? crearClienteDemo()
  : window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);

// ---------- Marca del evento (nombre, organizador, logo y colores) ----------
const MARCA_NEUTRA = {
  evento: "Karaoke Night",
  organizador: "",
  logo: null,
  color_principal: "#e0314b",
  color_destacado: "#f6b21a",
  version: 0,
};
let marcaActual = MARCA_NEUTRA;

const hexARgb = (hex) => {
  const n = parseInt(hex.slice(1), 16);
  return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
};
const rgbAHex = (rgb) => "#" + rgb.map((c) => Math.round(c).toString(16).padStart(2, "0")).join("");
// t > 0 aclara hacia el blanco, t < 0 oscurece hacia el negro.
const matizar = (hex, t) =>
  rgbAHex(hexARgb(hex).map((c) => (t > 0 ? c + (255 - c) * t : c * (1 + t))));

// Texto oscuro sobre colores claros y blanco sobre colores oscuros (luminancia WCAG).
function textoSobre(hex) {
  const [r, g, b] = hexARgb(hex).map((c) => {
    c /= 255;
    return c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4;
  });
  return 0.2126 * r + 0.7152 * g + 0.0722 * b > 0.4 ? "#071633" : "#ffffff";
}

function aplicarColores(principal, destacado) {
  const raiz = document.documentElement.style;
  raiz.setProperty("--accent", principal);
  raiz.setProperty("--accent2", destacado);
  raiz.setProperty("--rojo-rgb", hexARgb(principal).join(", "));
  raiz.setProperty("--oro-rgb", hexARgb(destacado).join(", "));
  raiz.setProperty("--grad-rojo", `linear-gradient(90deg, ${matizar(principal, -0.14)}, ${matizar(principal, 0.1)})`);
  raiz.setProperty("--grad-oro", `linear-gradient(135deg, ${destacado}, ${matizar(destacado, 0.3)})`);
  raiz.setProperty("--sobre-principal", textoSobre(principal));
  raiz.setProperty("--sobre-destacado", textoSobre(destacado));
  raiz.setProperty("--principal-claro", matizar(principal, 0.45));
}

// Pinta la marca en todo lo que la usa: logos, títulos, la pestaña y los colores.
function aplicarMarca(m) {
  marcaActual = { ...MARCA_NEUTRA, ...m };
  const { evento, organizador, logo } = marcaActual;
  aplicarColores(marcaActual.color_principal, marcaActual.color_destacado);

  document.querySelectorAll("[data-logo]").forEach((img) => {
    img.src = logo || "icono.svg";
    img.classList.toggle("por-defecto", !logo);
    img.alt = organizador || evento;
  });
  document.querySelectorAll("[data-marca-evento]").forEach((el) => (el.textContent = evento));
  // data-plantilla usa {org}; sin organizador se muestra data-sin-org (o se oculta).
  document.querySelectorAll("[data-plantilla]").forEach((el) => {
    const texto = organizador ? el.dataset.plantilla.replace("{org}", organizador) : (el.dataset.sinOrg ?? "");
    el.textContent = texto;
    el.classList.toggle("oculto", !texto);
  });
  const sufijo = document.body.dataset.sufijoTitulo ?? "";
  document.title = `${organizador ? organizador + " " : ""}${evento}${sufijo}`;
  const icono = document.getElementById("favicon");
  if (icono) icono.href = logo || "icono.svg";
}

// Se recuerda la última marca para no mostrar la neutra un instante al abrir.
// La demo vive en el mismo sitio que el evento real: cada uno con su clave.
const CLAVE_MARCA = MODO_DEMO ? "karaoke_marca_demo" : "karaoke_marca";

function marcaGuardada() {
  try {
    return JSON.parse(localStorage.getItem(CLAVE_MARCA)) ?? null;
  } catch {
    return null;
  }
}

function recordarMarca(m) {
  try {
    localStorage.setItem(CLAVE_MARCA, JSON.stringify(m));
  } catch {}
}

async function cargarMarca() {
  const { data, error } = await supabaseClient.rpc("marca_publica");
  if (error || !data) return;
  aplicarMarca(data);
  recordarMarca(data);
}

const ETIQUETA_ESTADO = { pendiente: "En espera", cantando: "Cantando", listo: "Ya cantó" };

function escapeHtml(s) {
  return String(s ?? "").replace(/[&<>"']/g, (c) => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
  })[c]);
}

// La barra de arriba queda visible mientras haya al menos un pedido en curso.
let cargasActivas = 0;
async function conCarga(pedido) {
  const barra = document.getElementById("barraCarga");
  cargasActivas++;
  barra?.classList.add("activa");
  try {
    return await pedido;
  } finally {
    cargasActivas--;
    if (cargasActivas === 0) barra?.classList.remove("activa");
  }
}

async function conBoton(boton, accion) {
  boton.classList.add("cargando");
  boton.disabled = true;
  try {
    return await accion();
  } finally {
    boton.classList.remove("cargando");
    boton.disabled = false;
  }
}

function traerParticipantes() {
  return conCarga(
    supabaseClient
      .from("participantes")
      .select("*")
      .order("orden", { ascending: true, nullsFirst: false })
      .order("created_at", { ascending: true })
  );
}

function clasificar(lista) {
  const conPos = lista.map((p, i) => ({ ...p, pos: i + 1 }));
  return {
    ahora: conPos.find((p) => p.estado === "cantando") || null,
    pendientes: conPos.filter((p) => p.estado === "pendiente"),
    listos: conPos.filter((p) => p.estado === "listo"),
    total: conPos.length,
  };
}

// Un cambio de turno dispara dos eventos (el que termina y el que empieza):
// se agrupan para hacer una sola consulta.
function suscribirCambios(canal, alCambiar, alEstado, tablas = ["participantes"]) {
  let espera;
  const programar = () => {
    clearTimeout(espera);
    espera = setTimeout(alCambiar, 150);
  };
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "visible") programar();
  });
  let canalRt = supabaseClient.channel(canal);
  for (const table of tablas) {
    canalRt = canalRt.on("postgres_changes", { event: "*", schema: "public", table }, programar);
  }
  return canalRt.subscribe((estado) => alEstado?.(estado));
}

function traerRevelacion() {
  return conCarga(supabaseClient.rpc("estado_revelacion"));
}

function lluviaDeConfeti(emojis = ["🎉", "✨", "🏆", "🎤", "⭐"], cantidad = 28) {
  if (matchMedia("(prefers-reduced-motion: reduce)").matches) return;
  for (let i = 0; i < cantidad; i++) {
    const c = document.createElement("span");
    c.className = "confeti";
    c.textContent = emojis[i % emojis.length];
    c.style.left = Math.random() * 100 + "vw";
    c.style.setProperty("--dx", Math.random() * 80 - 40 + "px");
    c.style.setProperty("--rot", Math.random() * 60 - 30 + "deg");
    c.style.animationDelay = Math.random() * 0.6 + "s";
    c.addEventListener("animationend", () => c.remove(), { once: true });
    document.body.append(c);
  }
}

function toast(texto, tipo = "ok") {
  let contenedor = document.getElementById("toasts");
  if (!contenedor) {
    contenedor = document.createElement("div");
    contenedor.id = "toasts";
    contenedor.className = "toasts";
    contenedor.setAttribute("role", "status");
    contenedor.setAttribute("aria-live", "polite");
    document.body.append(contenedor);
  }
  const el = document.createElement("div");
  el.className = "toast " + tipo;
  el.textContent = texto;
  contenedor.append(el);
  setTimeout(() => {
    el.classList.add("saliendo");
    el.addEventListener("animationend", () => el.remove(), { once: true });
  }, 2800);
}

// Decide qué animación lleva cada elemento al volver a dibujar la lista:
// "entra" si es nuevo, "cambio" si cambió algo, nada si quedó igual.
function crearAnimador() {
  let anteriores = null;
  return {
    clase(p) {
      if (!anteriores) return "entra";
      const previo = anteriores.get(p.id);
      if (previo === undefined) return "entra";
      return previo === firma(p) ? "" : "cambio";
    },
    recordar(lista) {
      anteriores = new Map(lista.map((p) => [p.id, firma(p)]));
    },
  };
}

function firma(p) {
  return [p.estado, p.nombre, p.cancion, p.pos].join("|");
}
