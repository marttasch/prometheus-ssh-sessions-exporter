# SSH Sessions Prometheus Exporter

A small exporter that parses the output of `w` on a Raspberry Pi and exposes active SSH session information as Prometheus metrics.
Useful to detect unexpected/unauthorised logins (counts, client IPs, TTYs, login times, command names, idle/JCPU/PCPU).

---

## What it provides

**Metrics**

* `ssh_sessions_total` — Gauge: number of active sessions.
* `ssh_session_info{user, tty, from, login, idle, jcpu, pcpu, what}` — Gauge (=1) per active session with identifying labels:

**Why**

* Quick, low-effort way to monitor who is currently logged in over SSH.
* Labels make it easy to alert on sessions from unexpected IP ranges or outside working hours.

---

## Repository layout (important files)

```
ssh-sessions-exporter/
├─ ssh_sessions_prometheus.py     # main exporter (edit this file in repo)
├─ install.sh                     # installer / updater (run with sudo)
├─ prometheus_requirements.txt    # python deps: prometheus_client
├─ ssh_sessions_exporter.service.template
├─ README.md
├─ .gitignore
```

---

## Installation

On your Raspberry Pi (assumes Debian-based OS):

```bash
# clone your repo
git clone <your-repo-url>
cd ssh-sessions-exporter

# run installer as root
sudo ./install.sh
```

What `install.sh` does:

* installs `procps` if `w` is missing,
* copies `ssh_sessions_prometheus.py` to `/opt/ssh_sessions/`,
* creates a Python venv in `/opt/ssh_sessions/venv` and installs `prometheus_client`,
* writes a systemd service `/etc/systemd/system/ssh_sessions_exporter.service`,
* enables & starts the service,
* opens port 9122 via `ufw` if `ufw` is installed.

Test locally:

```bash
# metrics endpoint
curl http://localhost:9122/metrics | head -n 40

# service status / logs
sudo systemctl status ssh_sessions_exporter.service
sudo journalctl -u ssh_sessions_exporter.service -f
```

Update workflow after changing `ssh_sessions_prometheus.py` in the repo:

```bash
# on the PI in the repo directory:
git pull
sudo ./install.sh update
```

---

## Configuration (runtime)

The Python script reads optional environment variables (also set by the service unit):

* `PORT` — HTTP port for metrics (default `9122`)
* `POLL_INTERVAL` — poll interval in seconds (default `15`)
* `LOG_LEVEL` — `DEBUG`/`INFO` (default `INFO`)

The service file created by `install.sh` sets these values via `Environment=` lines.

---

## Prometheus scrape config (example)

Add a scrape job to your `prometheus.yml`:

```yaml
scrape_configs:
  - job_name: 'raspi-ssh-sessions'
    static_configs:
      - targets: ['raspberrypi.local:9122']  # or '192.168.2.123:9122'
```

After updating Prometheus config, reload or restart Prometheus.
