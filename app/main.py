"""Colección de pelucos: la web del catálogo de relojes y su API.

Guarda cada reloj como un documento JSON en SQLite (`datos/pelucos.db`) y las fotos como ficheros
(`datos/fotos/<id>`). La página (`static/index.html`) es la misma que se hizo en claude.ai; `static/servidor.js`
le da, con esta API, la función `db` que allí le daba la plataforma. No se dan de alta relojes nuevos desde la web.
"""
import json
import os
import re
import sqlite3
from contextlib import closing
from datetime import datetime, timezone
from pathlib import Path

from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import FileResponse, Response

RAIZ = Path(__file__).resolve().parent.parent
ESTATICOS = RAIZ / "static"
DATOS = Path(os.environ.get("PELUCOS_DATOS", RAIZ / "datos"))
MAX_DOC = 256 * 1024
ID_RELOJ = re.compile(r"^[A-Za-z0-9_-]{1,100}$")
ID_FOTO = re.compile(r"^[0-9a-f]{32}$")
TIPOS = {b"\xff\xd8\xff": "image/jpeg", b"\x89PNG": "image/png", b"RIFF": "image/webp", b"GIF8": "image/gif"}

app = FastAPI(title="Colección de pelucos", docs_url=None, redoc_url=None, openapi_url=None)


def _bd() -> sqlite3.Connection:
    DATOS.mkdir(parents=True, exist_ok=True)
    c = sqlite3.connect(DATOS / "pelucos.db")
    c.execute("PRAGMA journal_mode = WAL")
    c.execute("CREATE TABLE IF NOT EXISTS relojes (id TEXT PRIMARY KEY, datos TEXT NOT NULL, actualizado TEXT NOT NULL)")
    return c


def _fotos() -> Path:
    return DATOS / "fotos"


def _id_valido(id: str) -> str:
    if not ID_RELOJ.match(id):
        raise HTTPException(400, "Identificador de reloj no válido")
    return id


async def _cuerpo(request: Request) -> dict:
    crudo = await request.body()
    if len(crudo) > MAX_DOC:
        raise HTTPException(413, "La ficha es demasiado grande")
    try:
        datos = json.loads(crudo)
    except ValueError:
        raise HTTPException(400, "El cuerpo no es JSON")
    if not isinstance(datos, dict):
        raise HTTPException(400, "La ficha tiene que ser un objeto")
    datos.pop("id", None)
    return datos


def _mezclar(base: dict, cambios: dict) -> dict:
    """Mezcla como el `update` de la plataforma: los objetos se mezclan por dentro; el resto se sustituye."""
    for k, v in cambios.items():
        if isinstance(v, dict) and isinstance(base.get(k), dict):
            base[k] = _mezclar(dict(base[k]), v)
        else:
            base[k] = v
    return base


def _guardar(c: sqlite3.Connection, id: str, datos: dict) -> None:
    ahora = datetime.now(timezone.utc).isoformat()
    c.execute("INSERT INTO relojes (id, datos, actualizado) VALUES (?, ?, ?) "
              "ON CONFLICT(id) DO UPDATE SET datos = excluded.datos, actualizado = excluded.actualizado",
              (id, json.dumps(datos, ensure_ascii=False), ahora))
    c.commit()


@app.get("/")
def pagina():
    return FileResponse(ESTATICOS / "index.html", headers={"Cache-Control": "no-cache"})


@app.get("/servidor.js")
def puente():
    return FileResponse(ESTATICOS / "servidor.js", media_type="text/javascript", headers={"Cache-Control": "no-cache"})


@app.get("/salud")
def salud():
    with closing(_bd()) as c:
        c.execute("SELECT 1").fetchone()
    return {"ok": True}


@app.get("/api/relojes")
def listar():
    with closing(_bd()) as c:
        filas = c.execute("SELECT id, datos FROM relojes ORDER BY id").fetchall()
    return [{**json.loads(d), "id": i} for i, d in filas]


@app.put("/api/relojes/{id}")
async def poner(id: str, request: Request):
    datos = await _cuerpo(request)
    with closing(_bd()) as c:
        _guardar(c, _id_valido(id), datos)
    return {"id": id}


@app.patch("/api/relojes/{id}")
async def cambiar(id: str, request: Request):
    cambios = await _cuerpo(request)
    with closing(_bd()) as c:
        fila = c.execute("SELECT datos FROM relojes WHERE id = ?", (_id_valido(id),)).fetchone()
        if not fila:
            raise HTTPException(404, "Ese reloj no existe")
        _guardar(c, id, _mezclar(json.loads(fila[0]), cambios))
    return {"id": id}


@app.delete("/api/relojes/{id}")
def borrar(id: str):
    with closing(_bd()) as c:
        c.execute("DELETE FROM relojes WHERE id = ?", (_id_valido(id),))
        c.commit()
    return Response(status_code=204)


@app.get("/_blob/{id}")
def foto(id: str):
    ruta = _fotos() / id
    if not ID_FOTO.match(id) or not ruta.is_file():
        raise HTTPException(404, "No existe esa foto")
    with open(ruta, "rb") as f:
        cabecera = f.read(4)
    tipo = next((t for m, t in TIPOS.items() if cabecera.startswith(m)), "application/octet-stream")
    return FileResponse(ruta, media_type=tipo, headers={"Cache-Control": "private, max-age=31536000, immutable"})
