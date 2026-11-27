# Colección de pelucos

Catálogo privado de los relojes de la familia: qué es cada uno, cuánto vale (oculto hasta que se pide), si es para
colección o para usar, y qué hay que hacerle para ponerlo a punto.

Corre en el servidor (eloydev) y solo se ve desde la tailnet: **https://eloydev.taildf0e61.ts.net:10000**.
Este repo solo tiene el código. Las fichas y las fotos están únicamente en el servidor (`~/pelucos/datos`) y entran en
la copia diaria del servidor (`copia-servidor`).

## Cómo está hecho

| Fichero | Qué hace |
|---|---|
| `app/main.py` | FastAPI: sirve la página y la API. Fichas en SQLite (`datos/pelucos.db`, un JSON por reloj), fotos en `datos/fotos/<id>` |
| `static/index.html` | La página (la misma que se hizo como artifact en claude.ai) |
| `static/servidor.js` | Le da a la página, con la API, la función `db` que allí le daba claude.ai |
| `scripts/instalar.sh` | Instala o actualiza todo como eloy: clon en `~/pelucos`, servicio de usuario, despliegue automático y `tailscale serve` |
| `scripts/desplegar.sh` | Lo lanza `pelucos-github.timer` cada 5 min: tests → copia de la BD → avance → reinicio → `/salud` → vuelta atrás si falla |

API: `GET /api/relojes`, `PUT|PATCH|DELETE /api/relojes/<id>`, `GET /_blob/<id>` (fotos), `GET /salud`.

Desde la web se ven las fichas, se editan sus datos y tareas y se elige si cada reloj cuenta en el valor total; no se dan
de alta relojes ni se suben fotos. Un reloj nuevo se mete a mano: su foto en `datos/fotos/<id de 32 hex>` y su ficha
con `PUT /api/relojes/<id>`.

## Desplegar

Llegar a `main` de GitHub es desplegar (como finanzas y jarvis). Logs:
`sudo -u eloy XDG_RUNTIME_DIR=/run/user/$(id -u eloy) journalctl --user -u pelucos -u pelucos-github`.

## Desarrollo

```
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
.venv/bin/python -m pytest -q
PELUCOS_DATOS=/tmp/pelucos .venv/bin/uvicorn app.main:app --port 8100
```
