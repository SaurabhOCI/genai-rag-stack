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

echo "[STEP] create /opt/genai and /home/opc directories"
mkdir -p /opt/genai /home/opc/code /home/opc/bin /home/opc/scripts
chown -R opc:opc /opt/genai /home/opc/code /home/opc/bin /home/opc/scripts

echo "[STEP] create bastion helper scripts"
if [ "$BASTION_ENABLED" = "true" ]; then
  cat > /home/opc/scripts/bastion-info.sh <<'BASTION_INFO'
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
BASTION_INFO

  chmod +x /home/opc/scripts/bastion-info.sh
  chown opc:opc /home/opc/scripts/bastion-info.sh
  
  # Add to .bashrc
  echo "echo 'Run ~/scripts/bastion-info.sh for connection information'" >> /home/opc/.bashrc
fi

echo "[STEP] fetch code repository"
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

echo "[STEP] embed enhanced init-genailabs.sh"
cat >/opt/genai/init-genailabs.sh <<'USERSCRIPT'
#!/bin/bash
set -Eeuo pipefail
LOGFILE=/var/log/cloud-init-output.log
exec > >(tee -a $LOGFILE) 2>&1

MARKER_FILE="/home/opc/.init_done"
if [ -f "$MARKER_FILE" ]; then
  echo "Init script has already been run. Exiting."
  exit 0
fi

echo "===== Starting Enhanced Cloud-Init User Script ====="

# Expand the boot volume (best-effort)
sudo /usr/libexec/oci-growfs -y || true

# Ensure build prerequisites
sudo dnf config-manager --set-enabled ol8_addons || true
sudo dnf install -y podman git libffi-devel bzip2-devel ncurses-devel readline-devel wget make gcc zlib-devel openssl-devel || true

# Install latest SQLite from source
cd /tmp
wget -q https://www.sqlite.org/2023/sqlite-autoconf-3430000.tar.gz
tar -xzf sqlite-autoconf-3430000.tar.gz
cd sqlite-autoconf-3430000
./configure --prefix=/usr/local
make -s
sudo make install

# Verify SQLite
/usr/local/bin/sqlite3 --version || true

# PATH/LD for SQLite
echo 'export PATH="/usr/local/bin:$PATH"' >> /home/opc/.bashrc
echo 'export LD_LIBRARY_PATH="/usr/local/lib:$LD_LIBRARY_PATH"' >> /home/opc/.bashrc
echo 'export CFLAGS="-I/usr/local/include"' >> /home/opc/.bashrc
echo 'export LDFLAGS="-L/usr/local/lib"' >> /home/opc/.bashrc
source /home/opc/.bashrc

# Persistent oradata
sudo mkdir -p /home/opc/oradata
sudo chown -R 54321:54321 /home/opc/oradata
sudo chmod -R 755 /home/opc/oradata

# Wait for 23ai container to exist and be ready
echo "Waiting for 23ai container to be created..."
for i in {1..120}; do
  if /usr/bin/podman ps -a --format '{{.Names}}' | grep -qw 23ai; then
    echo "23ai container exists."
    break
  fi
  sleep 5
done

echo "Waiting for FREEPDB1 service to be registered with the listener..."
for i in {1..180}; do
  if /usr/bin/podman exec 23ai bash -lc '. /home/oracle/.bashrc; lsnrctl status' | grep -qi 'Service "FREEPDB1"'; then
    echo "FREEPDB1 service is registered."
    break
  fi
  sleep 10
done

# Quick connection smoke test
OUTPUT=$(/usr/bin/podman exec 23ai bash -lc 'echo | sqlplus -S -L sys/database123@127.0.0.1:1521/FREEPDB1 as sysdba || true')
echo "$OUTPUT" | tail -n 2

# Enhanced PDB configuration
echo "Configuring Oracle database in PDB (FREEPDB1)..."
sudo /usr/bin/podman exec -i 23ai bash -lc '. /home/oracle/.bashrc; sqlplus -S -L "sys:database123@127.0.0.1:1521/FREEPDB1 as sysdba" <<EOSQL
WHENEVER SQLERROR CONTINUE
CREATE BIGFILE TABLESPACE tbs2 DATAFILE ''bigtbs_f2.dbf'' SIZE 1G AUTOEXTEND ON NEXT 32M MAXSIZE UNLIMITED EXTENT MANAGEMENT LOCAL SEGMENT SPACE MANAGEMENT AUTO;
CREATE UNDO TABLESPACE undots2 DATAFILE ''undotbs_2a.dbf'' SIZE 1G AUTOEXTEND ON RETENTION GUARANTEE;
CREATE TEMPORARY TABLESPACE temp_demo TEMPFILE ''temp02.dbf'' SIZE 1G REUSE AUTOEXTEND ON NEXT 32M MAXSIZE UNLIMITED EXTENT MANAGEMENT LOCAL UNIFORM SIZE 1M;
-- Ensure vector user exists with enhanced permissions
CREATE USER vector IDENTIFIED BY "vector" DEFAULT TABLESPACE tbs2 QUOTA UNLIMITED ON tbs2;
GRANT CREATE SESSION, CREATE TABLE, CREATE SEQUENCE, CREATE VIEW, CREATE PROCEDURE TO vector;
GRANT UNLIMITED TABLESPACE TO vector;
-- Enable AI Vector Search capabilities
ALTER USER vector QUOTA UNLIMITED ON tbs2;
EXIT
EOSQL'

# Enhanced pyenv + Python 3.11.9 setup
sudo -u opc -i bash <<'EOF_OPC'
set -eux
export HOME=/home/opc
export PYENV_ROOT="$HOME/.pyenv"
curl -sS https://pyenv.run | bash

cat << EOF >> $HOME/.bashrc
export PYENV_ROOT="\$HOME/.pyenv"
[[ -d "\$PYENV_ROOT/bin" ]] && export PATH="\$PYENV_ROOT/bin:\$PATH"
eval "\$(pyenv init --path)"
eval "\$(pyenv init -)"
eval "\$(pyenv virtualenv-init -)"
EOF

cat << EOF >> $HOME/.bash_profile
if [ -f ~/.bashrc ]; then
   source ~/.bashrc
fi
EOF

source $HOME/.bashrc
export PATH="$PYENV_ROOT/bin:$PATH"

CFLAGS="-I/usr/local/include" LDFLAGS="-L/usr/local/lib" LD_LIBRARY_PATH="/usr/local/lib" pyenv install -s 3.11.9
pyenv rehash
mkdir -p $HOME/labs
cd $HOME/labs
pyenv local 3.11.9
pyenv rehash
python --version

# Enhanced Python package installation
$HOME/.pyenv/versions/3.11.9/bin/pip install --no-cache-dir \
  oci==2.129.1 \
  oracledb \
  sentence-transformers \
  langchain==0.2.6 \
  langchain-community==0.2.6 \
  langchain-chroma==0.1.2 \
  langchain-core==0.2.11 \
  langchain-text-splitters==0.2.2 \
  langsmith==0.1.83 \
  pypdf==4.2.0 \
  streamlit==1.36.0 \
  python-multipart==0.0.9 \
  chroma-hnswlib==0.7.3 \
  chromadb==0.5.3 \
  torch==2.5.0 \
  gradio \
  fastapi \
  uvicorn

# Pre-download models
python - <<PY
from sentence_transformers import SentenceTransformer
print("Downloading embedding model...")
SentenceTransformer('all-MiniLM-L12-v2')
print("Model download complete.")
PY

pip install --user jupyterlab
curl -sSL https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.sh -o install.sh
chmod +x install.sh
./install.sh --accept-all-defaults
echo 'export PATH=$PATH:$HOME/.local/bin' >> $HOME/.bashrc
source $HOME/.bashrc

# Enhanced repository setup
REPO_URL="https://github.com/ou-developers/ou-generativeai-pro.git"
FINAL_DIR="$HOME/labs"
git init
git remote add origin $REPO_URL
git config core.sparseCheckout true
echo "labs/*" >> .git/info/sparse-checkout
git pull origin main || true
mv labs/* . 2>/dev/null || true
rm -rf .git labs
echo "Files successfully downloaded to $FINAL_DIR"
EOF_OPC

touch "$MARKER_FILE"
echo "===== Enhanced Cloud-Init User Script Completed Successfully ====="
exit 0
USERSCRIPT
chmod +x /opt/genai/init-genailabs.sh
cp -f /opt/genai/init-genailabs.sh /home/opc/init-genailabs.sh || true
chown opc:opc /home/opc/init-genailabs.sh || true

echo "[STEP] install Python 3.9 for OL8 and create enhanced venv"
retry 5 dnf -y module enable python39 || true
retry 5 dnf -y install python39 python39-pip
sudo -u opc bash -lc 'python3.9 -m venv $HOME/.venvs/genai || true; echo "source $HOME/.venvs/genai/bin/activate" >> $HOME/.bashrc; source $HOME/.venvs/genai/bin/activate; python -m pip install --upgrade pip wheel setuptools'

echo "[STEP] install enhanced Python libraries"
sudo -u opc bash -lc 'source $HOME/.venvs/genai/bin/activate; pip install --no-cache-dir \
  jupyterlab==4.2.5 \
  streamlit==1.36.0 \
  oracledb \
  sentence-transformers \
  langchain==0.2.6 \
  langchain-community==0.2.6 \
  langchain-core==0.2.11 \
  langchain-text-splitters==0.2.2 \
  langsmith==0.1.83 \
  pypdf==4.2.0 \
  python-multipart==0.0.9 \
  chroma-hnswlib==0.7.3 \
  chromadb==0.5.3 \
  torch==2.5.0 \
  oci \
  oracle-ads \
  gradio \
  fastapi \
  uvicorn'

echo "[STEP] install OCI CLI to ~/bin/oci and make PATH global"
sudo -u opc bash -lc 'retry 5 curl -sSL https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.sh -o /tmp/oci-install.sh; retry 5 bash /tmp/oci-install.sh --accept-all-defaults --exec-dir $HOME/bin --install-dir $HOME/lib/oci-cli --update-path false; grep -q "export PATH=$HOME/bin" $HOME/.bashrc || echo "export PATH=$HOME/bin:$PATH" >> $HOME/.bashrc'
cat >/etc/profile.d/genai-path.sh <<'PROF'
export PATH=/home/opc/bin:$PATH
PROF

echo "[STEP] seed enhanced /opt/genai content"
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

echo "[STEP] write enhanced start_jupyter.sh with authentication support"
if [ "$JUPYTER_ENABLE_AUTH" = "true" ] && [ -n "$JUPYTER_PASSWORD" ]; then
  # Generate password hash
  JUPYTER_PASSWORD_HASH=$(sudo -u opc bash -lc "source \$HOME/.venvs/genai/bin/activate; python3 -c \"
from jupyter_server.auth import passwd
print(passwd('$JUPYTER_PASSWORD'))
\"")

  cat >/home/opc/start_jupyter.sh <<JUPYTER_AUTH
#!/bin/bash
set -eux
source \$HOME/.venvs/genai/bin/activate

# Generate Jupyter config with password
jupyter lab --generate-config -y

# Set password in config
cat >> \$HOME/.jupyter/jupyter_lab_config.py << EOF
c.ServerApp.password = '$JUPYTER_PASSWORD_HASH'
c.ServerApp.token = ''
c.ServerApp.ip = '0.0.0.0'
c.ServerApp.port = 8888
c.ServerApp.open_browser = False
c.ServerApp.allow_root = False
c.ServerApp.notebook_dir = '/home/opc/labs'
EOF

# Start Jupyter
jupyter lab --config=\$HOME/.jupyter/jupyter_lab_config.py
JUPYTER_AUTH
else
  cat >/home/opc/start_jupyter.sh <<'JUPYTER_TOKEN'
#!/bin/bash
set -eux
source $HOME/.venvs/genai/bin/activate
cd /home/opc/labs
jupyter lab --NotebookApp.token='' --NotebookApp.password='' --ip=0.0.0.0 --port=8888 --no-browser --notebook-dir=/home/opc/labs
JUPYTER_TOKEN
fi

chown opc:opc /home/opc/start_jupyter.sh
chmod +x /home/opc/start_jupyter.sh

echo "[STEP] create enhanced Streamlit startup script"
cat >/home/opc/start_streamlit.sh <<'STREAMLIT'
#!/bin/bash
set -eux
source $HOME/.venvs/genai/bin/activate
cd /home/opc/labs

# Create a simple Streamlit app if it doesn't exist
if [ ! -f "streamlit_app.py" ]; then
  cat > streamlit_app.py <<'EOF'
import streamlit as st
import sys
import os

st.set_page_config(page_title="GenAI RAG Lab", page_icon="🤖", layout="wide")

st.title("🤖 GenAI RAG Laboratory")
st.markdown("Welcome to your Oracle Cloud GenAI RAG environment!")

col1, col2 = st.columns(2)

with col1:
    st.header("🔧 Environment Status")
    
    # Check Python environment
    st.subheader("Python Environment")
    st.code(f"Python: {sys.version}")
    st.code(f"Working Directory: {os.getcwd()}")
    
    # Check Oracle connection
    st.subheader("Oracle Database")
    try:
        import oracledb
        st.success("✅ Oracle database driver available")
        
        # Attempt connection test
        try:
            conn = oracledb.connect(
                user="vector",
                password="vector",
                dsn="localhost:1521/FREEPDB1"
            )
            st.success("✅ Database connection successful")
            conn.close()
        except Exception as e:
            st.warning(f"⚠️ Database connection test failed: {str(e)}")
    except ImportError:
        st.error("❌ Oracle database driver not available")
    
    # Check AI libraries
    st.subheader("AI Libraries")
    libraries = ["langchain", "sentence_transformers", "chromadb", "torch"]
    for lib in libraries:
        try:
            __import__(lib)
            st.success(f"✅ {lib} available")
        except ImportError:
            st.error(f"❌ {lib} not available")

with col2:
    st.header("📚 Quick Start Guide")
    
    st.markdown("""
    ### 🚀 Getting Started
    
    1. **Jupyter Lab**: Access your development environment
       - Navigate to port 8888 for Jupyter Lab
       - Explore the `/home/opc/labs` directory
    
    2. **Oracle Database**: 
       - Host: localhost (via tunnel) or instance IP
       - Port: 1521
       - Service: FREEPDB1
       - User: vector / Password: vector
    
    3. **Sample Code**: Check the labs directory for examples
    
    ### 🔗 Useful Links
    - [Oracle AI Vector Search Documentation](https://docs.oracle.com/en/database/oracle/oracle-database/23/vecse/)
    - [LangChain Documentation](https://docs.langchain.com/)
    - [Sentence Transformers](https://www.sbert.net/)
    """)
    
    st.header("💡 Quick Actions")
    
    if st.button("🔍 Test Vector Search"):
        st.code("""
# Sample vector search code
import oracledb
from sentence_transformers import SentenceTransformer

# Load embedding model
model = SentenceTransformer('all-MiniLM-L12-v2')

# Create embeddings
text = "Hello world"
embedding = model.encode(text)

print(f"Embedding shape: {embedding.shape}")
        """)
    
    if st.button("📖 Sample RAG Query"):
        st.code("""
# Sample RAG implementation
from langchain.text_splitter import CharacterTextSplitter
from langchain.vectorstores import Chroma
from langchain.embeddings import SentenceTransformerEmbeddings

# Initialize components
embeddings = SentenceTransformerEmbeddings(model_name="all-MiniLM-L12-v2")
text_splitter = CharacterTextSplitter(chunk_size=1000, chunk_overlap=0)

# Your RAG pipeline here...
        """)

st.markdown("---")
st.markdown("🏗️ **Infrastructure**: Deployed with Oracle Cloud Infrastructure & Terraform")
EOF
fi

streamlit run streamlit_app.py --server.port=8501 --server.address=0.0.0.0
STREAMLIT

chown opc:opc /home/opc/start_streamlit.sh
chmod +x /home/opc/start_streamlit.sh

echo "[STEP] create systemd services for applications"
cat >/etc/systemd/system/jupyter-lab.service <<'JUPYTER_SERVICE'
[Unit]
Description=Jupyter Lab for GenAI RAG
After=genai-setup.service
Wants=genai-setup.service

[Service]
Type=simple
User=opc
WorkingDirectory=/home/opc/labs
Environment=PATH=/home/opc/.venvs/genai/bin:/home/opc/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=/home/opc/start_jupyter.sh
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
JUPYTER_SERVICE

cat >/etc/systemd/system/streamlit-app.service <<'STREAMLIT_SERVICE'
[Unit]
Description=Streamlit App for GenAI RAG
After=genai-setup.service
Wants=genai-setup.service

[Service]
Type=simple
User=opc
WorkingDirectory=/home/opc/labs
Environment=PATH=/home/opc/.venvs/genai/bin:/home/opc/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=/home/opc/start_streamlit.sh
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
STREAMLIT_SERVICE

# Enable but don't start yet (will start after main setup completes)
systemctl daemon-reload
systemctl enable jupyter-lab.service
systemctl enable streamlit-app.service

echo "[STEP] open firewall ports"
for p in 8888 8501 1521; do firewall-cmd --zone=public --add-port=${p}/tcp --permanent || true; done
firewall-cmd --reload || true

echo "[STEP] run user's enhanced init-genailabs.sh"
set +e
bash /opt/genai/init-genailabs.sh
USR_RC=$?
set -e
echo "[STEP] user init script exit code: $USR_RC"

echo "[STEP] start application services"
systemctl start jupyter-lab.service || echo "Jupyter service start failed, check logs"
systemctl start streamlit-app.service || echo "Streamlit service start failed, check logs"

touch "$MARKER"
echo "===== GenAI OneClick systemd: COMPLETE $(date -u) ====="
SCRIPT
chmod +x /usr/local/bin/genai-setup.sh

# ====================================================================
# genai-db.sh (DB container) — enhanced bootstrap for 23ai
# ====================================================================
cat >/usr/local/bin/genai-db.sh <<'DBSCR'
#!/bin/bash
set -Eeuo pipefail

PODMAN="/usr/bin/podman"
log(){ echo "[DB] $*"; }
retry() { local t=${1:-5}; shift; local n=1; until "$@"; do local rc=$?;
  if (( n>=t )); then return "$rc"; fi
  log "retry $n/$t (rc=$rc): $*"; sleep $((n*5)); ((n++));
done; }

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

log "creating enhanced PDB user 'vector'"
"$PODMAN" exec -e ORACLE_PWD="$ORACLE_PWD" -i "$NAME" bash -lc '
  . /home/oracle/.bashrc
  sqlplus -S -L /nolog <<SQL
  CONNECT sys/${ORACLE_PWD}@127.0.0.1:1521/FREEPDB1 AS SYSDBA
  SET DEFINE OFF
  WHENEVER SQLERROR CONTINUE
  CREATE USER vector IDENTIFIED BY "vector";
  GRANT CREATE SESSION, CREATE TABLE, CREATE SEQUENCE, CREATE VIEW, CREATE PROCEDURE TO vector;
  GRANT UNLIMITED TABLESPACE TO vector;
  -- Enable AI Vector Search
  GRANT EXECUTE ON DBMS_VECTOR TO vector;
  GRANT EXECUTE ON DBMS_VECTOR_CHAIN TO vector;
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
Description=GenAI oneclick - Oracle 23ai container with AI Vector Search
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
Description=GenAI oneclick post-boot setup with Bastion support
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

echo "===== GenAI OneClick with Bastion: cloud-init done $(date -u) ====="
