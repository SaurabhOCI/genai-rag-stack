#!/bin/bash
# cloudinit.sh — Oracle 23ai Free + GenAI stack bootstrap
# Fix: install Podman first, then start DB unit; DB script uses absolute podman path.

set -Eeuo pipefail

LOGFILE="/var/log/genai_setup.log"
exec > >(tee -a "$LOGFILE") 2>&1
echo "===== GenAI OneClick: start $(date -u) ====="

# --------------------------------------------------------------------
# Grow filesystem (best-effort)
# --------------------------------------------------------------------
if command -v /usr/libexec/oci-growfs >/dev/null 2>&1; then
  /usr/libexec/oci-growfs -y || true
fi

# --------------------------------------------------------------------
# MINIMAL PRE-INSTALL (so DB unit can run): Podman + basics
# --------------------------------------------------------------------
echo "[PRE] installing Podman and basics so DB unit can run"
dnf -y install dnf-plugins-core || true
dnf config-manager --set-enabled ol8_addons || true
dnf -y makecache --refresh || true
dnf -y install podman curl grep coreutils shadow-utils || true
# sanity
/usr/bin/podman --version || { echo "[PRE] podman missing"; exit 1; }

# --------------------------------------------------------------------
# DB bootstrap script: /usr/local/bin/genai-db.sh
#   - starts container
#   - waits for first boot
#   - opens FREEPDB1 + SAVE STATE
#   - waits for FREEPDB1 in listener
#   - (optional) creates vector/vector
# --------------------------------------------------------------------
cat >/usr/local/bin/genai-db.sh <<'DBSCR'
#!/bin/bash
set -Eeuo pipefail

PODMAN="/usr/bin/podman"
log(){ echo "[DB] $*"; }
retry() { local t=${1:-5}; shift; local n=1; until "$@"; do local rc=$?;
  if (( n>=t )); then return "$rc"; fi
  log "retry $n/$t (rc=$rc): $*"; sleep $((n*5)); ((n++));
done; }

# Keep ONE password here (as requested)
ORACLE_PWD="database123"
ORACLE_PDB="FREEPDB1"
ORADATA_DIR="/home/opc/oradata"
IMAGE="container-registry.oracle.com/database/free:latest"
NAME="23ai"

log "start $(date -u)"

# Data dir & perms for oracle uid 54321
mkdir -p "$ORADATA_DIR" && chown -R 54321:54321 "$ORADATA_DIR" || true

# Pull (best-effort) and remove stale container
retry 5 "$PODMAN" pull "$IMAGE" || true
"$PODMAN" rm -f "$NAME" || true

# Launch DB (host networking so 127.0.0.1:1521 works)
retry 5 "$PODMAN" run -d --name "$NAME" --network=host \
  -e ORACLE_PWD="$ORACLE_PWD" \
  -e ORACLE_PDB="$ORACLE_PDB" \
  -e ORACLE_MEMORY='2048' \
  -v "$ORADATA_DIR":/opt/oracle/oradata:z \
  "$IMAGE"

# Wait for first-boot marker
log "waiting for 'DATABASE IS READY TO USE!'"
for i in {1..144}; do
  "$PODMAN" logs "$NAME" 2>&1 | grep -q 'DATABASE IS READY TO USE!' && break
  sleep 5
done

# Open FREEPDB1 & SAVE STATE using TCP login to CDB service "FREE"
log "opening PDB and saving state..."
"$PODMAN" exec -e ORACLE_PWD="$ORACLE_PWD" -i "$NAME" bash -lc '
  . /home/oracle/.bashrc
  sqlplus -S -L /nolog <<SQL
  CONNECT sys/${ORACLE_PWD}@127.0.0.1:1521/FREE AS SYSDBA
  WHENEVER SQLERROR EXIT SQL.SQLCODE
  ALTER PLUGGABLE DATABASE FREEPDB1 OPEN;
  ALTER PLUGGABLE DATABASE FREEPDB1 SAVE STATE;
  ALTER SYSTEM REGISTER;
  EXIT
SQL
' || log "WARN: open/save state returned non-zero (may already be open)"

# Wait until listener publishes FREEPDB1
log "waiting for listener to publish FREEPDB1..."
for i in {1..60}; do
  "$PODMAN" exec -i "$NAME" bash -lc '. /home/oracle/.bashrc; lsnrctl status' \
    | grep -qi 'Service "FREEPDB1"' && { log "FREEPDB1 registered"; break; }
  sleep 3
done

# (Optional) Create app user idempotently
log "creating PDB user 'vector' (idempotent)"
"$PODMAN" exec -e ORACLE_PWD="$ORACLE_PWD" -i "$NAME" bash -lc '
  . /home/oracle/.bashrc
  sqlplus -S -L /nolog <<SQL
  CONNECT sys/${ORACLE_PWD}@127.0.0.1:1521/FREEPDB1 AS SYSDBA
  DECLARE v_count number; BEGIN
    SELECT COUNT(*) INTO v_count FROM dba_users WHERE username = ''VECTOR'';
    IF v_count = 0 THEN
      EXECUTE IMMEDIATE q''[CREATE USER vector IDENTIFIED BY vector]'';
      EXECUTE IMMEDIATE q''[GRANT CREATE SESSION, CREATE TABLE, CREATE SEQUENCE, CREATE VIEW TO vector]'';
      EXECUTE IMMEDIATE q''[ALTER USER vector QUOTA UNLIMITED ON USERS]'';
    END IF;
  END;
  /
  EXIT
SQL
' || log "WARN: vector user create step returned non-zero"

log "done $(date -u)"
DBSCR
chmod +x /usr/local/bin/genai-db.sh

# --------------------------------------------------------------------
# Main setup script (your app deps etc.) — runs AFTER DB unit
#  - also includes a user script that waits for container existence
# --------------------------------------------------------------------
cat >/usr/local/bin/genai-setup.sh <<'SCRIPT'
#!/bin/bash
set -Eeuo pipefail
echo "===== GenAI OneClick setup: start $(date -u) ====="

# You can add fuller provisioning here; keep minimal for speed.
dnf -y install git unzip jq tar wget curl firewalld python3 python3-venv || true

# Open firewall ports
for p in 8888 8501 1521; do firewall-cmd --zone=public --add-port=${p}/tcp --permanent || true; done
firewall-cmd --reload || true

# Minimal Jupyter env for opc
mkdir -p /home/opc/.venvs /home/opc/bin /opt/genai
python3 -m venv /home/opc/.venvs/genai || true
sudo -u opc bash -lc 'source $HOME/.venvs/genai/bin/activate && pip install --upgrade pip wheel && pip install jupyterlab oracledb'

# User script that waits for container then for FREEPDB1
cat >/opt/genai/init-genailabs.sh <<'USERSCRIPT'
#!/bin/bash
set -Eeuo pipefail
echo "[USER] waiting for 23ai container to be created..."
for i in {1..120}; do
  if /usr/bin/podman ps -a --format '{{.Names}}' | grep -qw 23ai; then
    echo "[USER] 23ai container exists."
    break
  fi
  sleep 5
done

echo "[USER] waiting for FREEPDB1 service to be registered..."
for i in {1..180}; do
  if /usr/bin/podman exec 23ai bash -lc '. /home/oracle/.bashrc; lsnrctl status' | grep -qi 'Service "FREEPDB1"'; then
    echo "[USER] FREEPDB1 registered."
    break
  fi
  sleep 10
done
exit 0
USERSCRIPT
chmod +x /opt/genai/init-genailabs.sh
bash /opt/genai/init-genailabs.sh || true

echo "===== GenAI OneClick setup: done $(date -u) ====="
SCRIPT
chmod +x /usr/local/bin/genai-setup.sh

# --------------------------------------------------------------------
# systemd units (DB first, then setup)
# --------------------------------------------------------------------
cat >/etc/systemd/system/genai-23ai.service <<'UNIT_DB'
[Unit]
Description=GenAI oneclick - Oracle 23ai container
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
TimeoutStartSec=0
KillMode=process
ExecStart=/bin/bash -lc '/usr/local/bin/genai-db.sh >> /var/log/genai_setup.log 2>&1'
Restart=no

[Install]
WantedBy=multi-user.target
UNIT_DB

cat >/etc/systemd/system/genai-setup.service <<'UNIT_SETUP'
[Unit]
Description=GenAI oneclick post-boot setup
Wants=network-online.target genai-23ai.service
After=network-online.target genai-23ai.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -lc '/usr/local/bin/genai-setup.sh >> /var/log/genai_setup.log 2>&1'
Restart=no

[Install]
WantedBy=multi-user.target
UNIT_SETUP

# Enable & start in the correct order
systemctl daemon-reload
systemctl enable genai-23ai.service
systemctl enable genai-setup.service
systemctl start genai-23ai.service      # DB/bootstrap first
systemctl start genai-setup.service     # then app/setup

echo "===== GenAI OneClick: cloud-init done $(date -u) ====="
