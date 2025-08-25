#!/usr/bin/env bash
set -euo pipefail

# install.sh - robust installer
# Usage:
#   sudo ./install.sh
#   sudo ./install.sh update

INSTALL_USER="${INSTALL_USER:-${SUDO_USER:-pi}}"
INSTALL_DIR="${INSTALL_DIR:-/opt/ssh_sessions}"
PORT="${PORT:-9122}"
POLL_INTERVAL="${POLL_INTERVAL:-15}"
VENV_DIR="$INSTALL_DIR/venv"
SCRIPT_NAME="ssh_sessions_prometheus.py"
SCRIPT_SRC="$(pwd)/$SCRIPT_NAME"
SCRIPT_DST="$INSTALL_DIR/$SCRIPT_NAME"
SERVICE_NAME="ssh_sessions_exporter.service"
SERVICE_PATH="/etc/systemd/system/$SERVICE_NAME"
REQUIREMENTS_FILE="requirements.txt"

if [ "$(id -u)" -ne 0 ]; then
  echo "Dieses Script muss mit root-Rechten ausgeführt werden. Nutze: sudo ./install.sh"
  exit 1
fi

CMD=${1:-install}

if [ "$CMD" = "update" ]; then
  echo "-> Update: Kopiere ${SCRIPT_NAME} und starte Service neu"
  mkdir -p "$INSTALL_DIR"
  chown "$INSTALL_USER":"$INSTALL_USER" "$INSTALL_DIR"
  cp "$SCRIPT_SRC" "$SCRIPT_DST"
  chown "$INSTALL_USER":"$INSTALL_USER" "$SCRIPT_DST"
  chmod 755 "$SCRIPT_DST"
  systemctl restart $SERVICE_NAME
  echo "-> Update fertig. Service neu gestartet."
  exit 0
fi

echo "-> Erstelle Installationsverzeichnis: $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
chown "$INSTALL_USER":"$INSTALL_USER" "$INSTALL_DIR"
chmod 755 "$INSTALL_DIR"

# ensure 'w' exists
if ! command -v w >/dev/null 2>&1; then
  echo "-> 'w' nicht gefunden. Installiere procps..."
  apt-get update
  apt-get install -y procps
fi

# copy python script
if [ -f "$SCRIPT_DST" ]; then
  echo "-> Backup vorhandener Script-Datei"
  mv "$SCRIPT_DST" "$SCRIPT_DST.bak.$(date +%s)"
fi
cp "$SCRIPT_SRC" "$SCRIPT_DST"
chown "$INSTALL_USER":"$INSTALL_USER" "$SCRIPT_DST"
chmod 755 "$SCRIPT_DST"

# Ensure python3-venv present
if ! python3 -c "import venv" >/dev/null 2>&1; then
  echo "-> python3-venv/venv module nicht vorhanden. Installiere python3-venv..."
  apt-get update
  apt-get install -y python3-venv
fi

# create venv if not exists or recreate if broken
if [ ! -d "$VENV_DIR" ] || [ ! -x "$VENV_DIR/bin/pip" ]; then
  echo "-> (Re-)Erstelle Python venv in $VENV_DIR"
  /usr/bin/python3 -m venv "$VENV_DIR"
  chown -R "$INSTALL_USER":"$INSTALL_USER" "$VENV_DIR"
fi

# verify pip binary exists
if [ ! -x "$VENV_DIR/bin/pip" ]; then
  echo "-> pip in venv fehlt. Versuche ensurepip..."
  /usr/bin/python3 -m ensurepip --upgrade || true
  /usr/bin/python3 -m pip install --upgrade pip
  # recreate venv as fallback
  /usr/bin/python3 -m venv --clear "$VENV_DIR"
fi

if [ ! -x "$VENV_DIR/bin/pip" ]; then
  echo "Fehler: pip in venv konnte nicht installiert werden. Bitte prüfe python3-venv Installation."
  exit 1
fi

echo "-> Installiere Python Abhängigkeiten"
"$VENV_DIR/bin/pip" install --upgrade pip
"$VENV_DIR/bin/pip" install -r "$REQUIREMENTS_FILE"

# write systemd service
if [ -f "$SERVICE_PATH" ]; then
  echo "-> Backup vorhandene Service-Datei"
  mv "$SERVICE_PATH" "$SERVICE_PATH.bak.$(date +%s)"
fi

cat > "$SERVICE_PATH" <<SERVICE
[Unit]
Description=SSH Sessions Prometheus Exporter
After=network.target

[Service]
Type=simple
User=$INSTALL_USER
WorkingDirectory=$INSTALL_DIR
Environment=PORT=$PORT
Environment=POLL_INTERVAL=$POLL_INTERVAL
ExecStart=$VENV_DIR/bin/python $SCRIPT_DST
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SERVICE

# systemd reload + enable/start
systemctl daemon-reload
systemctl enable $SERVICE_NAME
systemctl restart $SERVICE_NAME

# ufw open port if ufw exists
if command -v ufw >/dev/null 2>&1; then
  echo "-> ufw vorhanden: erlaube Port $PORT/tcp"
  ufw allow "$PORT"/tcp || true
fi

echo
echo "== Installation abgeschlossen =="
systemctl status $SERVICE_NAME --no-pager || true
echo
echo "Metrics (lokal): curl http://localhost:$PORT/metrics | head -n 30"
echo
echo "Update workflow: git pull && sudo ./install.sh update"
