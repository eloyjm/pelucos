#!/usr/bin/env bash
# Instala (o actualiza) pelucos en el servidor, como eloy: el código en ~/pelucos (clon de GitHub), el servicio de
# usuario, el despliegue automático desde main de GitHub (pelucos-github.timer, cada 5 min) y la publicación en la
# tailnet. Se puede repetir.
#
#   scripts/instalar.sh [URL de GitHub]   (por defecto, la de origin de este repo)
#
# Solo hace falta root para dos cosas, que se piden con sudo si no están ya: `loginctl enable-linger` (los servicios de
# usuario siguen en marcha sin sesión abierta) y `tailscale serve` (https://<servidor>:10000 → 127.0.0.1:8100).
set -euo pipefail
cd "$(dirname "$0")/.."
URL="${1:-$(git remote get-url origin)}"
APP="$HOME/pelucos"
LIB="$HOME/.local/lib/pelucos"
UNIDADES="$HOME/.config/systemd/user"
PUERTO=8100
PUERTO_TAILNET=10000
export XDG_RUNTIME_DIR="/run/user/$(id -u)"

echo "==> Código en $APP (clon de $URL)"
[[ -d "$APP/.git" ]] || git clone -q "$URL" "$APP"
[[ -d "$APP/.venv" ]] || python3 -m venv "$APP/.venv"
"$APP/.venv/bin/pip" install -q -r "$APP/requirements.txt"
mkdir -p "$APP/datos/fotos" && chmod 700 "$APP/datos"

echo "==> Copia instalada en $LIB (un despliegue roto no la rompe; cada despliegue bueno la renueva)"
install -D -m 755 "$APP/scripts/desplegar.sh" "$LIB/desplegar.sh"

echo "==> Unidades systemd de usuario"
mkdir -p "$UNIDADES"
cat > "$UNIDADES/pelucos.service" <<EOF
[Unit]
Description=Colección de pelucos (web del catálogo de relojes)
After=network-online.target

[Service]
WorkingDirectory=%h/pelucos
Environment=PYTHONUNBUFFERED=1
# Solo escucha en el propio equipo: desde fuera se entra por Tailscale (tailscale serve), con HTTPS
ExecStart=%h/pelucos/.venv/bin/uvicorn app.main:app --host 127.0.0.1 --port $PUERTO --proxy-headers --forwarded-allow-ips 127.0.0.1
Restart=always
RestartSec=5
UMask=0077
MemoryMax=200M

[Install]
WantedBy=default.target
EOF
cat > "$UNIDADES/pelucos-github.service" <<'EOF'
[Unit]
Description=Pelucos: desplegar main de GitHub si hay un commit nuevo
After=network-online.target

[Service]
Type=oneshot
ExecStart=%h/.local/lib/pelucos/desplegar.sh
EOF
cat > "$UNIDADES/pelucos-github.timer" <<'EOF'
[Unit]
Description=Mirar main de GitHub de pelucos cada 5 min

[Timer]
OnBootSec=4min
OnUnitActiveSec=5min
AccuracySec=20s

[Install]
WantedBy=timers.target
EOF
loginctl show-user "$USER" -p Linger --value 2>/dev/null | grep -qx yes || sudo loginctl enable-linger "$USER"
systemctl --user daemon-reload
systemctl --user enable --quiet pelucos.service
systemctl --user restart pelucos.service
systemctl --user enable --now --quiet pelucos-github.timer
for _ in $(seq 1 15); do
  sleep 1
  curl -fsS -o /dev/null "http://127.0.0.1:$PUERTO/salud" && break
done
curl -fsS -o /dev/null "http://127.0.0.1:$PUERTO/salud" || { echo "La web no responde: journalctl --user -u pelucos -n 50" >&2; exit 1; }
echo "    En marcha en http://127.0.0.1:$PUERTO"

echo "==> Tailscale (https, solo dentro de la tailnet)"
if tailscale serve status 2>/dev/null | grep -q ":$PUERTO_TAILNET "; then
  echo "    Ya publicado."
else
  sudo tailscale serve --bg --https=$PUERTO_TAILNET "http://127.0.0.1:$PUERTO"
fi
nombre=$(tailscale status --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))')
echo "==> Listo: https://$nombre:$PUERTO_TAILNET   ·   Logs: journalctl --user -u pelucos -u pelucos-github"
