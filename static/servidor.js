// Puente entre la página (hecha para claude.ai) y la API de este servidor.
// La página pide sus funciones con `claude.use(nombre)`; aquí se dan `db` (las fichas, en /api/relojes) y `assets`
// (las fotos, en /api/fotos). El resto (`sample`, el análisis con Claude) no existe en el servidor: devuelve null y la
// página oculta ese botón.
(() => {
  const oyentes = new Set();
  let ultimo = null;

  async function pedir(metodo, url, cuerpo) {
    const r = await fetch(url, {
      method: metodo,
      headers: cuerpo && !(cuerpo instanceof FormData) ? { "Content-Type": "application/json" } : undefined,
      body: cuerpo instanceof FormData ? cuerpo : cuerpo ? JSON.stringify(cuerpo) : undefined,
    });
    if (!r.ok) {
      let msg = r.statusText;
      try { msg = (await r.json()).detail || msg; } catch {}
      throw { code: r.status === 404 ? "invalid_argument" : "unavailable", message: msg };
    }
    return r.status === 204 ? null : r.json();
  }

  async function refrescar() {
    try {
      const lista = await pedir("GET", "/api/relojes");
      ultimo = { docs: lista.map((d) => ({ id: d.id, exists: true, data: () => d, metadata: { fromCache: false, hasPendingWrites: false } })),
        size: lista.length, empty: !lista.length, metadata: { fromCache: false, hasPendingWrites: false } };
      for (const o of oyentes) o.next(ultimo);
    } catch (e) {
      for (const o of oyentes) o.error?.(e);
    }
  }
  setInterval(() => { if (oyentes.size && document.visibilityState === "visible") refrescar(); }, 30000);
  document.addEventListener("visibilitychange", () => { if (document.visibilityState === "visible" && oyentes.size) refrescar(); });

  const nuevoId = () => Array.from(crypto.getRandomValues(new Uint8Array(10)), (b) => b.toString(16).padStart(2, "0")).join("");
  const url = (id) => "/api/relojes/" + encodeURIComponent(id);
  const tras = (p) => p.then((x) => { refrescar(); return x; });

  function documento(id) {
    return {
      id,
      path: "relojes/" + id,
      set: (datos) => tras(pedir("PUT", url(id), datos)),
      update: (datos) => tras(pedir("PATCH", url(id), datos)),
      delete: () => tras(pedir("DELETE", url(id))),
    };
  }

  const db = {
    collection: (ruta) => {
      if (ruta !== "relojes") throw new TypeError("Solo existe la colección «relojes»");
      return {
        doc: (id) => documento(id || nuevoId()),
        onSnapshot(next, error) {
          const o = { next, error };
          oyentes.add(o);
          if (ultimo) setTimeout(() => next(ultimo)); else refrescar();
          return () => oyentes.delete(o);
        },
      };
    },
    doc: (ruta) => {
      const [col, id] = String(ruta).split("/");
      if (col !== "relojes" || !id) throw new TypeError("Ruta de ficha no válida: " + ruta);
      return documento(id);
    },
  };

  const assets = {
    async upload(blob) {
      const fd = new FormData();
      fd.append("foto", blob, "foto");
      return pedir("POST", "/api/fotos", fd);
    },
  };

  window.claude = { use: async (nombre) => ({ db, assets }[nombre] ?? null) };
})();
