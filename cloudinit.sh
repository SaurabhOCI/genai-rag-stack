#!/bin/bash
# cloudinit.sh — Oracle 23ai Free + GenAI stack bootstrap with Bastion support
# - Enhanced for private subnet deployment with Bastion Service
# - Configurable Jupyter authentication
# - Improved error handling and logging

set -Eeuo pipefail

LOGFILE="/var/log/genai_setup.log"
exec > >(tee -a "$LOGFILE") 2>&1
echo "===== GenAI OneClick with Bastion: start $(date -u) ====="

# Template variables
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
    
    while [ $attempt -le $max_attempts ]; do
        echo "[PRE] Installation attempt $attempt of $max_attempts"
        if dnf -y install podman curl grep coreutils shadow-utils git unzip; then
            echo "[PRE] Installation successful"
            return 0
        else
            echo "[PRE] Installation attempt $attempt failed, retrying..."
            sleep 10
            attempt=$((attempt + 1))
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
# genai-setup.sh (MAIN provisioning) — enhanced for bastion
# ====================================================================
cat > /usr/local/bin/genai-setup.sh << 'EOF_GENAI_SETUP'
#!/bin/bash
set -uxo pipefail

echo "===== GenAI OneClick systemd: start $(date -u) ====="

MARKER="/var/lib/genai.oneclick.done"
if [[ -f "$MARKER" ]]; then
  echo "[INFO] already provisioned; exiting."
  exit 0
fi

retry() { 
    local max=${1:-5}; shift; local n=1; 
    until "$@"; do 
        rc=$?; 
        [[ $n -ge $max ]] && echo "[RETRY] failed after $n: $*" && return $rc; 
        echo "[RETRY] $n -> retrying in $((n*5))s: $*"; 
        sleep $((n*5)); 
        n=$((n+1)); 
    done; 
    return 0; 
}

echo "[STEP] enable ol8_addons, pre-populate metadata, and install base pkgs"
retry 5 dnf -y install dnf-plugins-core curl
retry 5 dnf config-manager --set-enabled ol8_addons || true
retry 5 dnf -y makecache --refresh
retry 5 dnf -y install \
  git unzip jq tar make gcc gcc-c++ bzip2 bzip2-devel zlib-devel openssl-devel readline-devel libffi-devel \
  wget curl which xz python3 python3-pip python39 python39-pip podman firewalld

echo "[STEP] enable firewalld"
systemctl enable --now firewalld || true

echo "[STEP] create /opt/genai and /home/opc directories"
mkdir -p /opt/genai /home/opc/code /home/opc/bin /home/opc/scripts /home/opc/.venvs
chown -R opc:opc /opt/genai /home/opc/code /home/opc/bin /home/opc/scripts /home/opc/.venvs

echo "[STEP] create bastion helper scripts"
if [ "$BASTION_ENABLED" = "true" ]; then
  cat > /home/opc/scripts/bastion-info.sh << 'EOF_BASTION_INFO'
#!/bin/bash
echo "=== OCI Bastion Service Information ==="
echo "This instance is deployed in a private subnet with Bastion Service access."
echo ""
echo "To access services, use the bastion sessions created by Terraform:"
echo ""
echo "1. SSH Access:"
echo "   Use the SSH connection command from Terraform outputs"
echo ""
echo "2. Jupyter Lab Access:"
echo "   Use the Jupyter connection command from Terraform outputs"
echo "   Then browse to: http://localhost:8888"
echo ""
echo "3. Streamlit Access:"
echo "   Use the Streamlit connection command from Terraform outputs"
echo "   Then browse to: http://localhost:8501"
echo ""
echo "4. Oracle Database Access:"
echo "   Use the database connection command from Terraform outputs"
echo "   Then connect to: localhost:1521/FREEPDB1"
echo ""
echo "For Terraform outputs, run: terraform output"
EOF_BASTION_INFO

  chmod +x /home/opc/scripts/bastion-info.sh
  chown opc:opc /home/opc/scripts/bastion-info.sh
  
  # Add to .bashrc
  echo "echo 'Run ~/scripts/bastion-info.sh for connection information'" >> /home/opc/.bashrc
fi

echo "[STEP] create Python virtual environment"
sudo -u opc bash -c '
export HOME=/home/opc
python3 -m venv $HOME/.venvs/genai
source $HOME/.venvs/genai/bin/activate
pip install --upgrade pip wheel setuptools

# Install essential packages
pip install \
  jupyterlab==4.2.5 \
  notebook \
  ipython \
  streamlit==1.36.0 \
  pandas \
  numpy \
  matplotlib \
  seaborn \
  requests \
  python-dotenv \
  oracledb

echo "Virtual environment created successfully"
'

echo "[STEP] add venv activation to .bashrc"
echo 'source ~/.venvs/genai/bin/activate' >> /home/opc/.bashrc
chown opc:opc /home/opc/.bashrc

echo "[STEP] create Jupyter startup script"
cat > /home/opc/start-jupyter.sh << 'EOF_JUPYTER'
#!/bin/bash
source ~/.venvs/genai/bin/activate
export JUPYTER_CONFIG_DIR=/home/opc/.jupyter

# Create jupyter config directory
mkdir -p $JUPYTER_CONFIG_DIR

# Generate Jupyter config if it doesn't exist
if [ ! -f $JUPYTER_CONFIG_DIR/jupyter_lab_config.py ]; then
    jupyter lab --generate-config
fi

# Set password if provided
if [ -n "$JUPYTER_PASSWORD" ] && [ "$JUPYTER_ENABLE_AUTH" = "true" ]; then
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
print('Jupyter password configured')
"
fi

# Start Jupyter Lab
jupyter lab --ip=0.0.0.0 --port=8888 --no-browser --allow-root
EOF_JUPYTER

chmod +x /home/opc/start-jupyter.sh
chown opc:opc /home/opc/start-jupyter.sh

echo "[STEP] create Oracle 23ai Free container service"
cat > /usr/local/bin/start-oracle23ai.sh << 'EOF_ORACLE'
#!/bin/bash
set -e

CONTAINER_NAME="oracle23ai-free"
IMAGE_NAME="container-registry.oracle.com/database/free:latest"

echo "Starting Oracle 23ai Free container setup..."

# Create persistent data directory
mkdir -p /home/opc/oradata
chown -R 54321:54321 /home/opc/oradata

# Pull the Oracle 23ai Free image
echo "Pulling Oracle 23ai Free image..."
podman pull $IMAGE_NAME

# Stop and remove existing container if it exists
podman stop $CONTAINER_NAME 2>/dev/null || true
podman rm $CONTAINER_NAME 2>/dev/null || true

# Start Oracle 23ai Free container
echo "Starting Oracle 23ai Free container..."
podman run -d \
  --name $CONTAINER_NAME \
  -p 1521:1521 \
  -p 5500:5500 \
  -e ORACLE_PWD=database123 \
  -e ORACLE_CHARACTERSET=AL32UTF8 \
  -v /home/opc/oradata:/opt/oracle/oradata \
  $IMAGE_NAME

echo "Oracle 23ai Free container started. Waiting for database to be ready..."

# Wait for database to be ready
for i in {1..60}; do
    if podman logs $CONTAINER_NAME 2>&1 | grep -q "DATABASE IS READY TO USE"; then
        echo "Oracle 23ai Free database is ready!"
        break
    fi
    if [ $i -eq 60 ]; then
        echo "Warning: Database may not be fully ready yet. Check logs with: podman logs $CONTAINER_NAME"
    fi
    sleep 10
done

echo "Oracle 23ai Free setup complete!"
EOF_ORACLE

chmod +x /usr/local/bin/start-oracle23ai.sh

echo "[STEP] create systemd service for Oracle 23ai"
cat > /etc/systemd/system/oracle23ai.service << 'EOF_SERVICE'
[Unit]
Description=Oracle 23ai Free Database Container
After=network.target

[Service]
Type=forking
User=root
ExecStart=/usr/local/bin/start-oracle23ai.sh
ExecStop=/usr/bin/podman stop oracle23ai-free
ExecReload=/usr/bin/podman restart oracle23ai-free
TimeoutStartSec=300
Restart=on-failure
RestartSec=30

[Install]
WantedBy=multi-user.target
EOF_SERVICE

# Enable and start Oracle service
systemctl daemon-reload
systemctl enable oracle23ai.service
systemctl start oracle23ai.service

echo "[STEP] download sample code and notebooks"
sudo -u opc bash -c '
cd /home/opc
git clone https://github.com/oracle-samples/oracle-db-examples.git sample-code || true
mkdir -p notebooks
cd notebooks

# Create sample notebook
cat > welcome.ipynb << EOF_NOTEBOOK
{
 "cells": [
  {
   "cell_type": "markdown",
   "metadata": {},
   "source": [
    "# Welcome to your GenAI Environment\\n",
    "\\n",
    "This environment includes:\\n",
    "- **Oracle 23ai Free** database with Vector Search capabilities\\n",
    "- **Python 3** with Jupyter Lab\\n",
    "- **Essential ML/AI libraries** (pandas, numpy, matplotlib, etc.)\\n",
    "- **Secure access** via OCI Bastion Service\\n",
    "\\n",
    "## Quick Start\\n",
    "\\n",
    "1. Test database connection\\n",
    "2. Explore sample datasets\\n",
    "3. Build your first AI application"
   ]
  },
  {
   "cell_type": "code",
   "execution_count": null,
   "metadata": {},
   "outputs": [],
   "source": [
    "import pandas as pd\\n",
    "import numpy as np\\n",
    "import matplotlib.pyplot as plt\\n",
    "\\n",
    "# Test basic functionality\\n",
    "print(\"Environment ready!\")\\n",
    "print(f\"Pandas version: {pd.__version__}\")\\n",
    "print(f\"NumPy version: {np.__version__}\")"
   ]
  }
 ],
 "metadata": {
  "kernelspec": {
   "display_name": "Python 3",
   "language": "python",
   "name": "python3"
  },
  "language_info": {
   "name": "python",
   "version": "3.9.0"
  }
 },
 "nbformat": 4,
 "nbformat_minor": 4
}
EOF_NOTEBOOK
'

echo "[STEP] setup complete - creating marker file"
touch "$MARKER"
echo "===== GenAI OneClick systemd: completed $(date -u) ====="
exit 0
EOF_GENAI_SETUP

chmod +x /usr/local/bin/genai-setup.sh

echo "[STEP] create systemd service for genai setup"
cat > /etc/systemd/system/genai-setup.service << 'EOF_SYSTEMD'
[Unit]
Description=GenAI Environment Setup
After=network.target
Wants=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/genai-setup.sh
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal
TimeoutStartSec=1800

[Install]
WantedBy=multi-user.target
EOF_SYSTEMD

# Enable and start the setup service
systemctl daemon-reload
systemctl enable genai-setup.service
systemctl start genai-setup.service

echo "===== Cloud-init setup complete. GenAI environment will be ready shortly. ====="
echo "Check setup progress with: sudo journalctl -u genai-setup.service -f"
