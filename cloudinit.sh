#!/bin/bash
# cloudinit.sh — Minimal working GenAI stack with proper Terraform escaping
set -Eeuo pipefail

LOGFILE="/var/log/genai_setup.log"
exec > >(tee -a "$LOGFILE") 2>&1
echo "===== GenAI OneClick: start $(date -u) ====="

# Template variables from Terraform
JUPYTER_ENABLE_AUTH="${jupyter_enable_auth}"
JUPYTER_PASSWORD="${jupyter_password}"
BASTION_ENABLED="${bastion_enabled}"

# Pass template variables to the environment
echo "export JUPYTER_PASSWORD_ENV='${jupyter_password}'" >> /home/opc/.bashrc
echo "export JUPYTER_ENABLE_AUTH_ENV='${jupyter_enable_auth}'" >> /home/opc/.bashrc

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

# Create password file for Jupyter
echo "${jupyter_password}" > /tmp/jupyter_password.txt
chown opc:opc /tmp/jupyter_password.txt

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
  plotly \
  sentence-transformers

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

# Download sample code repositories
echo "[STEP] Download sample code repositories"
CODE_DIR="/home/opc/code"
mkdir -p "$CODE_DIR"

# Multiple download strategies
download_success=false

# Strategy 1: Direct wget
if ! $download_success; then
    echo "Trying wget download..."
    cd /tmp
    if timeout 60 wget -q --no-check-certificate https://github.com/ou-developers/css-navigator/archive/refs/heads/main.zip; then
        if unzip -q main.zip && [ -d css-navigator-main/gen-ai ]; then
            cp -r css-navigator-main/gen-ai/* "$CODE_DIR"/ 2>/dev/null && download_success=true
            echo "✓ Code downloaded via wget"
        fi
        rm -rf css-navigator-main main.zip
    fi
fi

# Strategy 2: curl fallback
if ! $download_success; then
    echo "Trying curl download..."
    cd /tmp
    if timeout 60 curl -sL https://github.com/ou-developers/css-navigator/archive/refs/heads/main.zip -o main.zip; then
        if unzip -q main.zip && [ -d css-navigator-main/gen-ai ]; then
            cp -r css-navigator-main/gen-ai/* "$CODE_DIR"/ 2>/dev/null && download_success=true
            echo "✓ Code downloaded via curl"
        fi
        rm -rf css-navigator-main main.zip
    fi
fi

# Strategy 3: Create basic structure if all fails
if ! $download_success; then
    echo "⚠ Downloads failed - creating basic structure"
    echo "# Sample notebook" > "$CODE_DIR/sample.ipynb"
    echo "print('Hello from Jupyter!')" > "$CODE_DIR/hello.py"
    echo "# GenAI Sample Files" > "$CODE_DIR/README.md"
    echo "Files will be available for manual download" >> "$CODE_DIR/README.md"
fi

# Always set proper ownership
chown -R opc:opc "$CODE_DIR"
chmod -R 755 "$CODE_DIR"

cat > /opt/genai/config.txt << 'CONFIG'
{"model_name":"cohere.command-r-16k","embedding_model_name":"cohere.embed-english-v3.0","endpoint":"https://inference.generativeai.eu-frankfurt-1.oci.oraclecloud.com","compartment_ocid":"ocid1.compartment.oc1....replace_me..."}
CONFIG

echo "faq | What are Always Free services?=====Always Free services are part of Oracle Cloud Free Tier." > /opt/genai/txt-docs/faq.txt
chown -R opc:opc /opt/genai

# Create Jupyter startup script with robust password handling
cat > /home/opc/start-jupyter.sh << 'JUPYTER_EOF'
#!/bin/bash
source ~/.venvs/genai/bin/activate
export JUPYTER_CONFIG_DIR=/home/opc/.jupyter
mkdir -p $JUPYTER_CONFIG_DIR

# Check for password from multiple sources
JUPYTER_PASSWORD=""
if [ -f /tmp/jupyter_password.txt ]; then
    JUPYTER_PASSWORD=$(cat /tmp/jupyter_password.txt)
elif [ -n "$JUPYTER_PASSWORD_ENV" ]; then
    JUPYTER_PASSWORD="$JUPYTER_PASSWORD_ENV"
fi

# Check authentication flag
if [ -n "$JUPYTER_ENABLE_AUTH_ENV" ]; then
    JUPYTER_ENABLE_AUTH="$JUPYTER_ENABLE_AUTH_ENV"
else
    JUPYTER_ENABLE_AUTH="false"
fi

if [ "$JUPYTER_ENABLE_AUTH" = "true" ] && [ -n "$JUPYTER_PASSWORD" ]; then
    echo "Setting up Jupyter with password authentication..."
    python3 -c "
from jupyter_server.auth import passwd
with open('/home/opc/.jupyter/jupyter_lab_config.py', 'w') as f:
    f.write(f\"c.ServerApp.password = '{passwd('$JUPYTER_PASSWORD')}\\n\")
    f.write('c.ServerApp.allow_remote_access = True\\n')
    f.write('c.ServerApp.ip = \\\"0.0.0.0\\\"\\n')
    f.write('c.ServerApp.port = 8888\\n')
    f.write('c.ServerApp.open_browser = False\\n')
"
    jupyter lab --ip=0.0.0.0 --port=8888 --no-browser --allow-root
else
    echo "Starting Jupyter without authentication..."
    jupyter lab --LabApp.token='' --LabApp.password='' --ip=0.0.0.0 --port=8888 --no-browser --allow-root
fi
JUPYTER_EOF
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

# Database setup script with IMPROVED FREEPDB1 handling
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

# Configure database with better FREEPDB1 handling
echo "[DB] Configuring database..."
$PODMAN exec -i "$NAME" bash -c '
source /home/oracle/.bashrc
sqlplus -S / as sysdba << SQL
WHENEVER SQLERROR CONTINUE
ALTER PLUGGABLE DATABASE FREEPDB1 OPEN;
ALTER PLUGGABLE DATABASE FREEPDB1 SAVE STATE;
ALTER SYSTEM REGISTER;
EXIT
SQL
' || true

# Improved FREEPDB1 service registration with retry logic
echo "[DB] Waiting for FREEPDB1 service registration..."
service_registered=false
for attempt in {1..5}; do
  echo "[DB] Registration attempt $attempt/5..."
  
  # Force service registration
  $PODMAN exec -i "$NAME" bash -c '
  source /home/oracle/.bashrc
  sqlplus -S / as sysdba << SQL
  ALTER SYSTEM REGISTER;
  EXIT
SQL
  ' || true
  
  # Wait and check
  sleep 15
  
  if $PODMAN exec "$NAME" bash -c '. /home/oracle/.bashrc; lsnrctl status' | grep -qi 'Service "FREEPDB1"'; then
    echo "[DB] FREEPDB1 service registered successfully"
    service_registered=true
    break
  fi
  
  # If not registered, try restarting listener
  if [ $attempt -lt 5 ]; then
    echo "[DB] Service not registered, restarting listener..."
    $PODMAN exec "$NAME" bash -c '. /home/oracle/.bashrc; lsnrctl stop; lsnrctl start' || true
    sleep 10
  fi
done

if [ "$service_registered" = "false" ]; then
  echo "[DB] Warning: FREEPDB1 service registration failed after all attempts"
fi

# Create vector user with enhanced error handling and retry
echo "[DB] Creating vector user and configuring for GenAI..."
vector_user_created=false

for attempt in {1..3}; do
  echo "[DB] Vector user creation attempt $attempt/3..."
  
  if $PODMAN exec -i "$NAME" bash -c '
  source /home/oracle/.bashrc
  sqlplus -S sys/database123@127.0.0.1:1521/FREEPDB1 as sysdba << SQL
  WHENEVER SQLERROR CONTINUE
  
  -- Create vector user with proper permissions for AI workloads
  CREATE USER vector IDENTIFIED BY "vector" DEFAULT TABLESPACE users QUOTA UNLIMITED ON users;
  GRANT CREATE SESSION, CREATE TABLE, CREATE SEQUENCE, CREATE VIEW, CREATE PROCEDURE TO vector;
  GRANT UNLIMITED TABLESPACE TO vector;
  GRANT CREATE ANY DIRECTORY TO vector;
  GRANT READ, WRITE ON DIRECTORY DATA_PUMP_DIR TO vector;
  
  -- Test the connection
  CONNECT vector/vector@127.0.0.1:1521/FREEPDB1;
  SELECT '"'"'Vector user created successfully'"'"' as status FROM DUAL;
  
  EXIT
SQL
  '; then
    echo "[DB] Vector user created successfully"
    vector_user_created=true
    break
  else
    echo "[DB] Vector user creation failed, attempt $attempt/3"
    if [ $attempt -lt 3 ]; then
      sleep 10
    fi
  fi
done

if [ "$vector_user_created" = "false" ]; then
  echo "[DB] Warning: Vector user creation failed after all attempts"
fi

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

-- Reopen FREEPDB1 after restart
ALTER PLUGGABLE DATABASE FREEPDB1 OPEN;
ALTER PLUGGABLE DATABASE FREEPDB1 SAVE STATE;
ALTER SYSTEM REGISTER;

EXIT
SQL
' || echo "[DB] Warning: Vector memory configuration may have failed"

# Final verification
echo "[DB] Final verification..."
sleep 5
if $PODMAN exec "$NAME" bash -c '. /home/oracle/.bashrc; echo "SELECT USER FROM DUAL;" | sqlplus -S vector/vector@127.0.0.1:1521/FREEPDB1' 2>/dev/null | grep -q VECTOR; then
  echo "[DB] ✓ Vector user verified successfully"
else
  echo "[DB] ⚠ Vector user verification failed"
fi

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
if [ "$BASTION_ENABLED" = "true" ]; then
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

echo "===== GenAI OneClick: cloud-init complete $(date -u) ====="
