#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════╗
# ║   Record Mais IPTV Proxy - Instalador                        ║
# ║   Compatível: Ubuntu 22.04 | ARM64 | x86_64                  ║
# ║   GitHub: https://github.com/jeanfraga95/sky-nv              ║
# ╚══════════════════════════════════════════════════════════════╝

set -euo pipefail

# ─── Cores ──────────────────────────────────────────────────────────────────

VERDE='\033[0;32m'
AMARELO='\033[1;33m'
VERMELHO='\033[0;31m'
AZUL='\033[0;34m'
NEGRITO='\033[1m'
RESET='\033[0m'

ok()    { echo -e "${VERDE}  ✓ ${*}${RESET}"; }
info()  { echo -e "${AZUL}  → ${*}${RESET}"; }
aviso() { echo -e "${AMARELO}  ⚠ ${*}${RESET}"; }
erro()  { echo -e "${VERMELHO}  ✗ ${*}${RESET}"; exit 1; }
titulo(){ echo -e "\n${NEGRITO}${AZUL}══ ${*} ══${RESET}"; }

# ─── Variáveis ───────────────────────────────────────────────────────────────

REPO_BASE="https://raw.githubusercontent.com/jeanfraga95/sky-nv/main"
INSTALL_DIR="/opt/record_proxy"
SERVICE_NAME="record_proxy"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
LOG_FILE="/var/log/record_proxy.log"
PORTA=8888

# ─── Banner ──────────────────────────────────────────────────────────────────

echo -e ""
echo -e "${NEGRITO}${AZUL}╔══════════════════════════════════════════════╗${RESET}"
echo -e "${NEGRITO}${AZUL}║     Record Mais IPTV Proxy - Instalador      ║${RESET}"
echo -e "${NEGRITO}${AZUL}║        ARM64 / x86_64  |  Ubuntu 22.04       ║${RESET}"
echo -e "${NEGRITO}${AZUL}╚══════════════════════════════════════════════╝${RESET}"
echo -e ""

# ─── Verificações iniciais ───────────────────────────────────────────────────

titulo "Verificações"

# Root
if [[ $EUID -ne 0 ]]; then
    erro "Execute como root: sudo bash install.sh"
fi
ok "Executando como root"

# Arquitetura
ARCH=$(uname -m)
if [[ "$ARCH" != "x86_64" && "$ARCH" != "aarch64" && "$ARCH" != "arm64" ]]; then
    aviso "Arquitetura não testada: $ARCH (esperado x86_64 ou aarch64)"
fi
ok "Arquitetura: $ARCH"

# Ubuntu 22.04
if [[ -f /etc/os-release ]]; then
    source /etc/os-release
    info "Sistema: $PRETTY_NAME"
fi

# ─── Remover instalação anterior ─────────────────────────────────────────────

titulo "Limpeza de instalação anterior"

if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
    info "Parando serviço existente..."
    systemctl stop "$SERVICE_NAME"
    ok "Serviço parado"
fi

if systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; then
    systemctl disable "$SERVICE_NAME" 2>/dev/null || true
fi

if [[ -f "$SERVICE_FILE" ]]; then
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload
    ok "Serviço anterior removido"
fi

if [[ -d "$INSTALL_DIR" ]]; then
    info "Removendo instalação anterior: $INSTALL_DIR"
    rm -rf "$INSTALL_DIR"
    ok "Diretório anterior removido"
fi

# ─── Dependências do sistema ──────────────────────────────────────────────────

titulo "Dependências do sistema"

info "Atualizando lista de pacotes..."
apt-get update -qq

info "Instalando dependências base..."
apt-get install -y -qq \
    python3 \
    python3-pip \
    python3-venv \
    curl \
    wget \
    ca-certificates \
    gnupg \
    unzip \
    libglib2.0-0 \
    libnss3 \
    libnspr4 \
    libatk1.0-0 \
    libatk-bridge2.0-0 \
    libcups2 \
    libdrm2 \
    libdbus-1-3 \
    libexpat1 \
    libxcb1 \
    libxkbcommon0 \
    libx11-6 \
    libxcomposite1 \
    libxdamage1 \
    libxext6 \
    libxfixes3 \
    libxrandr2 \
    libgbm1 \
    libpango-1.0-0 \
    libcairo2 \
    libasound2 \
    libatspi2.0-0 2>/dev/null || true

ok "Dependências do sistema instaladas"

# ─── Criar diretório e ambiente virtual ──────────────────────────────────────

titulo "Ambiente Python"

mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

info "Criando ambiente virtual Python..."
python3 -m venv venv
source venv/bin/activate

info "Atualizando pip..."
pip install --upgrade pip -q

info "Instalando pacotes Python..."
pip install -q \
    playwright \
    requests

ok "Pacotes Python instalados"

info "Instalando Playwright e browser Chromium..."
playwright install chromium 2>&1 | tail -5
playwright install-deps chromium 2>/dev/null || true

ok "Chromium instalado"

# ─── Download dos scripts ─────────────────────────────────────────────────────

titulo "Download dos scripts"

info "Baixando record_proxy.py..."
curl -fsSL "${REPO_BASE}/record_proxy.py" -o "${INSTALL_DIR}/record_proxy.py"
ok "record_proxy.py baixado"

chmod +x "${INSTALL_DIR}/record_proxy.py"

# Criar diretório de log
touch "$LOG_FILE"
chmod 666 "$LOG_FILE"

# ─── Serviço systemd ──────────────────────────────────────────────────────────

titulo "Serviço systemd"

cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Record Mais IPTV Proxy - Links Fixos para Canais ao Vivo
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=60
StartLimitBurst=3

[Service]
Type=simple
User=root
WorkingDirectory=${INSTALL_DIR}
ExecStart=${INSTALL_DIR}/venv/bin/python3 ${INSTALL_DIR}/record_proxy.py
Restart=on-failure
RestartSec=15
StandardOutput=append:${LOG_FILE}
StandardError=append:${LOG_FILE}
Environment=PYTHONUNBUFFERED=1
Environment=PYTHONDONTWRITEBYTECODE=1

# Limites de recursos
LimitNOFILE=65536
LimitNPROC=4096

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "$SERVICE_NAME"
systemctl start "$SERVICE_NAME"

ok "Serviço criado e iniciado"

# ─── Verificação final ────────────────────────────────────────────────────────

titulo "Verificação"

sleep 3

if systemctl is-active --quiet "$SERVICE_NAME"; then
    ok "Serviço rodando normalmente"
else
    aviso "Serviço não iniciou ainda (normal – aguarda captura inicial)"
    aviso "Verifique: journalctl -u $SERVICE_NAME -f"
fi

# IP da VPS
IP_LOCAL=$(hostname -I | awk '{print $1}')
IP_PUBLICO=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || echo "$IP_LOCAL")

# ─── Resumo ───────────────────────────────────────────────────────────────────

echo -e ""
echo -e "${NEGRITO}${VERDE}╔══════════════════════════════════════════════════════╗${RESET}"
echo -e "${NEGRITO}${VERDE}║          Instalação concluída com sucesso!           ║${RESET}"
echo -e "${NEGRITO}${VERDE}╠══════════════════════════════════════════════════════╣${RESET}"
echo -e "${NEGRITO}${VERDE}║                                                      ║${RESET}"
echo -e "${NEGRITO}${VERDE}║  📺  Playlist M3U (todos os canais + qualidades):   ║${RESET}"
echo -e "${NEGRITO}${VERDE}║  http://${IP_PUBLICO}:${PORTA}/playlist.m3u${RESET}"
echo -e "${NEGRITO}${VERDE}║                                                      ║${RESET}"
echo -e "${NEGRITO}${VERDE}║  🔍  Status e URLs individuais:                     ║${RESET}"
echo -e "${NEGRITO}${VERDE}║  http://${IP_PUBLICO}:${PORTA}/status${RESET}"
echo -e "${NEGRITO}${VERDE}║                                                      ║${RESET}"
echo -e "${NEGRITO}${VERDE}║  ▶   Exemplo A&E no VLC:                            ║${RESET}"
echo -e "${NEGRITO}${VERDE}║  http://${IP_PUBLICO}:${PORTA}/stream/ae/fhd         ║${RESET}"
echo -e "${NEGRITO}${VERDE}║  http://${IP_PUBLICO}:${PORTA}/stream/ae/hd          ║${RESET}"
echo -e "${NEGRITO}${VERDE}║  http://${IP_PUBLICO}:${PORTA}/stream/ae/sd          ║${RESET}"
echo -e "${NEGRITO}${VERDE}║                                                      ║${RESET}"
echo -e "${NEGRITO}${VERDE}╠══════════════════════════════════════════════════════╣${RESET}"
echo -e "${NEGRITO}${VERDE}║  Canais disponíveis:                                 ║${RESET}"
echo -e "${NEGRITO}${VERDE}║  ae  amc  amcseries  animalplanet  axn               ║${RESET}"
echo -e "${NEGRITO}${VERDE}║  bandnews  bandsports  bis  bmcnews                  ║${RESET}"
echo -e "${NEGRITO}${VERDE}╠══════════════════════════════════════════════════════╣${RESET}"
echo -e "${NEGRITO}${VERDE}║  Comandos úteis:                                     ║${RESET}"
echo -e "${NEGRITO}${VERDE}║  sudo systemctl status ${SERVICE_NAME}                ║${RESET}"
echo -e "${NEGRITO}${VERDE}║  sudo systemctl restart ${SERVICE_NAME}               ║${RESET}"
echo -e "${NEGRITO}${VERDE}║  sudo tail -f ${LOG_FILE}            ║${RESET}"
echo -e "${NEGRITO}${VERDE}║                                                      ║${RESET}"
echo -e "${NEGRITO}${VERDE}║  ⚠  Nota: O primeiro pré-aquecimento pode levar     ║${RESET}"
echo -e "${NEGRITO}${VERDE}║     alguns minutos (login + captura por canal).      ║${RESET}"
echo -e "${NEGRITO}${VERDE}╚══════════════════════════════════════════════════════╝${RESET}"
echo -e ""

info "Para acompanhar o progresso inicial:"
echo -e "  ${NEGRITO}sudo tail -f ${LOG_FILE}${RESET}"
echo -e ""
