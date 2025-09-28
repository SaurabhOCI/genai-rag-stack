#!/bin/bash
# cloudinit.sh — Minimal working GenAI stack with proper Terraform escaping
set -Eeuo pipefail

LOGFILE="/var/log/genai_setup.log"
exec > >(tee -a "$$LOGFILE") 2>&1
echo "===== GenAI OneClick: start $$(date -u) ====="

# Template variables from Terraform
JUPYTER_ENABLE_AUTH="${jupyter_enable_auth}"
JUPYTER_PASSWORD="${jupyter_password}"
BASTION_ENABLED="${bastion_enabled}"

# --------------------------------------------------------------------
# Grow filesystem
# --------------------------------------------------------------------
if command -v /usr/libexec/oci-growfs >/dev/null 2>&1; then
  /usr/libexec/oci-growfs -y || true
fi

# --------------------------------------------------------------------
# Install base packages
# --------------------------------------------------------------------
echo "[STEP] Installing base packages"
dnf config-manager --set-disabled ol8_ksplice || true
dnf clean all || true
dnf makecache --refresh || true
dnf config-manager --set-enabled ol8_addons || true
dnf config-manager --set-enabled ol8_appstream || true
dnf config-manager --set-enabled ol8_baseos_latest || true

# Install essential packages
dnf -y install podman curl grep coreutils shadow-utils git unzip \
  python39 python39-pip gcc gcc-c++ make wget firewalld

# Verify installation
if ! command -v podman >/dev/null 2>&1; then
    echo "[ERROR] Podman installation failed"
    exit 1
fi

echo "[SUCCESS] Base packages installed"

# --------------------------------------------------------------------
# Create directory structure
# --------------------------------------------------------------------
echo "[STEP] Creating directories"
mkdir -p /opt/genai /home/opc/{code,bin,scripts,.venvs,oradata}
chown -R opc:opc /opt/genai /home/opc/code /home/opc/bin /home/opc/scripts /home/opc/.venvs
chown -R 54321:54321 /home/opc/oradata || true

# --------------------------------------------------------------------
# Create setup scripts
# --------------------------------------------------------------------
echo "[STEP] Creating setup scripts"

# Main setup script
cat > /usr/local/bin/genai-setup.sh << 'EOF'
#!/bin/bash
set -e

MARKER="/var/lib/genai.oneclick.done"
if [[ -f "$MARKER" ]]; then
  echo "Already provisioned"
  exit 0
fi

echo "Starting GenAI setup..."

# Enable firewalld
systemctl enable --now firewalld || true

# Create Python virtual environment
echo "Creating Python environment..."
sudo -u opc bash << 'PYTHON_SETUP'
cd /home/opc
python3.9 -m venv .venvs/genai
source .venvs/genai/bin/activate
pip install --upgrade pip wheel setuptools

# Install compatible packages
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

echo "source ~/.venvs/genai/bin/activate" >> /home/opc/.bashrc
echo "Python environment ready"
PYTHON_SETUP

# Create essential configuration files
echo "Creating GenAI configuration files..."
mkdir -p /opt/genai/txt-docs /opt/genai/pdf-docs
cat > /opt/genai/LoadProperties.py << 'LOADPROPS'
class LoadProperties:
    def __init__(self):
        import json
        with open('config.txt') as f:
            js = json.load(f)
        self.model_name = js.get("model_name")
        self.embedding_model_name = js.get("embedding_model_name")
        self.endpoint = js.get("endpoint")
        self.compartment_ocid = js.get("compartment_ocid")
    def getModelName(self): return self.model_name
    def getEmbeddingModelName(self): return self.embedding_model_name
    def getEndpoint(self): return self.endpoint
    def getCompartment(self): return self.compartment_ocid
LOADPROPS

echo "[STEP] Download sample code repositories"
CODE_DIR="/home/opc/code"

# Simple wget approach
cd /tmp
if wget -q --timeout=30 https://github.com/ou-developers/css-navigator/archive/refs/heads/main.zip; then
    unzip -q main.zip
    if [ -d css-navigator-main/gen-ai ]; then
        cp -r css-navigator-main/gen-ai/* "$CODE_DIR"/ 2>/dev/null || true
        echo "Code downloaded successfully"
    fi
    rm -rf css-navigator-main main.zip
else
    echo "Code download failed - will be available manually"
fi

# Set ownership regardless
chown -R opc:opc "$CODE_DIR"
chmod -R a+rX "$CODE_DIR"

cat > /opt/genai/config.txt << 'CONFIG'
{"model_name":"cohere.command-r-16k","embedding_model_name":"cohere.embed-english-v3.0","endpoint":"https://inference.generativeai.eu-frankfurt-1.oci.oraclecloud.com","compartment_ocid":"ocid1.compartment.oc1....replace_me..."}
CONFIG

echo "faq | What are Always Free services?=====Always Free services are part of Oracle Cloud Free Tier." > /opt/genai/txt-docs/faq.txt
chown -R opc:opc /opt/genai

# Create Jupyter startup script with authentication support
cat > /home/opc/start-jupyter.sh << 'JUPYTER'
#!/bin/bash
source ~/.venvs/genai/bin/activate
export JUPYTER_CONFIG_DIR=/home/opc/.jupyter

# Create jupyter config directory
mkdir -p $JUPYTER_CONFIG_DIR

# Generate Jupyter config if it doesn't exist
if [ ! -f $JUPYTER_CONFIG_DIR/jupyter_lab_config.py ]; then
    jupyter lab --generate-config
fi

# Configure authentication based on template variables
if [ "$JUPYTER_ENABLE_AUTH" = "true" ] && [ -n "$JUPYTER_PASSWORD" ]; then
    python3 -c "
from jupyter_server.auth import passwd
import os
config_file = os.path.expanduser('~/.jupyter/jupyter_lab_config.py')
with open(config_file, 'a') as f:
    f.write(f\"\\nc.ServerApp.password = '{passwd('$JUPYTER_PASSWORD')}'\\n\")
    f.write('c.ServerApp.allow_remote_access = True\\n')
    f.write('c.ServerApp.ip = \"0.0.0.0\"\\n')
    f.write('c.ServerApp.port = 8888\\n')
    f.write('c.ServerApp.open_browser = False\\n')
print('Jupyter password authentication configured')
"
    jupyter lab --ip=0.0.0.0 --port=8888 --no-browser --allow-root
else
    # No authentication mode for easier development access
    jupyter lab --NotebookApp.token='' --NotebookApp.password='' --ip=0.0.0.0 --port=8888 --no-browser --allow-root
fi
JUPYTER
chown opc:opc /home/opc/start-jupyter.sh
chmod +x /home/opc/start-jupyter.sh

# Open firewall ports
firewall-cmd --zone=public --add-port=8888/tcp --permanent || true
firewall-cmd --zone=public --add-port=8501/tcp --permanent || true
firewall-cmd --zone=public --add-port=1521/tcp --permanent || true
firewall-cmd --reload || true

touch "$MARKER"
echo "GenAI setup complete"
EOF

chmod +x /usr/local/bin/genai-setup.sh

# Database setup script
cat > /usr/local/bin/genai-db.sh << 'EOF'
#!/bin/bash
set -e

echo "[DB] Starting Oracle 23ai setup"
PODMAN="/usr/bin/podman"
ORACLE_PWD="database123"
IMAGE="container-registry.oracle.com/database/free:latest"
NAME="23ai"

# Pull image and start container
$PODMAN pull "$IMAGE" || exit 1
$PODMAN rm -f "$NAME" || true

$PODMAN run -d --name "$NAME" --network=host \
  -e ORACLE_PWD="$ORACLE_PWD" \
  -e ORACLE_PDB="FREEPDB1" \
  -e ORACLE_MEMORY='2048' \
  -v /home/opc/oradata:/opt/oracle/oradata:z \
  "$IMAGE"

echo "[DB] Waiting for database to be ready..."
for i in {1..120}; do
  if $PODMAN logs "$NAME" 2>&1 | grep -q 'DATABASE IS READY TO USE!'; then
    echo "[DB] Database ready"
    break
  fi
  sleep 10
done

# Configure database
echo "[DB] Configuring database..."
$PODMAN exec -i "$NAME" bash -c '
source /home/oracle/.bashrc
sqlplus -S / as sysdba << SQL
ALTER PLUGGABLE DATABASE FREEPDB1 OPEN;
ALTER PLUGGABLE DATABASE FREEPDB1 SAVE STATE;
ALTER SYSTEM REGISTER;
EXIT
SQL
' || true

# Wait for FREEPDB1 service to be registered
echo "[DB] Waiting for FREEPDB1 service registration..."
for i in {1..60}; do
  if $PODMAN exec "$NAME" bash -c '. /home/oracle/.bashrc; lsnrctl status' | grep -qi 'Service "FREEPDB1"'; then
    echo "[DB] FREEPDB1 service registered"
    break
  fi
  sleep 5
done

# Create vector user and configure PDB for GenAI workloads
echo "[DB] Creating vector user and configuring for GenAI..."
$PODMAN exec -i "$NAME" bash -c '
source /home/oracle/.bashrc
sqlplus -S sys/database123@127.0.0.1:1521/FREEPDB1 as sysdba << SQL
WHENEVER SQLERROR CONTINUE

-- Create additional tablespaces for GenAI workloads
CREATE BIGFILE TABLESPACE tbs2 DATAFILE '"'"'bigtbs_f2.dbf'"'"' SIZE 1G AUTOEXTEND ON NEXT 32M MAXSIZE UNLIMITED EXTENT MANAGEMENT LOCAL SEGMENT SPACE MANAGEMENT AUTO;
CREATE UNDO TABLESPACE undots2 DATAFILE '"'"'undotbs_2a.dbf'"'"' SIZE 1G AUTOEXTEND ON RETENTION GUARANTEE;
CREATE TEMPORARY TABLESPACE temp_demo TEMPFILE '"'"'temp02.dbf'"'"' SIZE 1G REUSE AUTOEXTEND ON NEXT 32M MAXSIZE UNLIMITED EXTENT MANAGEMENT LOCAL UNIFORM SIZE 1M;

-- Create vector user with proper permissions for AI workloads
CREATE USER vector IDENTIFIED BY "vector" DEFAULT TABLESPACE tbs2 QUOTA UNLIMITED ON tbs2;
GRANT CREATE SESSION, CREATE TABLE, CREATE SEQUENCE, CREATE VIEW, CREATE PROCEDURE TO vector;
GRANT UNLIMITED TABLESPACE TO vector;

-- Additional grants for GenAI functionality
GRANT CREATE ANY DIRECTORY TO vector;
GRANT READ, WRITE ON DIRECTORY DATA_PUMP_DIR TO vector;

EXIT
SQL
' || echo "[DB] Warning: Some database configuration steps may have failed"

# Configure CDB-level settings for vector operations
echo "[DB] Configuring vector memory settings..."
$PODMAN exec -i "$NAME" bash -c '
source /home/oracle/.bashrc
sqlplus -S / as sysdba << SQL
WHENEVER SQLERROR CONTINUE
CREATE PFILE FROM SPFILE;
ALTER SYSTEM SET vector_memory_size = 512M SCOPE=SPFILE;
SHUTDOWN IMMEDIATE;
STARTUP;
EXIT
SQL
' || echo "[DB] Warning: Vector memory configuration may have failed"

echo "[DB] Database setup complete"
EOF

chmod +x /usr/local/bin/genai-db.sh

# --------------------------------------------------------------------
# Create systemd services
# --------------------------------------------------------------------
echo "[STEP] Creating systemd services"

cat > /etc/systemd/system/genai-db.service << 'EOF'
[Unit]
Description=Oracle 23ai Database
After=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/genai-db.sh
TimeoutStartSec=1800

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/genai-setup.service << 'EOF'
[Unit]
Description=GenAI Setup
After=network.target genai-db.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/genai-setup.sh
TimeoutStartSec=1800

[Install]
WantedBy=multi-user.target
EOF

# --------------------------------------------------------------------
# Start services
# --------------------------------------------------------------------
echo "[STEP] Starting services"
systemctl daemon-reload
systemctl enable genai-db.service
systemctl enable genai-setup.service
systemctl start genai-db.service
systemctl start genai-setup.service

# --------------------------------------------------------------------
# Create bastion helper if enabled
# --------------------------------------------------------------------
if [ "$$BASTION_ENABLED" = "true" ]; then
  echo "[STEP] Creating bastion helper"
  cat > /home/opc/scripts/bastion-info.sh << 'EOF'
#!/bin/bash
echo "=== OCI Bastion Service Information ==="
echo "Access via bastion port forwarding sessions"
echo "1. SSH: Use Terraform output ssh_connection_command"
echo "2. Jupyter: Use Terraform output jupyter_connection_command"
echo "3. Streamlit: Use Terraform output streamlit_connection_command"
echo "4. Database: Use Terraform output database_connection_command"
EOF
  chmod +x /home/opc/scripts/bastion-info.sh
  chown opc:opc /home/opc/scripts/bastion-info.sh
fi

echo "===== GenAI OneClick: cloud-init complete $$(date -u) ====="
