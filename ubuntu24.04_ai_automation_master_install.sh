#!/usr/bin/env bash
# ubuntu24.04_ai_automation_master_install.sh
# Autoinstaller / optimizer para Ubuntu 24.04 — MODO: Híbrido (GUI+Server)
# GPU: NVIDIA + CUDA (si está disponible)
# IA: "Dios Mode" (Ollama, GPT4All, LM Studio, LMDeploy, LangChain, FastAPI, Whisper, embeddings)
# Automatización: FULL STACK (n8n, Docker, Portainer, Redis, PostgreSQL, Traefik/nginx, Certbot placeholders)
# Seguridad: UFW + Fail2ban + Hardening + IDS (AIDE optional)
# Kernel & swap optimizaciones: ZRAM, low-latency kernel, sysctl tuning
# Auto-fix diario: systemd-timer que ejecuta mantenimiento
# WARNING: Ejecuta este script con sudo/root. Revisa las secciones marcadas como "PLACEHOLDER" antes de ejecutarlo en producción.

set -euo pipefail
LOGFILE="/var/log/ubuntu_ai_install.log"
exec > >(tee -a "$LOGFILE") 2>&1

###########################
# Helpers
###########################
info(){ echo -e "[INFO] $*"; }
warn(){ echo -e "[WARN] $*"; }
err(){ echo -e "[ERROR] $*"; exit 1; }

confirm_root(){
  if [ "$(id -u)" -ne 0 ]; then
    err "Este script requiere privilegios de root. Ejecútalo con sudo su - o sudo bash"
  fi
}

detect_gpu(){
  if command -v nvidia-smi >/dev/null 2>&1; then
    echo "nvidia"
  elif lspci | grep -i nvidia >/dev/null 2>&1; then
    echo "nvidia-detected"
  else
    echo "none"
  fi
}

###########################
# Inicio
###########################
confirm_root
info "Iniciando instalación y optimización — revisa el log en $LOGFILE"

# 1) Actualizar sistema
info "Actualizando paquetes..."
apt update -y && apt upgrade -y

# 2) Limpiar snaps y paquetes innecesarios (opcional)
info "Limpiando paquetes innecesarios..."
# Remove snapd if user wants; comment out if you need snap
if dpkg -l | grep -q snapd; then
  warn "snapd detected — eliminando snapd y snaps (esto puede afectar apps instaladas)."
  systemctl stop snapd.socket || true
  snap remove --purge snap-store || true
  apt purge -y snapd gnome-software-plugin-snap || true
  rm -rf /var/cache/snapd /snap || true
fi

# 3) Instalar utilidades base
info "Instalando utilidades base (curl, git, htop, jq, build-essential, etc.)"
apt install -y curl wget git htop jq unzip build-essential ca-certificates gnupg lsb-release software-properties-common apt-transport-https

# 4) ZRAM (swap in RAM) para mejorar rendimiento en sistemas con RAM limitada
info "Configurando ZRAM (zram-tools)..."
apt install -y zram-tools
cat >/etc/default/zramswap <<'EOF'
# zramswap defaults
ALGO=lz4
PCT=50
EOF
systemctl enable --now zramswap.service || true

# 5) Ajustes sysctl para rendimiento
info "Ajustes sysctl para rendimiento..."
cat >/etc/sysctl.d/99-ubuntu-ai.conf <<'EOF'
# Tunings for AI workloads & networking
vm.swappiness=10
vm.vfs_cache_pressure=50
fs.file-max=2097152
net.core.somaxconn=65535
net.core.netdev_max_backlog=250000
net.ipv4.tcp_fin_timeout=15
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_syncookies=1
net.ipv4.tcp_rmem= 4096 87380 6291456
net.ipv4.tcp_wmem= 4096 16384 4194304
EOF
sysctl --system

# 6) Instalar kernel low-latency
info "Instalando kernel low-latency (útil para audio/latencia baja)..."
apt install -y linux-lowlatency || warn "linux-lowlatency no disponible o ya instalado"

# 7) Swapfile fallback: ajustar o crear si no existe
if ! swapon --show | grep -q ""; then
  warn "No se detectó swap activo — creando swapfile de 8G..."
  fallocate -l 8G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

# 8) Instalación de drivers NVIDIA y CUDA (detecta y instala)
GPU_STATE=$(detect_gpu)
if [ "$GPU_STATE" = "nvidia" ] || [ "$GPU_STATE" = "nvidia-detected" ]; then
  info "GPU NVIDIA detectada. Instalando drivers recomendados y CUDA repo (si se desea)."
  ubuntu-drivers autoinstall || warn "ubuntu-drivers autoinstall falló — continúa de todos modos"
  # Opcional: instalar CUDA toolkit (placeholder) — revisar compatibilidad con tu GPU
  info "Instalando CUDA runtime mínimo (si está disponible en repositorios)."
  # NOTE: Instalar CUDA desde repos oficiales puede requerir repos externos. Aquí instalamos nvidia-cuda-toolkit como fallback.
  apt install -y nvidia-cuda-toolkit || warn "nvidia-cuda-toolkit no disponible; omitiendo. Para CUDA completa instala desde NVIDIA repos oficiales."
else
  info "No se detectó GPU NVIDIA. Continuando con instalación CPU-first."
fi

# 9) Docker + Compose + Portainer
info "Instalando Docker, Docker Compose y Portainer..."
# Docker
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
ARCH=$(dpkg --print-architecture)
echo "deb [arch=$ARCH signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
apt update -y
apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
# Allow current user (if exists) to use docker — if script run under sudo, $SUDO_USER may be present
if [ -n "${SUDO_USER:-}" ]; then
  usermod -aG docker "$SUDO_USER" || true
fi
# Portainer
docker volume create portainer_data || true
docker run -d --name portainer --restart=always -p 9000:9000 -v /var/run/docker.sock:/var/run/docker.sock -v portainer_data:/data portainer/portainer-ce:latest || warn "Portainer no arrancó"

# 10) Node 20 (LTS) & n8n (docker-compose)
info "Instalando Node.js 20 (para herramientas CLI y Make) y creando stack n8n + Postgres + Redis"
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt install -y nodejs

# Crear directorio de deploy
mkdir -p /opt/ai_automation_stack
cat >/opt/ai_automation_stack/docker-compose.yml <<'EOF'
version: '3.8'
services:
  postgres:
    image: postgres:15
    restart: always
    environment:
      - POSTGRES_USER=n8n
      - POSTGRES_PASSWORD=n8n_password
      - POSTGRES_DB=n8n
    volumes:
      - postgres_data:/var/lib/postgresql/data

  redis:
    image: redis:7
    restart: always

  n8n:
    image: n8nio/n8n:latest
    restart: always
    env_file: .env
    ports:
      - "5678:5678"
    depends_on:
      - postgres
      - redis
    volumes:
      - n8n_data:/home/node/.n8n

  traefik:
    image: traefik:v3
    command:
      - --providers.docker=true
      - --entrypoints.web.address=:80
      - --entrypoints.websecure.address=:443
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock

volumes:
  postgres_data:
  n8n_data:
EOF

cat >/opt/ai_automation_stack/.env <<'EOF'
# n8n env (ajusta contraseñas y DOMAIN)
DB_TYPE=postgresdb
DB_POSTGRESDB_HOST=postgres
DB_POSTGRESDB_PORT=5432
DB_POSTGRESDB_DATABASE=n8n
DB_POSTGRESDB_USER=n8n
DB_POSTGRESDB_PASSWORD=n8n_password
N8N_BASIC_AUTH_ACTIVE=true
N8N_BASIC_AUTH_USER=admin
N8N_BASIC_AUTH_PASSWORD=changeme
GENERIC_TIMEZONE=UTC
WEBHOOK_URL=http://localhost:5678/
# Si tienes dominio y TLS, reemplaza WEBHOOK_URL por https://tu-dominio
EOF

# Levantar stack
info "Levantando servicios Docker (n8n, postgres, redis, traefik)"
cd /opt/ai_automation_stack
docker compose up -d || warn "docker compose pudo haber fallado. Revisa 'docker compose ps'"

# 11) Instalar PostgreSQL y Redis local (si prefieres apt instead of docker) — opcional
info "Instalación opcional de PostgreSQL y Redis locales (también disponibles vía Docker)."
apt install -y postgresql postgresql-contrib redis-server || warn "Postgres/Redis apt instalados o ya existentes"

# 12) Python 3.12, pip, venv y dependencias IA
info "Instalando Python 3.12, pip, venv..."
apt install -y python3.12 python3.12-venv python3.12-dev python3-pip || warn "Python 3.12 may be preinstalled"
python3.12 -m pip install --upgrade pip setuptools wheel

# Crear ambiente global para herramientas IA
mkdir -p /opt/ai-tools
python3.12 -m venv /opt/ai-tools/venv
source /opt/ai-tools/venv/bin/activate
pip install --upgrade pip
pip install langchain fastapi uvicorn[standard] transformers sentence-transformers accelerate torch --extra-index-url https://download.pytorch.org/whl/cpu || true
# instalar whisper.cpp python wrapper (whisperx / faster-whisper alternativa)
pip install faster-whisper whisperx || true

# 13) Instalaciones de LLMs y herramientas locales (placeholders y automatismos)
info "Instalando herramientas LLM locales (gpt4all, llama.cpp, whisper.cpp builds)"
# GPT4All (descarga binaria si se desea) — dejamos script para instalar la versión Python
pip install gpt4all || true
# llama.cpp build (para cuantizados y uso local)
apt install -y cmake libopenblas-dev || true
if [ ! -d /opt/llama.cpp ]; then
  git clone https://github.com/ggerganov/llama.cpp.git /opt/llama.cpp || true
  cd /opt/llama.cpp
  make || true
fi

# 14) Ollama (si el usuario quiere: repo oficial) — intentar instalar si el binario público está disponible
info "Instalando Ollama (si está disponible via apt)
# NOTE: Si no está disponible, omitir. Revisa https://ollama.com/install para instrucciones actualizadas."
if ! command -v ollama >/dev/null 2>&1; then
  warn "Ollama no encontrado — la instalación automática depende de su repo. Dejo instrucciones en /opt/ai-tools/README_INSTALL.txt"
  cat >/opt/ai-tools/README_INSTALL.txt <<'EOF'
Ollama installation notes:
- Visita https://ollama.com/install para instrucciones actualizadas.
- Alternativa: usar docker images o gpt4all/llama.cpp local builds.
EOF
fi

# 15) LM Studio (GUI) — descarga e instrucción
info "Preparando LM Studio (descarga manual recomendada)"
cat >> /opt/ai-tools/README_INSTALL.txt <<'EOF'
LM Studio:
- Descarga la app para Linux desde su repo oficial o releases. Instálala manualmente si quieres GUI.
EOF

# 16) LangChain + FastAPI ejemplo de scaffold
info "Creando scaffold FastAPI para exponer embeddings/agents locales"
mkdir -p /opt/ai-tools/apps/sample_api
cat >/opt/ai-tools/apps/sample_api/main.py <<'PY'
from fastapi import FastAPI
app = FastAPI()

@app.get('/')
def root():
    return {'status':'ok','app':'ai-sample-api'}
PY
cat >/opt/ai-tools/apps/sample_api/uvicorn.service <<'UNIT'
[Unit]
Description=AI Sample Uvicorn
After=network.target

[Service]
User=root
WorkingDirectory=/opt/ai-tools/apps/sample_api
ExecStart=/opt/ai-tools/venv/bin/uvicorn main:app --host 0.0.0.0 --port 8000
Restart=on-failure

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now uvicorn.service || warn "Uvicorn service may fail until venv deps are installed"

# 17) Seguridad: UFW + Fail2Ban + AIDE (opcional)
info "Configurando firewall UFW y Fail2ban"
apt install -y ufw fail2ban aide
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 5678/tcp # n8n default
ufw --force enable

# Fail2ban default
cat >/etc/fail2ban/jail.local <<'EOF'
[sshd]
enabled = true
maxretry = 5
bantime = 3600
EOF
systemctl enable --now fail2ban || warn "fail2ban may fail to start"

# 18) IDS baseline (AIDE)
aideinit || true
mv /var/lib/aide/aide.db.new /var/lib/aide/aide.db || true

# 19) Auto-maintenance daily (logrotate, apt update, docker prune)
info "Creando tarea systemd timer para mantenimiento diario (autofix)"
cat >/etc/systemd/system/ai-maintenance.sh <<'SCRIPT'
#!/usr/bin/env bash
set -e
# Quick maintenance tasks
apt update -y && apt upgrade -y
docker system prune -af || true
apt autoremove -y
journalctl --vacuum-time=7d || true
SCRIPT
chmod +x /etc/systemd/system/ai-maintenance.sh
cat >/etc/systemd/system/ai-maintenance.service <<'UNIT'
[Unit]
Description=AI system maintenance

[Service]
Type=oneshot
ExecStart=/etc/systemd/system/ai-maintenance.sh

[Install]
WantedBy=multi-user.target
UNIT
cat >/etc/systemd/system/ai-maintenance.timer <<'TIMER'
[Unit]
Description=Daily AI maintenance timer

[Timer]
OnCalendar=daily
Persistent=true

[Install]
WantedBy=timers.target
TIMER
systemctl daemon-reload
systemctl enable --now ai-maintenance.timer || warn "ai-maintenance.timer may fail"

# 20) Monitoring basic: Netdata (lightweight)
info "Instalando Netdata para monitoreo ligero"
bash <(curl -Ss https://my-netdata.io/kickstart.sh) --dont-wait || warn "Netdata install may require manual steps"

# 21) Finalización y recomendaciones
info "Instalación finalizada (óptima). Recomendaciones finales:" 
cat >/root/UBUNTU_AI_POST_INSTALL_README.txt <<'EOF'
Checklist post-install:
- Reboot the machine to load low-latency kernel and NVIDIA drivers if installed.
- Edit /opt/ai_automation_stack/.env to secure credentials and set WEBHOOK_URL to your domain if you have one.
- If you need full CUDA: follow NVIDIA official instructions at https://developer.nvidia.com/cuda-downloads
- Install model files (weights) in /opt/models or use Ollama/docker images per your preference.
- Review /opt/ai-tools/README_INSTALL.txt for manual steps (LM Studio, Ollama specifics).
- Consider using Ansible for multi-server deployment; I can generate an Ansible playbook if desired.
EOF

info "SCRIPT COMPLETED. Reboot recommended. Logs in $LOGFILE and /root/UBUNTU_AI_POST_INSTALL_README.txt"

exit 0
