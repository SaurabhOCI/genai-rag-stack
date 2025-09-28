#!/bin/bash
# cloudinit.sh — Oracle 23ai Free + GenAI stack bootstrap with Bastion support
# - Enhanced for private subnet deployment with Bastion Service
# - Configurable Jupyter authentication
# - Improved error handling and logging
# - Direct execution without systemd dependencies

set -Eeuo pipefail

LOGFILE="/var/log/genai_setup.log"
exec > >(tee -a "$LOGFILE") 2>&1
echo "===== GenAI OneClick with Bastion: start $(date -u) ====="

# Template variables
JUPYTER_ENABLE_AUTH="${jupyter_enable_auth}"
JUPYTER_PASSWORD="${jupyter_password}"
BASTION_ENABLED="${bastion_enabled}"

# Set marker file path
MARKER="/var/lib/genai.oneclick.done"

# Exit if already completed
if [[ -f "$MARKER" ]]; then
  echo "[INFO] Setup already completed. Exiting."
  exit 0
fi

# Utility function for retries
retry() { 
    local max=$${1:-5}; shift; local n=1; 
    until "$@"; do 
        rc=$?; 
        [[ $n -ge $max ]] && echo "[RETRY] failed after $n: $*" && return $rc; 
        echo "[RETRY] $n -> retrying in $((n*5))s: $*"; 
        sleep $((n*5)); 
        n=$((n+1)); 
    done; 
    return 0; 
}

# --------------------------------------------------------------------
# Grow filesystem (best-effort)
# --------------------------------------------------------------------
echo "[STEP] Growing filesystem"
if command -v /usr/libexec/oci-growfs >/dev/null 2>&1; then
  /usr/libexec/oci-growfs -y || true
fi

# --------------------------------------------------------------------
# Install base packages
# --------------------------------------------------------------------
echo "[STEP] Installing base packages with Podman"

# Disable problematic repositories
dnf config-manager --set-disabled ol8_ksplice || true

# Clean and refresh cache
dnf clean all || true
dnf makecache --refresh || true

# Enable required repositories
dnf config-manager --set-enabled ol8_addons || true
dnf config-manager --set-enabled ol8_appstream || true
dnf config-manager --set-enabled ol8_baseos_latest || true

# Install core packages with retries
echo "[STEP] Installing essential packages"
retry 5 dnf -y install \
  podman curl grep coreutils shadow-utils git unzip \
  dnf-plugins-core jq tar make gcc gcc-c++ \
  bzip2 bzip2-devel zlib-devel openssl-devel readline-devel libffi-devel \
  wget which xz python3 python3-pip python39 python39-pip firewalld

echo "[STEP] Verifying Podman installation"
if ! command -v podman >/dev/null 2>&1; then
    echo "[ERROR] Podman installation failed"
    exit 1
fi

podman --version
echo "[SUCCESS] Podman and base packages installed"

# --------------------------------------------------------------------
# Enable firewalld
# --------------------------------------------------------------------
echo "[STEP] Enabling firewalld"
systemctl enable --now firewalld || true

# --------------------------------------------------------------------
# Create directory structure
# --------------------------------------------------------------------
echo "[STEP] Creating directory structure"
mkdir -p /opt/genai /home/opc/{code,bin,scripts,.venvs,notebooks,oradata}
chown -R opc:opc /opt/genai /home/opc/code /home/opc/bin /home/opc/scripts /home/opc/.venvs /home/opc/notebooks

# Set proper permissions for Oracle data directory
chown -R 54321:54321 /home/opc/oradata || true
chmod -R 755 /home/opc/oradata

# --------------------------------------------------------------------
# Create bastion helper scripts (if enabled)
# --------------------------------------------------------------------
if [ "$BASTION_ENABLED" = "true" ]; then
echo "[STEP] Creating bastion helper scripts"
cat > /home/opc/scripts/bastion-info.sh << 'BASTION_INFO_SCRIPT'
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
BASTION_INFO_SCRIPT

chmod +x /home/opc/scripts/bastion-info.sh
chown opc:opc /home/opc/scripts/bastion-info.sh

# Add to .bashrc
echo "echo 'Run ~/scripts/bastion-info.sh for connection information'" >> /home/opc/.bashrc
fi

# --------------------------------------------------------------------
# Create Python virtual environment and install packages
# --------------------------------------------------------------------
echo "[STEP] Creating Python virtual environment"
sudo -u opc bash << 'PYTHON_SETUP'
set -e
export HOME=/home/opc
cd $HOME

echo "Creating virtual environment..."
python3 -m venv $HOME/.venvs/genai

echo "Activating virtual environment..."
source $HOME/.venvs/genai/bin/activate

echo "Upgrading pip..."
pip install --upgrade pip wheel setuptools

echo "Installing Python packages..."
pip install --no-cache-dir \
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
  oracledb \
  plotly \
  scikit-learn

echo "Python environment setup complete"
PYTHON_SETUP

# Add virtual environment activation to .bashrc
echo 'source ~/.venvs/genai/bin/activate' >> /home/opc/.bashrc
chown opc:opc /home/opc/.bashrc

echo "[SUCCESS] Python virtual environment created with Jupyter Lab"

# --------------------------------------------------------------------
# Create Jupyter startup script
# --------------------------------------------------------------------
echo "[STEP] Creating Jupyter startup script"
cat > /home/opc/start-jupyter.sh << 'JUPYTER_STARTUP'
#!/bin/bash
source ~/.venvs/genai/bin/activate
export JUPYTER_CONFIG_DIR=/home/opc/.jupyter

# Create jupyter config directory
mkdir -p $JUPYTER_CONFIG_DIR

# Generate Jupyter config if it doesn't exist
if [ ! -f $JUPYTER_CONFIG_DIR/jupyter_lab_config.py ]; then
    jupyter lab --generate-config
fi
JUPYTER_STARTUP

# Add Jupyter authentication if enabled
if [ "$JUPYTER_ENABLE_AUTH" = "true" ] && [ -n "$JUPYTER_PASSWORD" ]; then
cat >> /home/opc/start-jupyter.sh << JUPYTER_AUTH_SECTION

# Configure password authentication
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
JUPYTER_AUTH_SECTION
fi

cat >> /home/opc/start-jupyter.sh << 'JUPYTER_STARTUP_END'

# Start Jupyter Lab
echo "Starting Jupyter Lab..."
jupyter lab --ip=0.0.0.0 --port=8888 --no-browser --allow-root
JUPYTER_STARTUP_END

chmod +x /home/opc/start-jupyter.sh
chown opc:opc /home/opc/start-jupyter.sh

echo "[SUCCESS] Jupyter startup script created"

# --------------------------------------------------------------------
# Create Oracle 23ai container setup
# --------------------------------------------------------------------
echo "[STEP] Creating Oracle 23ai container setup"
cat > /usr/local/bin/start-oracle23ai.sh << 'ORACLE_SCRIPT'
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

echo "Oracle 23ai Free container started. Database will be ready in a few minutes."
echo "Check status with: podman logs $CONTAINER_NAME"
ORACLE_SCRIPT

chmod +x /usr/local/bin/start-oracle23ai.sh

# Start Oracle 23ai in the background
echo "[STEP] Starting Oracle 23ai container"
nohup /usr/local/bin/start-oracle23ai.sh > /var/log/oracle23ai-setup.log 2>&1 &

echo "[SUCCESS] Oracle 23ai container setup initiated"

# --------------------------------------------------------------------
# Download sample code and create welcome notebook
# --------------------------------------------------------------------
echo "[STEP] Setting up sample code and notebooks"
sudo -u opc bash << 'SAMPLE_SETUP'
cd /home/opc

# Clone sample code repository
git clone https://github.com/oracle-samples/oracle-db-examples.git sample-code || true

# Create sample notebooks
cd notebooks

# Create welcome notebook
cat > welcome.ipynb << 'NOTEBOOK_JSON'
{
 "cells": [
  {
   "cell_type": "markdown",
   "metadata": {},
   "source": [
    "# Welcome to your GenAI Environment\n",
    "\n",
    "This environment includes:\n",
    "- **Oracle 23ai Free** database with Vector Search capabilities\n",
    "- **Python 3** with Jupyter Lab\n",
    "- **Essential ML/AI libraries** (pandas, numpy, matplotlib, etc.)\n",
    "- **Secure access** via OCI Bastion Service\n",
    "\n",
    "## Quick Start\n",
    "\n",
    "1. Test database connection\n",
    "2. Explore sample datasets\n",
    "3. Build your first AI application"
   ]
  },
  {
   "cell_type": "code",
   "execution_count": null,
   "metadata": {},
   "outputs": [],
   "source": [
    "import pandas as pd\n",
    "import numpy as np\n",
    "import matplotlib.pyplot as plt\n",
    "\n",
    "# Test basic functionality\n",
    "print(\"Environment ready!\")\n",
    "print(f\"Pandas version: {pd.__version__}\")\n",
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
NOTEBOOK_JSON

echo "Sample notebooks created"
SAMPLE_SETUP

echo "[SUCCESS] Sample code and notebooks setup complete"

# --------------------------------------------------------------------
# Final verification and completion
# --------------------------------------------------------------------
echo "[STEP] Performing final verification"

# Verify Jupyter installation
sudo -u opc bash -c 'source ~/.venvs/genai/bin/activate && jupyter --version' || {
    echo "[ERROR] Jupyter verification failed"
    exit 1
}

# Verify essential Python packages
sudo -u opc bash -c 'source ~/.venvs/genai/bin/activate && python -c "import pandas, numpy, matplotlib; print(\"Essential packages verified\")"' || {
    echo "[ERROR] Python packages verification failed"
    exit 1
}

echo "[SUCCESS] All verifications passed"

# Create completion marker
touch "$MARKER"
echo "Setup completed at: $(date -u)" > "$MARKER"

echo "===== GenAI OneClick setup completed successfully: $(date -u) ====="
echo "Environment ready for use!"
echo ""
echo "To start Jupyter Lab: ./start-jupyter.sh"
echo "To check Oracle DB: podman logs oracle23ai-free"
if [ "$BASTION_ENABLED" = "true" ]; then
echo "For connection info: ~/scripts/bastion-info.sh"
fi
