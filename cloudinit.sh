#!/bin/bash
# cloudinit.sh — one-click Oracle 23ai Free DB + GenAI setup
# Changes vs previous:
# - Start DB unit BEFORE setup unit (ordering fix)
# - User script waits for container existence, then for FREEPDB1
# - Hardcoded ORACLE_PWD=database123

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
# DB bootstrap script: /usr/local/bin/genai-db.sh
#   - starts container
#   - waits for first-boot readiness
#   - opens FREEPDB1 + SAVE STATE
#   - waits for listener to publish FREEPDB1
#   - (optional) creates vector/vector user
# --------------------------------------------------------------------
cat >/usr/local/bin/genai-db.sh <<'DBSCR'
#!/bin/bash
set -Eeuo pipefail

log(){ echo "[DB] $*"; }
retry() { local t=${1:-5}; shift; local n=1; until "$@"; do local rc=$?;
  if (( n>=t )); then return "$rc"; fi
  log "retry $n/$t (rc=$rc): $*"; sleep $((n*5)); ((n++));
done; }

# Keep ONE password here
ORACLE_PWD="database123"
ORACLE_PDB="FREEPDB1"
ORADATA_DIR="/home/opc/oradata"
IMAGE="container-registry.oracle.com/database/free:latest"
NAME="23ai"

log "start $(date -u)"

# Data dir & perms
mkdir -p "$ORADATA_DIR" && chown -R 54321:54321 "$ORADATA_DIR" || true

# Pull image (best-effort), remove any stale container
retry 5 podman pull "$IMAGE" || true
podman rm -f "$NAME" || true

# Launch DB (host network allows 127.0.0.1:1521 inside & outside container)
retry 5 podman run -d --name "$NAME" --network=host \
  -e ORACLE_PWD="$ORACLE_PWD" \
  -e ORACLE_PDB="$ORACLE_PDB" \
  -e ORACLE_MEMORY='2048' \
  -v "$ORADATA_DIR":/opt/oracle/oradata:z \
  "$IMAGE"

# Wait for first boot finished marker
log "waiting for 'DATABASE IS READY TO USE!'"
for i in {1..144}; do
  podman logs "$NAME" 2>&1 | grep -q 'DATABASE IS READY TO USE!' && break
  sleep 5
done

# Open FREEPDB1 + SAVE STATE using TCP to CDB "FREE" (robust)
log "opening PDB and saving state..."
podman exec -e ORACLE_PWD="$ORACLE_PWD" -i "$NAME" bash -lc '
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

# Wait until listener shows FREEPDB1
log "waiting for listener to publish FREEPDB1..."
for i in {1..60}; do
  podman exec -i "$NAME" bash -lc '. /home/oracle/.bashrc; lsnrctl status' \
    | grep -qi 'Service "FREEPDB1"' && { log "FREEPDB1 registered"; break; }
  sleep 3
done

# (Optional) create app user idempotently
log "creating PDB user 'vector' (idempotent)"
podman exec -e ORACLE_PWD="$ORACLE_PWD" -i "$NAME" bash -lc '
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
# Main setup script: /usr/local/bin/genai-setup.sh
#   (kept lightweight here; add your app provisioning as needed)
#   - embeds user init script that now waits for container existence
# --------------------------------------------------------------------
cat >/usr/local/bin/genai-setup.sh <<'SCRIPT'
#!/bin/bash
set -Eeuo pipefail
echo "===== GenAI OneClick setup: start $(date -u) ====="

# Basic packages
dnf -y install dnf-plugins-core || true
dnf config-manager --set-enabled ol8_addons || true
dnf -y makecache --refresh || true
dnf -y install git unzip jq tar wget curl python3 python3-pip podman firewalld || true

# Open firewall ports
for p in 8888 8501 1521; do firewall-cmd --zone=public --add-port=${p}/tcp --permanent || true; done
firewall-cmd --reload || true

# Create directories
mkdir -p /opt/genai /home/opc/code /home/opc/bin /home/opc/.venvs
chown -R opc:opc /opt/genai /home/opc

# Minimal Jupyter env
python3 -m venv /home/opc/.venvs/genai || true
sudo -u opc bash -lc 'source $HOME/.venvs/genai/bin/activate && pip install --upgrade pip wheel && pip install jupyterlab oracledb'

# User helper: wait for DB container then for FREEPDB1
cat >/opt/genai/init-genailabs.sh <<'USERSCRIPT'
#!/bin/bash
set -Eeuo pipefail

echo "[USER] waiting for 23ai container to be created..."
for i in {1..120}; do
  if sudo podman ps -a --format '{{.Names}}' | grep -qw 23ai; then
    echo "[USER] 23ai container exists."
    break
  fi
  sleep 5
done

echo "[USER] waiting for FREEPDB1 service to be registered..."
for i in {1..180}; do
  if sudo podman exec 23ai bash -lc '. /home/oracle/.bashrc; lsnrctl status' | grep -qi 'Service "FREEPDB1"'; then
    echo "[USER] FREEPDB1 registered."
    break
  fi
  sleep 10
done

# (Optional) seed anything that needs DB up...
exit 0
USERSCRIPT
chmod +x /opt/genai/init-genailabs.sh
sudo -u opc cp -f /opt/genai/init-genailabs.sh /home/opc/init-genailabs.sh || true

# Run user script (non-fatal)
bash /opt/genai/init-genailabs.sh || true

echo "===== GenAI OneClick setup: done $(date -u) ====="
SCRIPT
chmod +x /usr/local/bin/genai-setup.sh

# --------------------------------------------------------------------
# systemd units
#   - DB unit runs FIRST
#   - Setup unit depends on DB unit and runs AFTER
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

# --------------------------------------------------------------------
# Enable & start in the correct order: DB first, then setup
# --------------------------------------------------------------------
systemctl daemon-reload
systemctl enable genai-23ai.service
systemctl enable genai-setup.service
systemctl start genai-23ai.service      # start DB/bootstrap
systemctl start genai-setup.service     # run app/setup after DB

echo "===== GenAI OneClick: cloud-init done $(date -u) ====="
