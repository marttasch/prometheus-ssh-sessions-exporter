#!/usr/bin/env bash
set -euo pipefail


# install.sh - idempotenter Installer fürs Repo
# Usage:
# sudo ./install.sh # full install (first time)
# sudo ./install.sh update # nur python file kopieren und Service neu starten


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
REQUIREMENTS_FILE="prometheus_requirements.txt"


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


# Full install
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


# create venv and install deps
if [ ! -d "$VENV_DIR" ]; then
echo "-> Erstelle Python venv in $VENV_DIR"
/usr/bin/python3 -m venv "$VENV_DIR"
chown -R "$INSTALL_USER":"$INSTALL_USER" "$VENV_DIR"
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
echo "Update workflow: git pull && sudo ./install.sh update"
