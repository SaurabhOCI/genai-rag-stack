#!/bin/bash
set -euxo pipefail

LOGFILE="/var/log/genai_setup.log"
exec > >(tee -a "$LOGFILE") 2>&1
echo "===== GenAI OneClick: start $(date -u) ====="

# growfs (best-effort)
if command -v /usr/libexec/oci-growfs >/dev/null 2>&1; then
  /usr/libexec/oci-growfs -y || true
fi

# ---- genai-setup.sh (main provisioning) ----
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
retry 5 dnf -y install \\
  git unzip jq tar make gcc gcc-c++ bzip2 bzip2-devel zlib-devel openssl-devel readline-devel libffi-devel \\
  wget curl which xz python3 python3-pip podman firewalld

echo "[STEP] enable firewalld"
systemctl enable --now firewalld || true

echo "[STEP] create /opt/genai and /home/opc/labs"
mkdir -p /opt/genai /home/opc/labs /home/opc/bin
chown -R opc:opc /opt/genai /home/opc/labs /home/opc/bin

echo "[STEP] create /opt/code and fetch css-navigator/gen-ai"
mkdir -p /opt/code

# preflight: ensure tools exist
if ! command -v git >/dev/null 2>&1;   then retry 5 dnf -y install git;   fi
if ! command -v curl >/dev/null 2>&1;  then retry 5 dnf -y install curl;  fi
if ! command -v unzip >/dev/null 2>&1; then retry 5 dnf -y install unzip; fi

TMP_DIR="$(mktemp -d)"
REPO_ZIP="/tmp/cssnav.zip"

# If we got content via sparse-checkout, copy it
if [ -d "$TMP_DIR/gen-ai" ] && [ -n "$(ls -A "$TMP_DIR/gen-ai" 2>/dev/null)" ]; then
  echo "[STEP] copying from sparse-checkout"
  # make sure source is traversable (some tmp contexts are restrictive)
  chmod -R a+rx "$TMP_DIR/gen-ai" || true
  # try rsync, but fall back to cp if rsync hits permission/selinux issues
  if command -v rsync >/dev/null 2>&1; then
    rsync -a "$TMP_DIR/gen-ai"/ /opt/code/ || cp -a "$TMP_DIR/gen-ai"/. /opt/code/
  else
    cp -a "$TMP_DIR/gen-ai"/. /opt/code/
  fi
else
  # Fallback: download repo zip and extract only gen-ai
  echo "[STEP] sparse-checkout empty; falling back to zip"
  retry 5 curl -L -o "$REPO_ZIP" https://codeload.github.com/ou-developers/css-navigator/zip/refs/heads/main
  TMP_ZIP_DIR="$(mktemp -d)"
  unzip -q -o "$REPO_ZIP" -d "$TMP_ZIP_DIR"
  if [ -d "$TMP_ZIP_DIR/css-navigator-main/gen-ai" ]; then
    chmod -R a+rx "$TMP_ZIP_DIR/css-navigator-main/gen-ai" || true
    cp -a "$TMP_ZIP_DIR/css-navigator-main/gen-ai"/. /opt/code/
  else
    echo "[WARN] gen-ai folder not found in zip"
  fi
  rm -rf "$TMP_ZIP_DIR" "$REPO_ZIP"
fi

rm -rf "$TMP_DIR"
chown -R opc:opc /opt/code || true
chmod -R a+rX /opt/code || true

echo "[STEP] embed user's init-genailabs.sh"
cat >/opt/genai/init-genailabs.sh <<'USERSCRIPT'
#!/bin/bash

# Define a log file for capturing all output
LOGFILE=/var/log/cloud-init-output.log
exec > >(tee -a $LOGFILE) 2>&1

# Marker file to ensure the script only runs once
MARKER_FILE="/home/opc/.init_done"

# Check if the marker file exists
if [ -f "$MARKER_FILE" ]; then
  echo "Init script has already been run. Exiting."
  exit 0
fi

echo "===== Starting Cloud-Init Script ====="

# Expand the boot volume
echo "Expanding boot volume..."
sudo /usr/libexec/oci-growfs -y

# Enable ol8_addons and install necessary development tools
echo "Installing required packages..."
sudo dnf config-manager --set-enabled ol8_addons
sudo dnf install -y podman git libffi-devel bzip2-devel ncurses-devel readline-devel wget make gcc zlib-devel openssl-devel

# Install the latest SQLite from source
echo "Installing latest SQLite..."
cd /tmp
wget https://www.sqlite.org/2023/sqlite-autoconf-3430000.tar.gz
tar -xvzf sqlite-autoconf-3430000.tar.gz
cd sqlite-autoconf-3430000
./configure --prefix=/usr/local
make
sudo make install

# Verify the installation of SQLite
echo "SQLite version:"
/usr/local/bin/sqlite3 --version

# Ensure the correct version is in the path and globally
export PATH="/usr/local/bin:$PATH"
export LD_LIBRARY_PATH="/usr/local/lib:$LD_LIBRARY_PATH"
echo 'export PATH="/usr/local/bin:$PATH"' >> /home/opc/.bashrc
echo 'export LD_LIBRARY_PATH="/usr/local/lib:$LD_LIBRARY_PATH"' >> /home/opc/.bashrc

# Set environment variables to link the newly installed SQLite with Python build globally
echo 'export CFLAGS="-I/usr/local/include"' >> /home/opc/.bashrc
echo 'export LDFLAGS="-L/usr/local/lib"' >> /home/opc/.bashrc

# Source the updated ~/.bashrc to apply changes globally
source /home/opc/.bashrc

# Create a persistent volume directory for Oracle data
echo "Creating Oracle data directory..."
sudo mkdir -p /home/opc/oradata
echo "Setting up permissions for the Oracle data directory..."
sudo chown -R 54321:54321 /home/opc/oradata
sudo chmod -R 755 /home/opc/oradata

# Run the Oracle Database Free Edition container
echo "Running Oracle Database container..."
sudo podman run -d \
    --name 23ai \
    --network=host \
    -e ORACLE_PWD=database123 \
    -v /home/opc/oradata:/opt/oracle/oradata:z \
    container-registry.oracle.com/database/free:latest

# Wait for Oracle Container to start
echo "Waiting for Oracle container to initialize..."
sleep 10

# Check if the listener is up and if the freepdb1 service is registered
echo "Checking if service freepdb1 is registered with the listener..."
while ! sudo podman exec 23ai bash -c "lsnrctl status | grep -q freepdb1"; do
  echo "Waiting for freepdb1 service to be registered with the listener..."
  sleep 30
done
echo "freepdb1 service is registered with the listener."

# Retry loop for Oracle login with error detection
MAX_RETRIES=5
RETRY_COUNT=0
DELAY=10

while true; do
  OUTPUT=$(sudo podman exec 23ai bash -c "sqlplus -S sys/database123@localhost:1521/freepdb1 as sysdba <<EOF
EXIT;
EOF")

  if [[ "$OUTPUT" == *"ORA-01017"* || "$OUTPUT" == *"ORA-01005"* ]]; then
    RETRY_COUNT=$((RETRY_COUNT + 1))
    echo "Attempt $RETRY_COUNT: Oracle credential error. Retrying in $DELAY seconds..."
  elif [[ "$OUTPUT" == *"ORA-"* ]]; then
    RETRY_COUNT=$((RETRY_COUNT + 1))
    echo "Attempt $RETRY_COUNT: Oracle connection error. Retrying in $DELAY seconds..."
  else
    echo "Oracle Database is available."
    break
  fi

  if [ "$RETRY_COUNT" -ge "$MAX_RETRIES" ]; then
    echo "Max retries reached. Unable to connect to Oracle Database."
    echo "Error output: $OUTPUT"
    exit 1
  fi

  sleep $DELAY
done

# Run the SQL commands to configure the PDB
echo "Configuring Oracle database in PDB (freepdb1)..."
sudo podman exec -i 23ai bash <<EOF
sqlplus -S sys/database123@localhost:1521/freepdb1 as sysdba <<EOSQL
CREATE BIGFILE TABLESPACE tbs2 DATAFILE 'bigtbs_f2.dbf' SIZE 1G AUTOEXTEND ON NEXT 32M MAXSIZE UNLIMITED EXTENT MANAGEMENT LOCAL SEGMENT SPACE MANAGEMENT AUTO;
CREATE UNDO TABLESPACE undots2 DATAFILE 'undotbs_2a.dbf' SIZE 1G AUTOEXTEND ON RETENTION GUARANTEE;
CREATE TEMPORARY TABLESPACE temp_demo TEMPFILE 'temp02.dbf' SIZE 1G REUSE AUTOEXTEND ON NEXT 32M MAXSIZE UNLIMITED EXTENT MANAGEMENT LOCAL UNIFORM SIZE 1M;
CREATE USER vector IDENTIFIED BY vector DEFAULT TABLESPACE tbs2 QUOTA UNLIMITED ON tbs2;
GRANT DB_DEVELOPER_ROLE TO vector;
EXIT;
EOSQL
EOF

# Reconnect to CDB root to apply system-level changes
echo "Switching to CDB root for system-level changes..."
sudo podman exec -i 23ai bash <<EOF
sqlplus -S / as sysdba <<EOSQL
CREATE PFILE FROM SPFILE;
ALTER SYSTEM SET vector_memory_size = 512M SCOPE=SPFILE;
SHUTDOWN IMMEDIATE;
STARTUP;
EXIT;
EOSQL
EOF

# Wait for Oracle to restart and apply memory changes
sleep 10

echo "Skipping vector_memory_size check. Assuming it is set to 512M based on startup logs."

# Now switch to opc for user-specific tasks
sudo -u opc -i bash <<'EOF_OPC'

# Set environment variables
export HOME=/home/opc
export PYENV_ROOT="$HOME/.pyenv"
curl https://pyenv.run | bash

# Add pyenv initialization to ~/.bashrc for opc
cat << EOF >> $HOME/.bashrc
export PYENV_ROOT="\$HOME/.pyenv"
[[ -d "\$PYENV_ROOT/bin" ]] && export PATH="\$PYENV_ROOT/bin:\$PATH"
eval "\$(pyenv init --path)"
eval "\$(pyenv init -)"
eval "\$(pyenv virtualenv-init -)"
EOF

# Ensure .bashrc is sourced on login
cat << EOF >> $HOME/.bash_profile
if [ -f ~/.bashrc ]; then
   source ~/.bashrc
fi
EOF

# Source the updated ~/.bashrc to apply pyenv changes
source $HOME/.bashrc

# Export PATH to ensure pyenv is correctly initialized
export PATH="$PYENV_ROOT/bin:$PATH"

# Install Python 3.11.9 using pyenv with the correct SQLite version linked
CFLAGS="-I/usr/local/include" LDFLAGS="-L/usr/local/lib" LD_LIBRARY_PATH="/usr/local/lib" pyenv install 3.11.9

# Rehash pyenv to update shims
pyenv rehash

# Set up vectors directory and Python 3.11.9 environment
mkdir -p $HOME/labs
cd $HOME/labs
pyenv local 3.11.9

# Rehash again to ensure shims are up to date
pyenv rehash

# Verify Python version in the labs directory
python --version

# Adding the PYTHONPATH for correct installation and look up for the libraries
export PYTHONPATH=$HOME/.pyenv/versions/3.11.9/lib/python3.11/site-packages:$PYTHONPATH

# Install required Python packages
$HOME/.pyenv/versions/3.11.9/bin/pip install --no-cache-dir oci==2.129.1 oracledb sentence-transformers langchain==0.2.6 langchain-community==0.2.6 langchain-chroma==0.1.2 langchain-core==0.2.11 langchain-text-splitters==0.2.2 langsmith==0.1.83 pypdf==4.2.0 streamlit==1.36.0 python-multipart==0.0.9 chroma-hnswlib==0.7.3 chromadb==0.5.3 torch==2.5.0

# Download the model during script execution
python -c "from sentence_transformers import SentenceTransformer; SentenceTransformer('all-MiniLM-L12-v2')"

# Install JupyterLab
pip install --user jupyterlab

# Install OCI CLI
echo "Installing OCI CLI..."
curl -L https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.sh -o install.sh
chmod +x install.sh
./install.sh --accept-all-defaults

# Verify the installation
echo "Verifying OCI CLI installation..."
oci --version || { echo "OCI CLI installation failed."; exit 1; }

# Ensure all the binaries are added to PATH
echo 'export PATH=$PATH:$HOME/.local/bin' >> $HOME/.bashrc
source $HOME/.bashrc

# Copy files from the git repo labs folder to the labs directory in the instance
echo "Copying files from the 'labs' folder in the OU Git repository to the existing labs directory..."
REPO_URL="https://github.com/ou-developers/ou-generativeai-pro.git"
FINAL_DIR="$HOME/labs"  # Existing directory on your instance

# Initialize a new git repository
git init

# Add the remote repository
git remote add origin $REPO_URL

# Enable sparse-checkout and specify the folder to download
git config core.sparseCheckout true
echo "labs/*" >> .git/info/sparse-checkout

# Pull only the specified folder into the existing directory
git pull origin main  # Replace 'main' with the correct branch name if necessary

# Move the contents of the 'labs' subfolder to the root of FINAL_DIR, if necessary
mv labs/* . 2>/dev/null || true  # Move files if 'labs' folder exists

# Remove any remaining empty 'labs' directory and .git folder
rm -rf .git labs

echo "Files successfully downloaded to $FINAL_DIR"

EOF_OPC

# Create the marker file to indicate the script has been run
touch "$MARKER_FILE"

echo "===== Cloud-Init Script Completed Successfully ====="
exit 0

USERSCRIPT
chmod +x /opt/genai/init-genailabs.sh
cp -f /opt/genai/init-genailabs.sh /home/opc/init-genailabs.sh || true
chown opc:opc /home/opc/init-genailabs.sh || true

echo "[STEP] install Python 3.9 for OL8 and create venv"
retry 5 dnf -y module enable python39 || true
retry 5 dnf -y install python39 python39-pip
sudo -u opc bash -lc 'python3.9 -m venv $HOME/.venvs/genai || true; echo "source $HOME/.venvs/genai/bin/activate" >> $HOME/.bashrc; source $HOME/.venvs/genai/bin/activate; python -m pip install --upgrade pip wheel setuptools'
echo "[STEP] install Python libraries"
sudo -u opc bash -lc 'source $HOME/.venvs/genai/bin/activate; pip install --no-cache-dir jupyterlab==4.2.5 streamlit==1.36.0 oracledb sentence-transformers langchain==0.2.6 langchain-community==0.2.6 langchain-core==0.2.11 langchain-text-splitters==0.2.2 langsmith==0.1.83 pypdf==4.2.0 python-multipart==0.0.9 chroma-hnswlib==0.7.3 chromadb==0.5.3 torch==2.5.0 oci oracle-ads'

echo "[STEP] install OCI CLI to ~/bin/oci and make PATH global"
sudo -u opc bash -lc 'retry 5 curl -sSL https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.sh -o /tmp/oci-install.sh; retry 5 bash /tmp/oci-install.sh --accept-all-defaults --exec-dir $HOME/bin --install-dir $HOME/lib/oci-cli --update-path false; grep -q "export PATH=$HOME/bin" $HOME/.bashrc || echo "export PATH=$HOME/bin:$PATH" >> $HOME/.bashrc'
cat >/etc/profile.d/genai-path.sh <<'PROF'
export PATH=/home/opc/bin:$PATH
PROF

echo "[STEP] seed /opt/genai content"
cat >/opt/genai/LoadProperties.py <<'PY'
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
PY
cat >/opt/genai/config.txt <<'CFG'
{"model_name":"cohere.command-r-16k","embedding_model_name":"cohere.embed-english-v3.0","endpoint":"https://inference.generativeai.eu-frankfurt-1.oci.oraclecloud.com","compartment_ocid":"ocid1.compartment.oc1....replace_me..."}
CFG
mkdir -p /opt/genai/txt-docs /opt/genai/pdf-docs
echo "faq | What are Always Free services?=====Always Free services are part of Oracle Cloud Free Tier." >/opt/genai/txt-docs/faq.txt
chown -R opc:opc /opt/genai

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

echo "[STEP] run user's init-genailabs.sh (non-fatal)"
set +e
bash /opt/genai/init-genailabs.sh
USR_RC=$?
set -e
echo "[STEP] user init script exit code: $USR_RC"

touch "$MARKER"
echo "===== GenAI OneClick systemd: COMPLETE $(date -u) ====="
SCRIPT
chmod +x /usr/local/bin/genai-setup.sh

# ---- genai-db.sh (DB container) ----
cat >/usr/local/bin/genai-db.sh <<'DBSCR'
#!/bin/bash
set -uxo pipefail
echo "[DB] starting podman tasks $(date -u)"
retry() { local max=${1:-5}; shift; local n=1; until "$@"; do rc=$?; [[ $n -ge $max ]] && echo "[RETRY] failed after $n: $*" && return $rc; echo "[RETRY] $n -> retrying in $((n*5))s: $*"; sleep $((n*5)); n=$((n+1)); done; return 0; }
retry 5 podman pull container-registry.oracle.com/database/free:latest || true
podman rm -f 23ai || true
mkdir -p /home/opc/oradata && chown -R 54321:54321 /home/opc/oradata
podman run -d --name 23ai --network=host -e ORACLE_PWD=database123 -v /home/opc/oradata:/opt/oracle/oradata:z container-registry.oracle.com/database/free:latest || true
echo "[DB] done $(date -u)"
DBSCR
chmod +x /usr/local/bin/genai-db.sh

# ---- systemd units ----
cat >/etc/systemd/system/genai-setup.service <<'UNIT1'
[Unit]
Description=GenAI oneclick post-boot setup
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -lc '/usr/local/bin/genai-setup.sh >> /var/log/genai_setup.log 2>&1'
Restart=no

[Install]
WantedBy=multi-user.target
UNIT1

cat >/etc/systemd/system/genai-23ai.service <<'UNIT2'
[Unit]
Description=GenAI oneclick - Oracle 23ai container
Wants=network-online.target
After=network-online.target genai-setup.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -lc '/usr/local/bin/genai-db.sh >> /var/log/genai_setup.log 2>&1'
Restart=no

[Install]
WantedBy=multi-user.target
UNIT2

systemctl daemon-reload
systemctl enable genai-setup.service
systemctl enable genai-23ai.service
systemctl start genai-setup.service
systemctl start genai-23ai.service

echo "===== GenAI OneClick: cloud-init done $(date -u) ====="
