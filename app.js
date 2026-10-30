const supabaseClient = window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);

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
function suscribirCambios(canal, alCambiar, alEstado) {
  let espera;
  const programar = () => {
    clearTimeout(espera);
    espera = setTimeout(alCambiar, 150);
  };
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "visible") programar();
  });
  return supabaseClient
    .channel(canal)
    .on("postgres_changes", { event: "*", schema: "public", table: "participantes" }, programar)
    .subscribe((estado) => alEstado?.(estado));
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
