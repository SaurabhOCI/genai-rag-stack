#!/bin/bash
# cloudinit.sh — Oracle 23ai Free + GenAI stack bootstrap with proper Terraform escaping
# - All shell variables properly escaped with $$ for Terraform template processing
# - Template variables: jupyter_enable_auth, jupyter_password, bastion_enabled

set -Eeuo pipefail

LOGFILE="/var/log/genai_setup.log"
exec > >(tee -a "$$LOGFILE") 2>&1
echo "===== GenAI OneClick: start $$(date -u) ====="

# Template variables (NOT escaped - these come from Terraform)
JUPYTER_ENABLE_AUTH="${jupyter_enable_auth}"
JUPYTER_PASSWORD="${jupyter_password}"
BASTION_ENABLED="${bastion_enabled}"

# --------------------------------------------------------------------
# Grow filesystem (best-effort)
# --------------------------------------------------------------------
if command -v /usr/libexec/oci-growfs >/dev/null 2>&1; then
  /usr/libexec/oci-growfs -y || true
fi

# --------------------------------------------------------------------
# PRE: install Podman so the DB unit can run right away
# --------------------------------------------------------------------
echo "[PRE] installing Podman and basics"

# Disable problematic repositories that might cause connectivity issues
dnf config-manager --set-disabled ol8_ksplice || true

# Clean and refresh cache
dnf clean all || true
dnf makecache --refresh || true

# Enable required repositories with error handling
dnf config-manager --set-enabled ol8_addons || true
dnf config-manager --set-enabled ol8_appstream || true
dnf config-manager --set-enabled ol8_baseos_latest || true

# Install core packages with retries
install_with_retry() {
    local max_attempts=3
    local attempt=1
    
    while [ $$attempt -le $$max_attempts ]; do
        echo "[PRE] Installation attempt $$attempt of $$max_attempts"
        if dnf -y install podman curl grep coreutils shadow-utils git unzip; then
            echo "[PRE] Installation successful"
            return 0
        else
            echo "[PRE] Installation attempt $$attempt failed, retrying..."
            sleep 10
            attempt=$$((attempt + 1))
        fi
    done
    
    echo "[PRE] All installation attempts failed"
    return 1
}

# Try installation with retries
if ! install_with_retry; then
    echo "[PRE] Critical: Could not install required packages"
    exit 1
fi

# Verify critical tools are available
if ! command -v podman >/dev/null 2>&1; then
    echo "[PRE] Critical: podman not found after installation"
    exit 1
fi

/usr/bin/podman --version || { echo "[PRE] podman installation verification failed"; exit 1; }
echo "[PRE] Successfully installed Podman and dependencies"

# ====================================================================
# genai-setup.sh (MAIN provisioning) — with proper escaping
# ====================================================================
cat >/usr/local/bin/genai-setup.sh <<'SCRIPT'
#!/bin/bash
set -uxo pipefail

echo "===== GenAI OneClick systemd: start $(date -u) ====="

MARKER="/var/lib/genai.oneclick.done"
if [[ -f "$MARKER" ]]; then
  echo "[INFO] already provisioned; exiting."
  exit 0
fi

retry() { local max=${1:-5}; shift; local n=1; until "$@"; do rc=$?; [[ $n -ge $max ]] && echo "[RETRY] failed after $n: $*" && return $rc; echo "[RETRY] $n -> retrying in $((n*5))s: $*"; sleep $((n*5)); n=$((n+1)); done; return 0; }

echo "[STEP] enable ol8_addons, pre-populate metadata, and install base pkgs"
retry 5 dnf -y install dnf-plugins-core curl
retry 5 dnf config-manager --set-enabled ol8_addons || true
retry 5 dnf -y makecache --refresh
retry 5 dnf -y install \
  git unzip jq tar make gcc gcc-c++ bzip2 bzip2-devel zlib-devel openssl-devel readline-devel libffi-devel \
  wget curl which xz python3 python3-pip podman firewalld

echo "[STEP] enable firewalld"
systemctl enable --now firewalld || true

echo "[STEP] create /opt/genai and /home/opc/code"
mkdir -p /opt/genai /home/opc/code /home/opc/bin /home/opc/scripts /home/opc/.venvs
chown -R opc:opc /opt/genai /home/opc/code /home/opc/bin /home/opc/scripts /home/opc/.venvs
SCRIPT

# Add bastion-specific content only if enabled (outside the here-document)
if [ "$$BASTION_ENABLED" = "true" ]; then
cat >> /usr/local/bin/genai-setup.sh << 'BASTION_SECTION'

echo "[STEP] create bastion helper scripts"
cat > /home/opc/scripts/bastion-info.sh << 'BASTION_INFO_SCRIPT'
#!/bin/bash
echo "=== OCI Bastion Service Information ==="
echo "This instance is deployed in a private subnet with Bastion Service access."
echo ""
echo "To access services, use the bastion sessions created by Terraform:"
echo ""
echo "1. SSH Access: Use the SSH connection command from Terraform outputs"
echo "2. Jupyter Lab: Use port forwarding, then browse to http://localhost:8888"
echo "3. Streamlit: Use port forwarding, then browse to http://localhost:8501"
echo "4. Oracle DB: Use port forwarding, then connect to localhost:1521/FREEPDB1"
echo ""
echo "For Terraform outputs, run: terraform output"
BASTION_INFO_SCRIPT

chmod +x /home/opc/scripts/bastion-info.sh
chown opc:opc /home/opc/scripts/bastion-info.sh
echo "echo 'Run ~/scripts/bastion-info.sh for connection information'" >> /home/opc/.bashrc
BASTION_SECTION
fi

# Continue with the main setup script
cat >> /usr/local/bin/genai-setup.sh << 'MAIN_CONTINUE'

echo "[STEP] create /home/opc/code and fetch css-navigator/gen-ai"
CODE_DIR="/home/opc/code"
mkdir -p "$CODE_DIR"

# preflight
if ! command -v git   >/dev/null 2>&1; then retry 5 dnf -y install git;   fi
if ! command -v curl  >/dev/null 2>&1; then retry 5 dnf -y install curl;  fi
if ! command -v unzip >/dev/null 2>&1; then retry 5 dnf -y install unzip; fi

TMP_DIR="$(mktemp -d)"
REPO_ZIP="/tmp/cssnav.zip"

# Try sparse checkout
retry 5 git clone --depth 1 --filter=blob:none --sparse https://github.com/ou-developers/css-navigator.git "$TMP_DIR" || true
retry 5 git -C "$TMP_DIR" sparse-checkout init --cone || true
retry 5 git -C "$TMP_DIR" sparse-checkout set gen-ai || true

if [ -d "$TMP_DIR/gen-ai" ] && [ -n "$(ls -A "$TMP_DIR/gen-ai" 2>/dev/null)" ]; then
  echo "[STEP] copying from sparse-checkout"
  chmod -R a+rx "$TMP_DIR/gen-ai" || true
  cp -a "$TMP_DIR/gen-ai"/. "$CODE_DIR"/
else
  echo "[STEP] sparse-checkout empty; falling back to zip"
  retry 5 curl -L -o "$REPO_ZIP" https://codeload.github.com/ou-developers/css-navigator/zip/refs/heads/main
  TMP_ZIP_DIR="$(mktemp -d)"
  unzip -q -o "$REPO_ZIP" -d "$TMP_ZIP_DIR"
  if [ -d "$TMP_ZIP_DIR/css-navigator-main/gen-ai" ]; then
    chmod -R a+rx "$TMP_ZIP_DIR/css-navigator-main/gen-ai" || true
    cp -a "$TMP_ZIP_DIR/css-navigator-main/gen-ai"/. "$CODE_DIR"/
  else
    echo "[WARN] gen-ai folder not found in zip"
  fi
  rm -rf "$TMP_ZIP_DIR" "$REPO_ZIP"
fi

rm -rf "$TMP_DIR"

# ownership and a backward-compat symlink
chown -R opc:opc "$CODE_DIR" || true
chmod -R a+rX "$CODE_DIR" || true
ln -sfn "$CODE_DIR" /opt/code || true

echo "[STEP] install Python 3.9 for OL8 and create venv with COMPATIBLE packages"
retry 5 dnf -y module enable python39 || true
retry 5 dnf -y install python39 python39-pip

# Create virtual environment with compatible package versions
sudo -u opc bash -lc '
python3.9 -m venv $HOME/.venvs/genai || true
echo "source $HOME/.venvs/genai/bin/activate" >> $HOME/.bashrc
source $HOME/.venvs/genai/bin/activate
python -m pip install --upgrade pip wheel setuptools

# Install packages with versions compatible with Python 3.9/OL8
pip install --no-cache-dir \
  "jupyterlab>=3.0.0,<4.0.0" \
  notebook \
  ipython \
  "streamlit>=0.80.0,<1.11.0" \
  pandas \
  numpy \
  matplotlib \
  seaborn \
  requests \
  python-dotenv \
  oracledb \
  scikit-learn \
  plotly

echo "Compatible Python packages installed successfully"
'

echo "[STEP] write start_jupyter.sh"
cat >/home/opc/start_jupyter.sh <<'SH'
#!/bin/bash
set -eux
source $HOME/.venvs/genai/bin/activate
jupyter lab --NotebookApp.token='' --NotebookApp.password='' --ip=0.0.0.0 --port=8888 --no-browser
SH
chown opc:opc /home/opc/start_jupyter.sh
chmod +x /home/opc/start_jupyter.sh

echo "[STEP] open firewall ports"
for p in 8888 8501 1521; do firewall-cmd --zone=public --add-port=${p}/tcp --permanent || true; done
firewall-cmd --reload || true

touch "$MARKER"
echo "===== GenAI OneClick systemd: COMPLETE $(date -u) ====="
MAIN_CONTINUE

chmod +x /usr/local/bin/genai-setup.sh

# ====================================================================
# genai-db.sh (DB container) — FIXED with proper escaping
# ====================================================================
cat >/usr/local/bin/genai-db.sh <<'DBSCR'
#!/bin/bash
set -Eeuo pipefail

PODMAN="/usr/bin/podman"
log(){ echo "[DB] $*"; }

# Fixed retry function with proper bash syntax
retry() { 
    local t=${1:-5}; 
    shift; 
    local n=1; 
    until "$@"; do 
        local rc=$?;
        if [ $n -ge $t ]; then 
            return "$rc"; 
        fi
        log "retry $n/$t (rc=$rc): $*"; 
        sleep $((n*5)); 
        n=$((n+1));
    done; 
}

ORACLE_PWD="database123"
ORACLE_PDB="FREEPDB1"
ORADATA_DIR="/home/opc/oradata"
IMAGE="container-registry.oracle.com/database/free:latest"
NAME="23ai"

log "start $(date -u)"
mkdir -p "$ORADATA_DIR" && chown -R 54321:54321 "$ORADATA_DIR" || true

retry 5 "$PODMAN" pull "$IMAGE" || true
"$PODMAN" rm -f "$NAME" || true

retry 5 "$PODMAN" run -d --name "$NAME" --network=host \
  -e ORACLE_PWD="$ORACLE_PWD" \
  -e ORACLE_PDB="$ORACLE_PDB" \
  -e ORACLE_MEMORY='2048' \
  -v "$ORADATA_DIR":/opt/oracle/oradata:z \
  "$IMAGE"

log "waiting for 'DATABASE IS READY TO USE!'"
for i in {1..144}; do
  "$PODMAN" logs "$NAME" 2>&1 | grep -q 'DATABASE IS READY TO USE!' && break
  sleep 5
done

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

log "waiting for listener to publish FREEPDB1..."
for i in {1..60}; do
  "$PODMAN" exec -i "$NAME" bash -lc '. /home/oracle/.bashrc; lsnrctl status' \
    | grep -qi 'Service "FREEPDB1"' && { log "FREEPDB1 registered"; break; }
  sleep 3
done

log "creating PDB user 'vector' (idempotent)"
"$PODMAN" exec -e ORACLE_PWD="$ORACLE_PWD" -i "$NAME" bash -lc '
  . /home/oracle/.bashrc
  sqlplus -S -L /nolog <<SQL
  CONNECT sys/${ORACLE_PWD}@127.0.0.1:1521/FREEPDB1 AS SYSDBA
  SET DEFINE OFF
  WHENEVER SQLERROR CONTINUE
  CREATE USER vector IDENTIFIED BY "vector";
  GRANT CREATE SESSION, CREATE TABLE, CREATE SEQUENCE, CREATE VIEW TO vector;
  ALTER USER vector QUOTA UNLIMITED ON USERS;
  EXIT
SQL
' || log "WARN: vector user create step returned non-zero"

log "done $(date -u)"
DBSCR
chmod +x /usr/local/bin/genai-db.sh

# ====================================================================
# systemd units — DB FIRST, then setup
# ====================================================================
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

systemctl daemon-reload
systemctl enable genai-23ai.service
systemctl enable genai-setup.service
systemctl start genai-23ai.service      # DB/bootstrap first
systemctl start genai-setup.service     # then app/setup

echo "===== GenAI OneClick: cloud-init done $$(date -u) ====="
