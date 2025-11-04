#!/usr/bin/env bash
# optimiza_ia_full.sh
# Uso: sudo DRY_RUN=1 bash optimiza_ia_full.sh  -> sólo muestra acciones
#       sudo bash optimiza_ia_full.sh           -> ejecuta
set -euo pipefail
IFS=$'\n\t'

DRY_RUN="${DRY_RUN:-0}"
LOGFILE="/var/log/optimiza_ia_full.log"
BACKUP_DIR="/var/backups/optimiza_ia_full_$(date +%Y%m%d_%H%M%S)"
KEEP_KERNELS=1   # number of kernels to keep (current + keep)
OLLAMA_SERVICE_NAME="ollama"  # adjust si tu servicio difiere

# Colors
info() { echo -e "\e[1;34m[INFO]\e[0m $*"; }
warn() { echo -e "\e[1;33m[WARN]\e[0m $*"; }
err()  { echo -e "\e[1;31m[ERROR]\e[0m $*"; }

run() {
  echo "[$(date +'%F %T')] $*" | tee -a "$LOGFILE"
  if [ "$DRY_RUN" != "1" ]; then
    eval "$@"
  else
    echo "DRY_RUN: $*"
  fi
}

require_root() {
  if [ "$EUID" -ne 0 ]; then
    err "Este script requiere privilegios de root. Ejecuta con sudo."
    exit 1
  fi
}

safe_mkdir() {
  local d="$1"; [ -d "$d" ] || run "mkdir -p '$d'"
}

# ---------- START ----------
require_root
safe_mkdir "$BACKUP_DIR"
echo "Iniciando optimización FULL (DRY_RUN=$DRY_RUN)" | tee -a "$LOGFILE"

# 0) Info hardware y sistema (log)
info "Recolectando información del sistema"
uname -a | tee -a "$LOGFILE"
lscpu | tee -a "$LOGFILE" || true
free -h | tee -a "$LOGFILE" || true
lsblk | tee -a "$LOGFILE" || true
which nvidia-smi &>/dev/null && nvidia-smi -q | tee -a "$LOGFILE" || echo "nvidia-smi no disponible" | tee -a "$LOGFILE"

# 1) Actualización básica y backup de apt lists
info "Actualizando APT y haciendo backup de listas"
run "cp -a /etc/apt/sources.list $BACKUP_DIR/ || true"
run "cp -a /etc/apt/sources.list.d $BACKUP_DIR/ || true"
run "apt update -y"
run "apt upgrade -y"
run "apt dist-upgrade -y"

# 2) Limpieza profunda apt, snap, caches
info "Limpieza profunda de paquetes y caches"
run "apt autoremove --purge -y"
run "apt autoclean -y"
run "apt clean -y"
# Eliminación de paquetes huérfanos (debian-goodies proporciona deborphan)
run "apt install -y deborphan || true"
run "for p in \$(deborphan || true); do apt -y purge \$p || true; done || true"

# 2.1) Eliminar kernels viejos (mantener solo el kernel actual + KEEP_KERNELS)
info "Eliminando kernels antiguos (solo quedará el kernel actualmente en uso + $((KEEP_KERNELS-1)) previos)"
CURRENT_KERNEL="$(uname -r)"
run "mkdir -p $BACKUP_DIR/apt-lists"
run "dpkg --list | tee $BACKUP_DIR/apt-lists/dpkg_list.txt"
# List installed linux-image and remove older ones
OLD_KERNELS_TO_REMOVE=$(dpkg --list 'linux-image-*' | awk '/^ii/{print $2,$3}' | grep -v "$CURRENT_KERNEL" | awk '{print $1}' || true)
if [ -n "$OLD_KERNELS_TO_REMOVE" ]; then
  for k in $OLD_KERNELS_TO_REMOVE; do
    # safety exclude current and meta packages
    if echo "$k" | grep -q "linux-image-generic"; then
      continue
    fi
    run "apt-get -y purge $k || true"
  done
  run "update-grub || true"
else
  info "No se encontraron kernels antiguos para eliminar."
fi

# 2.2) Snap cleanup (opcional destructivo): eliminar snaps de aplicaciones de escritorio no críticas
info "Listado de snaps instalados (se eliminarán snaps de user-apps no-sistema)"
SNAPS=$(snap list | awk 'NR>1{print $1}')
# safety: keep 'core', 'core18', 'core20', 'snapd'
for s in $SNAPS; do
  case "$s" in
    core|core18|core20|snapd) info "Manteniendo snap $s";;
    *)
      info "Eliminando snap: $s"
      run "snap remove --purge $s || true"
      ;;
  esac
done

# 3) Drivers NVIDIA: auto detect & install (ubuntu-drivers)
info "Detectando drivers NVIDIA y aplicando ubuntu-drivers autoinstall"
run "apt install -y ubuntu-drivers-common build-essential dkms"
# Use ubuntu-drivers to choose recommended
run "ubuntu-drivers autoinstall || true"
# ensure nouveau disabled
run "bash -lc 'echo \"blacklist nouveau\" > /etc/modprobe.d/blacklist-nouveau.conf' || true"
run "update-initramfs -u || true"

# 4) Docker + NVIDIA container toolkit
info "Instalando Docker y nvidia container toolkit (nvidia-docker)"
run "apt install -y ca-certificates curl gnupg lsb-release"
run "mkdir -p /etc/apt/keyrings"
run "curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg"
run "echo \
  \"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) stable\" | tee /etc/apt/sources.list.d/docker.list > /dev/null"
run "apt update -y"
run "apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin || true"
# NVIDIA container toolkit repo
run "distribution=\$(. /etc/os-release;echo \$ID\$VERSION_ID) && \
  curl -s -L https://nvidia.github.io/nvidia-docker/gpgkey | apt-key add - || true"
run "curl -s -L https://nvidia.github.io/nvidia-docker/\$(. /etc/os-release;echo \$ID\$VERSION_ID)/nvidia-docker.list | tee /etc/apt/sources.list.d/nvidia-docker.list"
run "apt update -y || true"
run "apt install -y nvidia-container-toolkit || true"
run "systemctl restart docker || true"

# 5) System tuning: CPU governor, swappiness, zram, I/O scheduler
info "Aplicando ajustes de rendimiento: governor, swappiness, zram, scheduler"
run "apt install -y cpufrequtils util-linux zram-tools linux-tools-$(uname -r) || true"
# Set performance governor immediately
if command -v cpufreq-set &>/dev/null; then
  cpu_count=$(nproc)
  for i in $(seq 0 $((cpu_count-1))); do
    run "cpufreq-set -c $i -g performance || true"
  done
else
  info "cpufreq-set no disponible, intentando fallback echo governor"
  for gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    run "echo performance > $gov || true"
  done
fi
# swappiness
run "sysctl -w vm.swappiness=10 || true"
run "sed -i.bak -E 's/^vm.swappiness=.*/vm.swappiness=10/' /etc/sysctl.conf || true"
# zram config (use zram-tools)
run "apt install -y zram-tools || true"
run "cat > /etc/default/zramsize <<'ZZ'\n# zram-tools default\nPERCENT=40\nZZ"
run "systemctl enable --now zramswap.service || true"
# I/O scheduler: set to 'deadline' or 'mq-deadline' for spinning disks, 'none' for NVMe - auto detect
for disk in /sys/block/*; do
  name=$(basename "$disk")
  # skip loop, ram
  case "$name" in loop*|ram*|sr*|zram*) continue;; esac
  rotational=$(cat $disk/queue/rotational || echo 1)
  if [ "$rotational" -eq 1 ]; then
    run "echo mq-deadline > $disk/queue/scheduler || true"
  else
    run "echo none > $disk/queue/scheduler || true"
  fi
done

# 6) Install python stack + build tools + libs IA
info "Instalando toolchain para IA: Python, venv, pip, build-essentials, BLAS/LAPACK"
run "apt install -y python3 python3-venv python3-pip python3-dev build-essential git cmake ninja-build pkg-config \
libopenblas-dev liblapack-dev libssl-dev libffi-dev libsndfile1-dev libnuma-dev libbz2-dev \
libzstd-dev liblz4-tool liblzma-dev curl wget jq git-lfs || true"
run "pip3 install --upgrade pip setuptools wheel || true"
# Git LFS init
run "git lfs install || true"

# 7) Install common IA Python packages in a system venv (isolated under /opt/ia_env)
info "Creando venv en /opt/ia_env e instalando paquetes IA (pytorch, transformers, accelerate, etc.)"
run "mkdir -p /opt/ia_env && chown $SUDO_USER:${SUDO_USER:-root} /opt/ia_env || true"
run "python3 -m venv /opt/ia_env/venv || true"
run "/opt/ia_env/venv/bin/pip install --upgrade pip || true"

# Detect CUDA availability (nvidia-smi)
CUDA_AVAILABLE=0
if command -v nvidia-smi &>/dev/null; then
  CUDA_AVAILABLE=1
  CUDA_VER=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -n1 || true)
  info "NVIDIA driver detectado (driver ver: $CUDA_VER)"
else
  info "NVIDIA no detectada por nvidia-smi; instalaré stack CPU-optimizado."
fi

# Install PyTorch: try to install CUDA build if GPU present, else CPU
if [ "$CUDA_AVAILABLE" -eq 1 ]; then
  info "Intentando instalar PyTorch con soporte CUDA (si pip wheel disponible)"
  # Not hard-coding CUDA version: install torch with cuda if available in pip; fall back to cpu
  run "/opt/ia_env/venv/bin/pip install -U 'torch' torchvision torchaudio --index-url https://download.pytorch.org/whl/cu118 || true"
else
  info "Instalando PyTorch CPU optimizado"
  run "/opt/ia_env/venv/bin/pip install -U 'torch' torchvision torchaudio --extra-index-url https://download.pytorch.org/whl/cpu || true"
fi

# Common ML libs
run "/opt/ia_env/venv/bin/pip install -U transformers accelerate datasets safetensors tokenizers sentencepiece \
onnxruntime openai tiktoken langchain uvicorn fastapi pydantic psutil einops albumentations \
protobuf==4.23.4 || true"

# 8) llama.cpp & ctranslate2 build (if git present)
info "Construyendo optimizaciones locales (llama.cpp, ctranslate2) si están disponibles"
WORKDIR="/opt/ia_build"
run "mkdir -p $WORKDIR && chown $SUDO_USER:$SUDO_USER $WORKDIR || true"

# llama.cpp
if [ -d "$WORKDIR/llama.cpp" ]; then
  info "llama.cpp ya está clonado"
else
  run "git clone https://github.com/ggerganov/llama.cpp.git $WORKDIR/llama.cpp || true"
fi
# build with max CPU flags if possible
CPU_FLAGS="$(grep -m1 -o -E 'avx512|avx2|avx' /proc/cpuinfo || true)"
MAKE_OPTS=""
if echo "$CPU_FLAGS" | grep -q avx512; then
  MAKE_OPTS="CFLAGS='-O3 -march=native -mtune=native -mavx512f' MAKEFLAGS='-j$(nproc)'"
elif echo "$CPU_FLAGS" | grep -q avx2; then
  MAKE_OPTS="CFLAGS='-O3 -march=native -mtune=native -mavx2' MAKEFLAGS='-j$(nproc)'"
else
  MAKE_OPTS="CFLAGS='-O3 -march=native' MAKEFLAGS='-j$(nproc)'"
fi
run "cd $WORKDIR/llama.cpp && ${MAKE_OPTS} make || true"

# ctranslate2 (optional)
if [ -d "$WORKDIR/ctransformers" ]; then
  info "ctransformers ya clonado"
else
  run "git clone https://github.com/EleutherAI/ctransformers.git $WORKDIR/ctransformers || true"
fi
run "cd $WORKDIR/ctransformers && python3 -m pip install -r requirements.txt || true"

# 9) Ollama integration: vm.max_map_count, ulimits, move models helper
info "Configurando ajustes para Ollama (vm.max_map_count, ulimits y helper para modelos)"
run "sysctl -w vm.max_map_count=262144 || true"
run "sed -i.bak -E 's/^#?vm.max_map_count=.*/vm.max_map_count=262144/' /etc/sysctl.conf || true"
# increase file descriptors for service
OL_CONF="/etc/security/limits.d/99-ollama.conf"
run "cat > $OL_CONF <<'EOF'\n# Ollama / LLM tuning\n* soft nofile 65536\n* hard nofile 65536\nroot soft nofile 65536\nroot hard nofile 65536\nEOF"
# systemd service override for Ollama to raise LimitNOFILE
if systemctl list-units --type=service --no-legend | grep -q $OLLAMA_SERVICE_NAME; then
  info "Configurando override systemd para $OLLAMA_SERVICE_NAME"
  run "mkdir -p /etc/systemd/system/$OLLAMA_SERVICE_NAME.service.d || true"
  run "cat > /etc/systemd/system/$OLLAMA_SERVICE_NAME.service.d/override.conf <<'EOF'\n[Service]\nLimitNOFILE=65536\nLimitNPROC=65536\nEOF"
  run "systemctl daemon-reload || true"
  run "systemctl restart $OLLAMA_SERVICE_NAME || true"
else
  info "Servicio $OLLAMA_SERVICE_NAME no detectado; omitiendo override systemd"
fi

# helper script para mover modelos a disco rápido si se detecta SSD
MODEL_HELPER="/usr/local/bin/move_models_to_fastdisk.sh"
run "cat > $MODEL_HELPER <<'SH'\n#!/usr/bin/env bash\n# Mueve carpeta de modelos de Ollama a un disco rápido (si existe /mnt/fastdisk)\nSRC=\${1:-/var/lib/ollama}\nDST=\${2:-/mnt/fastdisk/ollama_models}\nif [ ! -d \"\$DST\" ]; then\n  mkdir -p \"\$DST\"\nfi\nif mountpoint -q /mnt/fastdisk; then\n  rsync -avh --progress \"\$SRC/\" \"\$DST/\" && echo \"Moved\" || echo \"Move failed\"\nelse\n  echo \"/mnt/fastdisk no montado\"\nfi\nSH"
run "chmod +x $MODEL_HELPER || true"

# 10) Security: ufw + fail2ban + unattended-upgrades
info "Instalando medidas de seguridad básicas: ufw, fail2ban, unattended-upgrades"
run "apt install -y ufw fail2ban unattended-upgrades apt-listchanges || true"
run "ufw default deny incoming || true"
run "ufw default allow outgoing || true"
# allow ssh
run "ufw allow ssh || true"
run "ufw --force enable || true"
# fail2ban default setup
run "systemctl enable --now fail2ban || true"
# unattended upgrades
run "dpkg-reconfigure --priority=low unattended-upgrades || true"

# 11) Cron job weekly cleanup and apt autoremove
info "Creando tarea cron semanal para limpieza y actualización de dependencias"
CRON_SCRIPT="/usr/local/bin/ia_weekly_maintenance.sh"
run "cat > $CRON_SCRIPT <<'CRON'\n#!/usr/bin/env bash\napt update && apt upgrade -y && apt autoremove -y && apt autoclean -y\n# prune docker unused\nif command -v docker &>/dev/null; then docker system prune -af || true; fi\nCRON"
run "chmod +x $CRON_SCRIPT"
run "(crontab -l 2>/dev/null || true; echo \"0 4 * * 0 root $CRON_SCRIPT\") | crontab -" || true

# 12) systemd unit to keep performance settings after resume/reboot
info "Creando systemd unit para reaplicar ajustes de performance en arranque"
TWEAK_SERVICE="/etc/systemd/system/ia-perf-tweaks.service"
run "cat > $TWEAK_SERVICE <<'UNIT'\n[Unit]\nDescription=Apply IA Performance Tweaks\nAfter=network.target\n\n[Service]\nType=oneshot\nExecStart=/bin/bash -c 'sysctl -w vm.swappiness=10; sysctl -w vm.max_map_count=262144; for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo performance > \$g || true; done'\n\n[Install]\nWantedBy=multi-user.target\nUNIT"
run "systemctl daemon-reload || true"
run "systemctl enable --now ia-perf-tweaks.service || true"

# 13) Final steps: permissions, info, report
info "Ajustando permisos y generando reporte final"
run "chown -R $SUDO_USER:$SUDO_USER /opt/ia_build || true"
echo "----------------------------------------" | tee -a "$LOGFILE"
echo "OPTIMIZACION COMPLETA: $(date)" | tee -a "$LOGFILE"
echo "Logs: $LOGFILE" | tee -a "$LOGFILE"
echo "Backups: $BACKUP_DIR" | tee -a "$LOGFILE"
echo "Para rollback manual: revisar $BACKUP_DIR y restaurar archivos editados." | tee -a "$LOGFILE"

info "TERMINADO. Recomendaciones post-ejecución:"
cat <<'ADVICE'
- Reinicia el sistema: sudo reboot
- Revisa nvidia-smi: nvidia-smi
- Si quieres revertir eliminación de snaps o kernels, revisa backups en $BACKUP_DIR.
- Comprueba Docker: docker run --rm --gpus all nvidia/cuda:11.8.0-base-ubuntu22.04 nvidia-smi
- Comprueba el venv: source /opt/ia_env/venv/bin/activate && python -c "import torch; print(torch.__version__)"
- Si algún driver NVIDIA da problemas, revisa /var/log/Xorg.0.log y usa 'ubuntu-drivers list' y 'ubuntu-drivers autoinstall' manualmente.
ADVICE

exit 0
