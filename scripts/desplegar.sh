#!/usr/bin/env bash
# Despliegue continuo de pelucos, con el mismo esquema que jarvis y finanzas: si main de GitHub tiene un commit nuevo,
# lo prueba y lo aplica. Lo lanza cada 5 min pelucos-github.timer, como eloy (servicio de usuario: no hace falta
# root). Se ejecuta la copia instalada en ~/.local/lib/pelucos (scripts/instalar.sh); tras cada despliegue bueno se
# renueva desde el repo.
#
# Pasos: fetch → tests del commit nuevo en una copia aparte → copia de la BD → avance de ~/pelucos (clon normal) →
# reinicio → comprobación (/salud). Si fallan los tests no se toca nada; si la web no arranca, se vuelve al commit
# anterior y a la BD de antes. Un commit que falla queda apuntado (~/.local/state/pelucos/fallido) y no se reintenta
# hasta que llegue otro.
set -euo pipefail
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
APP="${PELUCOS_APP:-$HOME/pelucos}"
ESTADO="${PELUCOS_ESTADO:-$HOME/.local/state/pelucos}"
SERVICIO="${PELUCOS_SERVICIO:-pelucos}"
PUERTO="${PELUCOS_PUERTO:-8100}"
BD="$APP/datos/pelucos.db"
mkdir -p "$ESTADO"
g() { git -C "$APP" "$@"; }

g fetch -q origin main
actual=$(g rev-parse HEAD)
nuevo=$(g rev-parse origin/main)
[[ "$actual" == "$nuevo" ]] && exit 0
[[ "$(cat "$ESTADO/fallido" 2>/dev/null)" == "$nuevo" ]] && exit 0  # ya falló: se espera al siguiente
if ! g merge-base --is-ancestor "$actual" "$nuevo"; then
  echo "!! $(g log --oneline -1 "$actual") no está en main de GitHub: no despliego encima"
  exit 1
fi
echo "==> Nuevo commit: $(g log --oneline -1 "$nuevo")"

fallo() {
  echo "$nuevo" > "$ESTADO/fallido"
  echo "!! NO DESPLEGADO: $1"
  exit 1
}

# 1) Tests en una copia aparte. Si cambian las dependencias, en un entorno nuevo: el de producción no se toca hasta
#    que los tests pasan.
tmp=$(mktemp -d)
trap 'g worktree remove --force "$tmp/codigo" >/dev/null 2>&1 || true; rm -rf "$tmp"' EXIT
g worktree add -q --detach "$tmp/codigo" "$nuevo"
python="$APP/.venv/bin/python"
deps_cambian=""
g diff --quiet "$actual" "$nuevo" -- requirements.txt || deps_cambian=1
if [[ -n "$deps_cambian" ]]; then
  python3 -m venv "$tmp/venv"
  "$tmp/venv/bin/pip" install -q -r "$tmp/codigo/requirements.txt" || fallo "pip install"
  python="$tmp/venv/bin/python"
fi
(cd "$tmp/codigo" && "$python" -m pytest -q -p no:cacheprovider) || fallo "fallan los tests"

# 2) Copia de la BD (API de backup de SQLite: consistente aunque la web esté escribiendo), por si el commit nuevo la
#    estropea al arrancar. Las fotos no se tocan en un despliegue.
if [[ -f "$BD" ]]; then
  python3 - "$BD" "$ESTADO/antes-despliegue.db" <<'PY' || fallo "no he podido copiar la BD"
import os, sqlite3, sys
os.umask(0o077)
o, c = sqlite3.connect(sys.argv[1]), sqlite3.connect(sys.argv[2] + ".tmp")
o.backup(c); c.execute("PRAGMA journal_mode = DELETE"); c.close(); o.close()
os.replace(sys.argv[2] + ".tmp", sys.argv[2])
PY
fi

# 3) Avanzar el código (reset: los ficheros borrados en el commit también desaparecen) y reiniciar
[[ -z "$(g status --porcelain --untracked-files=no)" ]] || fallo "~/pelucos tiene cambios locales (git status)"
[[ -n "$deps_cambian" ]] && { "$APP/.venv/bin/pip" install -q -r "$tmp/codigo/requirements.txt" || fallo "pip install en producción"; }
g reset -q --hard "$nuevo"
systemctl --user restart "$SERVICIO"

# 4) Comprobar que responde; si no, volver atrás (código y BD)
ok=""
for _ in $(seq 1 15); do
  sleep 2
  [[ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PUERTO/salud" || true)" == 200 ]] && { ok=1; break; }
done
if [[ -z "$ok" ]]; then
  journalctl --user -u "$SERVICIO" -n 20 --no-pager || true
  systemctl --user stop "$SERVICIO"
  if [[ -f "$ESTADO/antes-despliegue.db" ]]; then
    rm -f "$BD-wal" "$BD-shm"
    cp "$ESTADO/antes-despliegue.db" "$BD.restaurando" && mv -f "$BD.restaurando" "$BD"
  fi
  g reset -q --hard "$actual"
  systemctl --user start "$SERVICIO"
  fallo "la web no arranca con el commit nuevo; vuelta a $(g log --oneline -1 "$actual") y a la BD de antes"
fi
rm -f "$ESTADO/fallido"
# La copia instalada de este script sigue al repo
install -D -m 755 "$APP/scripts/desplegar.sh" "$HOME/.local/lib/pelucos/desplegar.sh"
echo "==> Desplegado: $(g log --oneline -1 HEAD)"
