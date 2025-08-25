#!/usr/bin/env python3
"""
ssh_sessions_prometheus.py

Auf einem Raspberry Pi in regelmäßigen Abständen (default 15s) werden aktive Sessions
aus dem Kommando `w` geparst und als Prometheus-Metriken auf Port 9122 exponiert.

Metriken:
- ssh_sessions_total   (Gauge) Anzahl gefundener Sessions (integer)
- ssh_session_info{user,tty,from,login,idle,jcpu,pcpu,what} = 1   (Gauge, 1 = aktiv)

Installation:
  pip3 install prometheus_client

Start:
  python3 ssh_sessions_prometheus.py

Empfehlung: Als systemd-service laufen lassen.

Hinweis:
- Das Script nimmt an, dass die Ausgabe von `w` das Standardformat hat.
- "WHAT"-Spalte kann Leerzeichen enthalten — wird korrekt als letztes Feld geparst.
"""

from __future__ import annotations
import subprocess
import time
import logging
import threading
from typing import List, Dict, Tuple, Set

from prometheus_client import start_http_server, Gauge

# --- Konfiguration ---
POLL_INTERVAL = 15.0  # Sekunden
EXPORT_PORT = 9122

# Labels: Reihenfolge muss konsistent sein (wird beim Entfernen verwendet)
LABEL_NAMES = ["user", "tty", "from", "login", "idle", "jcpu", "pcpu", "what"]

# Metriken
SSH_SESSION_GAUGE = Gauge(
    "ssh_session_info",
    "Info metric for each active session (value = 1). Labels: user, tty, from, login, idle, jcpu, pcpu, what",
    LABEL_NAMES,
)

SSH_TOTAL_GAUGE = Gauge(
    "ssh_sessions_total",
    "Number of active sessions discovered from `w` output",
)

# Interner Zustand: vorherige Label-Kombinationen, um veraltete Serien zu entfernen
_previous_labelsets_lock = threading.Lock()
_previous_labelsets: Set[Tuple[str, ...]] = set()

# Logging
logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
logger = logging.getLogger("ssh_sessions_exporter")


def run_w() -> str:
    """Führt `w` aus und gibt die rohe Ausgabe als String zurück."""
    try:
        out = subprocess.check_output(["w"], stderr=subprocess.STDOUT)
        return out.decode(errors="replace")
    except subprocess.CalledProcessError as e:
        logger.error("Fehler beim Aufruf von 'w': %s", e)
        return ""
    except FileNotFoundError:
        logger.error("Kommando 'w' nicht gefunden. Bitte installieren oder PATH anpassen.")
        return ""


def parse_w_output(output: str) -> List[Dict[str, str]]:
    """Parst die Ausgabe von `w` und gibt eine Liste von Session-Dictionaries zurück.

    Erwartetes Format (Beispiel):
    USER     TTY      FROM             LOGIN@   IDLE   JCPU   PCPU WHAT
    pi       pts/2    192.168.2.132    11:19   31:55   0.13s  0.13s -bash

    Wir splitten jede Zeile mit maxsplit=6, sodass die letzte Spalte (WHAT) auch Leerzeichen
    enthalten darf.
    """
    sessions: List[Dict[str, str]] = []
    if not output:
        return sessions

    lines = output.strip().splitlines()
    if len(lines) < 2:
        return sessions

    # Suche die Header-Zeile: Normalerweise die zweite Zeile, aber wir suchen robust.
    header_idx = None
    for i, ln in enumerate(lines[:4]):
        if ln.strip().startswith("USER") and "WHAT" in ln:
            header_idx = i
            break
    if header_idx is None:
        # fallback: nehme die erste Zeile als Header (unschön, aber robust)
        header_idx = 0

    # Nutzerzeilen beginnen nach header_idx
    data_lines = lines[header_idx + 1 :]

    for ln in data_lines:
        if not ln.strip():
            continue
        parts = ln.split(None, 6)  # höchstens 7 Teile; letztes ist WHAT (ggf. mit spaces)
        if len(parts) < 7:
            # Falls weniger Teile, fülle fehlende Felder mit leeren Strings
            parts = (parts + [""] * 7)[:7]
        user, tty, frm, login_at, idle, jcpu, pcpu_what = parts[0], parts[1], parts[2], parts[3], parts[4], parts[5], parts[6]

        # pcpuausgabe kann manchmal "0.13s  0.13s -bash" sein -> wir erwarten pcpu und what getrennt
        # Versuche, pcpu_what in pcpu und what zu splitten: pcpu ist meist ein einzelnes Token ohne spaces.
        pcpu = ""
        what = ""
        # Wenn pcpu_what anfängt mit '-' oder /bin/... dann ist pcpu leer
        # Versuche ein robustes split: split einmal auf erstes Vorkommen von ' ' falls möglich
        if pcpu_what:
            subparts = pcpu_what.split(None, 1)
            if len(subparts) == 1:
                # nur ein Feld übrig -> nehmen wir als 'what'
                pcpu = ""
                what = subparts[0]
            else:
                pcpu, what = subparts[0], subparts[1]
        # Sanitizing: kürzen Labels, damit Prometheus nicht übermäßig große Label-Werte erhält
        def _san(val: str) -> str:
            if val is None:
                return ""
            s = str(val).strip()
            if len(s) > 200:
                return s[:200]
            return s

        session = {
            "user": _san(user),
            "tty": _san(tty),
            "from": _san(frm),
            "login": _san(login_at),
            "idle": _san(idle),
            "jcpu": _san(jcpu),
            "pcpu": _san(pcpu),
            "what": _san(what),
        }
        sessions.append(session)

    return sessions


def update_metrics(sessions: List[Dict[str, str]]):
    """Aktualisiert die Prometheus-Metriken basierend auf der aktuellen Session-Liste."""
    global _previous_labelsets

    new_labelsets: Set[Tuple[str, ...]] = set()
    for s in sessions:
        labeltuple = (
            s.get("user", ""),
            s.get("tty", ""),
            s.get("from", ""),
            s.get("login", ""),
            s.get("idle", ""),
            s.get("jcpu", ""),
            s.get("pcpu", ""),
            s.get("what", ""),
        )
        new_labelsets.add(labeltuple)

    # Setze/erstelle aktuelle label-series
    for lbls in new_labelsets:
        try:
            SSH_SESSION_GAUGE.labels(*lbls).set(1)
        except Exception as e:
            logger.exception("Fehler beim Setzen der Metrik für Labels %s: %s", lbls, e)

    # Entferne alte Serien, die nicht mehr aktiv sind
    with _previous_labelsets_lock:
        removed = _previous_labelsets - new_labelsets
        for lbls in removed:
            try:
                SSH_SESSION_GAUGE.remove(*lbls)
            except KeyError:
                # falls die Serie bereits nicht existiert
                pass
            except Exception:
                logger.exception("Fehler beim Entfernen alter Metrik-Serie %s", lbls)

        _previous_labelsets = new_labelsets

    # Aktualisiere Gesamtsumme
    SSH_TOTAL_GAUGE.set(len(sessions))


def poll_loop(stop_event: threading.Event):
    """Hauptschleife, die `w` ausliest, parst und Metriken aktualisiert."""
    logger.info("Starte Poll-Loop (Intervall: %ss)", POLL_INTERVAL)
    while not stop_event.is_set():
        try:
            out = run_w()
            sessions = parse_w_output(out)
            update_metrics(sessions)
            logger.debug("Gefundene Sessions: %d", len(sessions))
        except Exception:
            logger.exception("Fehler in der Poll-Loop")
        # warte mit Event, damit wir sauber abbrechen können
        stop_event.wait(POLL_INTERVAL)


def main():
    logger.info("Starte SSH Sessions Prometheus Exporter auf Port %d", EXPORT_PORT)
    start_http_server(EXPORT_PORT)
    stop_event = threading.Event()
    worker = threading.Thread(target=poll_loop, args=(stop_event,), daemon=True)
    worker.start()

    try:
        # Hauptthread wartet unendlich; beenden mit Ctrl-C
        while True:
            time.sleep(3600)
    except KeyboardInterrupt:
        logger.info("Beende Exporter...")
        stop_event.set()
        worker.join(timeout=5)


if __name__ == "__main__":
    main()
