// Modo demo (?demo en la dirección): una base de datos simulada dentro del
// navegador, con las mismas funciones y reglas que la de Supabase (schema.sql).
// No toca la base real y no depende de ningún servidor. Pestañas abiertas en el
// mismo navegador comparten los datos (localStorage) y se avisan los cambios.

function crearClienteDemo() {
  const CLAVE = "karaoke_demo_v1";
  const IP = "demo";
  const ahora = () => new Date().toISOString();
  const hace = (min) => new Date(Date.now() - min * 60000).toISOString();
  const id = () => (crypto.randomUUID ? crypto.randomUUID() : String(Math.random()).slice(2) + Date.now());
  const pausa = () => new Promise((r) => setTimeout(r, 120 + Math.random() * 220));

  // ---------- Datos inventados para mostrar todo funcionando ----------
  function datosIniciales() {
    const canciones = [
      ["Sofía Rivas", "Rolling in the Deep — Adele", "listo"],
      ["Marco Díaz", "Bohemian Rhapsody — Queen", "listo"],
      ["Lucía Fernández", "Vivir Mi Vida — Marc Anthony", "listo"],
      ["Andrés Paredes", "La Bamba — Ritchie Valens", "cantando"],
      ["Valeria Gómez", "Shallow — Lady Gaga", "pendiente"],
      ["Diego Salas", "Livin' on a Prayer — Bon Jovi", "pendiente"],
      ["Camila Ortega", "Despacito — Luis Fonsi", "pendiente"],
      ["Tomás Herrera", "Hotel California — Eagles", "pendiente"],
    ];
    const participantes = canciones.map(([nombre, cancion, estado], i) => ({
      id: id(), nombre, cancion, orden: i + 1, estado, created_at: hace(90 - i),
    }));
    const votantes = ["Ana", "Luis", "Carla", "Pedro", "Rosa", "Jorge", "Elena", "Mateo", "Paula", "Iván",
      "Nora", "Raúl", "Sara", "Hugo", "Lola", "Fede", "Inés", "Bruno", "Clara", "Simón", "Dalia", "Gael"];
    // Votos por participante (en el orden de arriba).
    const reparto = [5, 3, 7, 4, 2, 1, 0, 0];
    const votos = [];
    let k = 0;
    reparto.forEach((n, i) => {
      for (let j = 0; j < n; j++) {
        votos.push({
          id: id(), dispositivo: id(), votante: votantes[k % votantes.length] + (k >= votantes.length ? " B." : ""),
          participante_id: participantes[i].id, created_at: hace(60 - k * 2),
          huella: "huella-" + k, ip: IP, senales: [], pais: "VE",
        });
        k++;
      }
    });
    // Dos votos sospechosos: un navegador disfrazado de celular y uno por la red Tor.
    votos[3].votante = "Perfil 7";
    votos[3].senales = ["gpu_pc", "plugins"];
    votos[3].pais = "US";
    votos[9].votante = "Usuario X";
    votos[9].pais = "T1";

    const bloqueados = [{
      id: id(), dispositivo: id(), votante: "Ana (otra pestaña)", participante_id: participantes[0].id,
      huella: votos[0].huella, ip: IP, coincide_con: votos[0].votante, created_at: hace(8),
    }];

    // Una competencia anterior, ya guardada en el historial.
    const ayer = (min) => new Date(Date.now() - 86400000 + min * 60000).toISOString();
    const anteriores = [["Gabriela Núñez", "Halo — Beyoncé", 6], ["Ricardo Mora", "Mi Gente — J Balvin", 4],
      ["Paola Méndez", "Someone Like You — Adele", 4], ["Fernando Ruiz", "Thriller — Michael Jackson", 1]];
    const histPart = [];
    const histVotos = [];
    let v = 0;
    anteriores.forEach(([nombre, cancion, n], i) => {
      histPart.push({ competencia_id: 1, turno: i + 1, nombre, cancion, votos: n, puesto: 0, participante_id: null });
      for (let j = 0; j < n; j++) {
        histVotos.push({ competencia_id: 1, votante: votantes[v++ % votantes.length], participante: nombre, votado_at: ayer(30 + v * 3), participante_id: null });
      }
    });
    asignarPuestos(histPart, "votos");

    return {
      evento: { votacion_abierta: true, revelados: 0, total_puestos: 0, competencia_id: 2 },
      marca: { evento: "Karaoke Night", organizador: "Demo", logo: null, color_principal: "#e0314b", color_destacado: "#f6b21a", version: 1 },
      participantes, votos, bloqueados,
      ranking: [],
      competencias: [{ id: 1, empezo: ayer(0), termino: ayer(160) }, { id: 2, empezo: hace(95), termino: null }],
      histPart, histVotos,
      sesiones: [],
      siguienteCompetencia: 3,
    };
  }

  // Puesto con empates (como rank() en SQL): 10, 7, 7, 3 → 1, 2, 2, 4.
  function asignarPuestos(filas, campo) {
    const orden = [...filas].sort((a, b) => b[campo] - a[campo]);
    orden.forEach((f, i) => (f.puesto = i > 0 && orden[i - 1][campo] === f[campo] ? orden[i - 1].puesto : i + 1));
  }

  function leer() {
    try {
      const guardado = JSON.parse(localStorage.getItem(CLAVE));
      if (guardado) return guardado;
    } catch {}
    const nuevo = datosIniciales();
    guardar(nuevo);
    return nuevo;
  }
  function guardar(db) {
    try {
      localStorage.setItem(CLAVE, JSON.stringify(db));
    } catch {}
    avisar();
  }

  // ---------- Reglas (las mismas que las funciones de schema.sql) ----------
  const fallar = (mensaje) => {
    throw new Error(mensaje);
  };
  const exigirSesion = (db, t) => db.sesiones.includes(t) || fallar("Clave incorrecta");
  const exigirAbierta = (db) => db.evento.votacion_abierta || fallar("La votación está cerrada");
  const porOrden = (db) => [...db.participantes].sort((a, b) => a.orden - b.orden);
  const cuenta = (db, pid) => db.votos.filter((v) => v.participante_id === pid).length;

  function revelacion(db) {
    const e = db.evento;
    return {
      votacion_abierta: e.votacion_abierta, revelados: e.revelados, total: e.total_puestos,
      puestos: db.ranking.filter((r) => r.orden > e.total_puestos - e.revelados).sort((a, b) => a.orden - b.orden)
        .map(({ orden, puesto, nombre, cancion, votos }) => ({ orden, puesto, nombre, cancion, votos })),
    };
  }

  function archivar(db) {
    const cid = db.evento.competencia_id;
    db.histPart = db.histPart.filter((h) => h.competencia_id !== cid);
    db.histVotos = db.histVotos.filter((h) => h.competencia_id !== cid);
    const filas = db.participantes.map((p) => ({
      competencia_id: cid, turno: p.orden, nombre: p.nombre, cancion: p.cancion,
      votos: cuenta(db, p.id), puesto: 0, participante_id: p.id,
    }));
    asignarPuestos(filas, "votos");
    db.histPart.push(...filas);
    for (const v of db.votos) {
      const p = db.participantes.find((x) => x.id === v.participante_id);
      if (p) db.histVotos.push({ competencia_id: cid, votante: v.votante, participante: p.nombre, votado_at: v.created_at, participante_id: p.id });
    }
  }

  const marcaPublica = (db) => ({ ...db.marca });

  const funciones = {
    estado_publico: (db) => ({
      participantes: porOrden(db).map(({ id, nombre, cancion, orden, estado, created_at }) => ({ id, nombre, cancion, orden, estado, created_at })),
      revelacion: revelacion(db),
      marca_version: db.marca.version,
    }),
    estado_revelacion: (db) => revelacion(db),
    marca_publica: (db) => marcaPublica(db),
    mi_voto: (db, p) => db.votos.find((v) => v.dispositivo === p.p_dispositivo)?.participante_id ?? null,

    votar(db, p) {
      exigirAbierta(db);
      if ((p.p_votante ?? "").trim().length < 2) fallar("Escribí tu nombre");
      if ((p.p_huella ?? "").length < 16) fallar("Actualizá la página para poder votar");
      if (db.votos.some((v) => v.dispositivo === p.p_dispositivo)) fallar("Ya votaste");
      if (!db.participantes.some((x) => x.id === p.p_participante)) fallar("Ese participante ya no está en la lista");
      const duenio = db.votos.find((v) => v.huella === p.p_huella && v.ip === IP);
      if (duenio) {
        db.bloqueados = db.bloqueados.filter((b) => b.dispositivo !== p.p_dispositivo);
        db.bloqueados.push({ id: id(), dispositivo: p.p_dispositivo, votante: p.p_votante.trim().slice(0, 40), participante_id: p.p_participante, huella: p.p_huella, ip: IP, coincide_con: duenio.votante, created_at: ahora() });
        return { ok: false, motivo: "mismo_celular" };
      }
      const validas = ["automatizado", "computadora", "sin_tactil", "gpu_pc", "plugins", "so_no_coincide", "pantalla", "zona_horaria"];
      db.votos.push({
        id: id(), dispositivo: p.p_dispositivo, votante: p.p_votante.trim().slice(0, 40), participante_id: p.p_participante,
        created_at: ahora(), huella: p.p_huella, ip: IP, senales: [...new Set((p.p_senales ?? []).filter((s) => validas.includes(s)))], pais: "VE",
      });
      return { ok: true, participante: p.p_participante };
    },
    quitar_voto(db, p) {
      exigirAbierta(db);
      db.votos = db.votos.filter((v) => v.dispositivo !== p.p_dispositivo);
      return null;
    },

    // ---------- Admin ----------
    iniciar_sesion(db, p) {
      if ((p.p_usuario ?? "").trim().toLowerCase() !== "demo" || p.p_clave !== "demo") fallar("Usuario o contraseña incorrectos");
      const t = id();
      db.sesiones.push(t);
      return t;
    },
    cerrar_sesion(db, p) {
      db.sesiones = db.sesiones.filter((t) => t !== p.p_token);
      return null;
    },
    verificar_clave: (db, p) => db.sesiones.includes(p.p_clave),

    agregar_participante(db, p) {
      exigirSesion(db, p.p_clave);
      const n = db.participantes.length;
      const k = Math.min(Math.max(p.p_orden ?? n + 1, 1), n + 1);
      db.participantes.forEach((x) => x.orden >= k && x.orden++);
      const fila = { id: id(), nombre: p.p_nombre.trim(), cancion: p.p_cancion.trim(), orden: k, estado: "pendiente", created_at: ahora() };
      db.participantes.push(fila);
      return fila;
    },
    editar_participante(db, p) {
      exigirSesion(db, p.p_clave);
      const fila = db.participantes.find((x) => x.id === p.p_id) ?? fallar("Participante no encontrado");
      const a = fila.orden;
      const b = Math.min(Math.max(p.p_orden ?? a, 1), db.participantes.length);
      for (const x of db.participantes) {
        if (x === fila) continue;
        if (b < a && x.orden >= b && x.orden < a) x.orden++;
        if (b > a && x.orden > a && x.orden <= b) x.orden--;
      }
      Object.assign(fila, { orden: b, nombre: p.p_nombre.trim(), cancion: p.p_cancion.trim() });
      // Las copias guardadas al cerrar también se corrigen.
      db.ranking.forEach((r) => r.participante_id === fila.id && Object.assign(r, { nombre: fila.nombre, cancion: fila.cancion }));
      db.histPart.forEach((h) => h.participante_id === fila.id && Object.assign(h, { nombre: fila.nombre, cancion: fila.cancion }));
      db.histVotos.forEach((h) => h.participante_id === fila.id && (h.participante = fila.nombre));
      return fila;
    },
    borrar_participante(db, p) {
      exigirSesion(db, p.p_clave);
      const fila = db.participantes.find((x) => x.id === p.p_id);
      if (!fila) return null;
      db.participantes = db.participantes.filter((x) => x !== fila);
      db.participantes.forEach((x) => x.orden > fila.orden && x.orden--);
      db.votos = db.votos.filter((v) => v.participante_id !== fila.id);
      db.bloqueados = db.bloqueados.filter((v) => v.participante_id !== fila.id);
      return null;
    },
    cambiar_estado(db, p) {
      exigirSesion(db, p.p_clave);
      const fila = db.participantes.find((x) => x.id === p.p_id) ?? fallar("Participante no encontrado");
      if (p.p_estado === "cantando") db.participantes.forEach((x) => x !== fila && x.estado === "cantando" && (x.estado = "listo"));
      fila.estado = p.p_estado;
      return fila;
    },

    votos_admin(db, p) {
      exigirSesion(db, p.p_clave);
      const sospechas = (v) => [...(v.senales ?? []),
        ...(v.pais === "T1" ? ["ip_tor"] : v.pais === "XX" ? ["ip_desconocida"] : v.pais && v.pais !== "VE" ? ["ip_extranjera:" + v.pais] : [])];
      const desc = (a, b) => b.created_at.localeCompare(a.created_at);
      return {
        votos: [...db.votos].sort(desc).map((v) => ({ id: v.id, votante: v.votante, participante_id: v.participante_id, created_at: v.created_at, sospechas: sospechas(v) })),
        bloqueados: [...db.bloqueados].sort(desc).map(({ id, votante, participante_id, coincide_con, created_at }) => ({ id, votante, participante_id, coincide_con, created_at })),
      };
    },
    aceptar_bloqueado(db, p) {
      exigirSesion(db, p.p_clave);
      exigirAbierta(db);
      const b = db.bloqueados.find((x) => x.id === p.p_id) ?? fallar("Ese intento ya no está");
      if (!db.votos.some((v) => v.dispositivo === b.dispositivo)) {
        db.votos.push({ id: id(), dispositivo: b.dispositivo, votante: b.votante, participante_id: b.participante_id, created_at: ahora(), huella: b.huella, ip: b.ip, senales: [], pais: "VE" });
      }
      db.bloqueados = db.bloqueados.filter((x) => x !== b);
      return null;
    },
    descartar_bloqueado(db, p) {
      exigirSesion(db, p.p_clave);
      db.bloqueados = db.bloqueados.filter((x) => x.id !== p.p_id);
      return null;
    },
    anular_voto(db, p) {
      exigirSesion(db, p.p_clave);
      exigirAbierta(db);
      db.votos = db.votos.filter((v) => v.id !== p.p_id);
      return null;
    },

    cerrar_votacion(db, p) {
      exigirSesion(db, p.p_clave);
      const filas = db.participantes.map((x) => ({ participante_id: x.id, nombre: x.nombre, cancion: x.cancion, votos: cuenta(db, x.id), orden: x.orden, puesto: 0 }));
      asignarPuestos(filas, "votos");
      filas.sort((a, b) => b.votos - a.votos || a.orden - b.orden);
      db.ranking = filas.map((f, i) => ({ ...f, orden: i + 1 }));
      Object.assign(db.evento, { votacion_abierta: false, revelados: 0, total_puestos: db.ranking.length });
      archivar(db);
      return null;
    },
    revelar_siguiente(db, p) {
      exigirSesion(db, p.p_clave);
      if (db.evento.votacion_abierta) fallar("Primero cerrá la votación");
      db.evento.revelados = Math.min(db.evento.revelados + 1, db.evento.total_puestos);
      return db.evento.revelados;
    },
    reabrir_votacion(db, p) {
      exigirSesion(db, p.p_clave);
      db.ranking = [];
      Object.assign(db.evento, { votacion_abierta: true, revelados: 0, total_puestos: 0 });
      return null;
    },
    nueva_competencia(db, p) {
      exigirSesion(db, p.p_clave);
      if (db.evento.votacion_abierta) archivar(db);
      const anterior = db.evento.competencia_id;
      const comp = db.competencias.find((c) => c.id === anterior);
      if (comp) comp.termino = ahora();
      db.votos = [];
      db.bloqueados = [];
      db.ranking = [];
      if (p.p_borrar_participantes) db.participantes = [];
      else db.participantes.forEach((x) => (x.estado = "pendiente"));
      const nueva = db.siguienteCompetencia++;
      db.competencias.push({ id: nueva, empezo: ahora(), termino: null });
      Object.assign(db.evento, { competencia_id: nueva, votacion_abierta: true, revelados: 0, total_puestos: 0 });
      if (!db.histPart.some((h) => h.competencia_id === anterior)) db.competencias = db.competencias.filter((c) => c.id !== anterior);
      return null;
    },
    historial(db, p) {
      exigirSesion(db, p.p_clave);
      return db.competencias
        .filter((c) => db.histPart.some((h) => h.competencia_id === c.id))
        .sort((a, b) => b.id - a.id)
        .map((c) => ({
          id: c.id, empezo: c.empezo, termino: c.termino, actual: c.id === db.evento.competencia_id,
          participantes: db.histPart.filter((h) => h.competencia_id === c.id).sort((a, b) => a.puesto - b.puesto || a.turno - b.turno)
            .map(({ turno, nombre, cancion, votos, puesto }) => ({ turno, nombre, cancion, votos, puesto })),
          votos: db.histVotos.filter((h) => h.competencia_id === c.id).sort((a, b) => a.votado_at.localeCompare(b.votado_at))
            .map((h) => ({ votante: h.votante, participante: h.participante, hora: h.votado_at })),
        }));
    },
    guardar_marca(db, p) {
      exigirSesion(db, p.p_clave);
      const m = db.marca;
      m.evento = p.p_evento.trim();
      m.organizador = (p.p_organizador ?? "").trim();
      if (p.p_logo === "") m.logo = null;
      else if (p.p_logo) m.logo = p.p_logo;
      m.color_principal = p.p_color_principal.toLowerCase();
      m.color_destacado = p.p_color_destacado.toLowerCase();
      m.version++;
      return marcaPublica(db);
    },
  };

  // ---------- Avisos entre pestañas (hace las veces de las conexiones en vivo) ----------
  const oyentes = new Set();
  function avisar() {
    oyentes.forEach((f) => f());
  }
  window.addEventListener("storage", (e) => e.key === CLAVE && avisar());

  // ---------- La misma forma que el cliente de Supabase que usa la app ----------
  return {
    async rpc(nombre, params = {}) {
      await pausa();
      const funcion = funciones[nombre];
      if (!funcion) return { data: null, error: { message: `La demo no tiene la función ${nombre}` } };
      const db = leer();
      const antes = JSON.stringify(db);
      try {
        const data = funcion(db, params);
        // Solo se guarda (y se avisa a las otras pestañas) si algo cambió: si no,
        // una consulta avisaría, el aviso dispararía otra consulta, y así sin fin.
        if (JSON.stringify(db) !== antes) guardar(db);
        return { data: data === undefined ? null : JSON.parse(JSON.stringify(data)), error: null };
      } catch (e) {
        return { data: null, error: { message: e.message } };
      }
    },
    from() {
      const consulta = {
        select: () => consulta,
        order: () => consulta,
        then(resolver, rechazar) {
          return pausa().then(() => ({ data: porOrden(leer()), error: null })).then(resolver, rechazar);
        },
      };
      return consulta;
    },
    channel() {
      const canal = {
        on: (_tipo, _filtro, alCambiar) => {
          oyentes.add(alCambiar);
          return canal;
        },
        subscribe: (alEstado) => {
          setTimeout(() => alEstado?.("SUBSCRIBED"), 50);
          return canal;
        },
      };
      return canal;
    },
  };
}

// Aviso de "demo" arriba de todo, con el acceso al otro lado y el botón para empezar de cero.
if (new URLSearchParams(location.search).has("demo")) {
  document.addEventListener("DOMContentLoaded", () => {
    const esAdmin = location.pathname.endsWith("admin.html");
    const aviso = document.createElement("div");
    aviso.className = "banner-demo";
    aviso.innerHTML = esAdmin
      ? '🧪 <strong>Demo</strong> con datos inventados · <a href="./?demo" target="_blank" rel="noopener">Pantalla pública ↗</a> · <button type="button" id="reiniciarDemo">Empezar de cero</button>'
      : '🧪 <strong>Demo</strong> con datos inventados · <a href="admin.html?demo" target="_blank" rel="noopener">Panel de admin ↗</a> <span>(usuario y contraseña: demo)</span>';
    document.body.prepend(aviso);
    document.getElementById("reiniciarDemo")?.addEventListener("click", () => {
      localStorage.removeItem("karaoke_demo_v1");
      localStorage.removeItem("karaoke_marca_demo");
      sessionStorage.clear();
      location.reload();
    });
    if (esAdmin) {
      const usuario = document.getElementById("usuarioInput");
      const clave = document.getElementById("claveInput");
      if (usuario && clave) {
        usuario.value = "demo";
        clave.value = "demo";
      }
    }
  });
}
