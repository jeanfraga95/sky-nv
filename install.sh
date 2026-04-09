#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════╗
# ║   SKY Mais IPTV Proxy - Instalador v2                    ║
# ║   Compatível: Ubuntu 20.04 / 22.04 | ARM64 | x86_64         ║
# ║   GitHub: https://github.com/jeanfraga95/sky-nv             ║
# ╚══════════════════════════════════════════════════════════════╝

set -euo pipefail

VERDE='\033[0;32m'; AMARELO='\033[1;33m'; VERMELHO='\033[0;31m'
AZUL='\033[0;34m'; NEGRITO='\033[1m'; RESET='\033[0m'

ok()    { echo -e "${VERDE}  ✓ ${*}${RESET}"; }
info()  { echo -e "${AZUL}  → ${*}${RESET}"; }
aviso() { echo -e "${AMARELO}  ⚠ ${*}${RESET}"; }
erro()  { echo -e "${VERMELHO}  ✗ ${*}${RESET}"; exit 1; }
titulo(){ echo -e "\n${NEGRITO}${AZUL}══ ${*} ══${RESET}"; }

REPO_BASE="https://raw.githubusercontent.com/jeanfraga95/sky-nv/main"
INSTALL_DIR="/opt/sky_proxy"
SERVICE_NAME="sky_proxy"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
LOG_FILE="/var/log/sky_proxy.log"
PORTA=8890

echo -e ""
echo -e "${NEGRITO}${AZUL}╔══════════════════════════════════════════════╗${RESET}"
echo -e "${NEGRITO}${AZUL}║     SKY Mais IPTV Proxy - Instalador      ║${RESET}"
echo -e "${NEGRITO}${AZUL}║   ARM64 / x86_64  |  Ubuntu 20.04 / 22.04   ║${RESET}"
echo -e "${NEGRITO}${AZUL}╚══════════════════════════════════════════════╝${RESET}"
echo -e ""

# ─── Verificações ────────────────────────────────────────────────────────────

titulo "Verificações"
[[ $EUID -ne 0 ]] && erro "Execute como root: sudo bash install.sh"
ok "Executando como root"
ARCH=$(uname -m)
ok "Arquitetura: $ARCH"
[[ -f /etc/os-release ]] && { source /etc/os-release; info "Sistema: $PRETTY_NAME"; }

# ─── Corrige repositórios APT quebrados ──────────────────────────────────────

titulo "Corrigindo repositórios APT"
info "Removendo repositórios de terceiros problemáticos..."

# Remove o repo Sury PHP (causador do erro 418 / not signed)
rm -f /etc/apt/sources.list.d/php.list \
      /etc/apt/sources.list.d/sury*.list \
      /etc/apt/sources.list.d/*php*.list 2>/dev/null || true

# Varre todos os .list e remove linhas com repos conhecidamente problemáticos
for f in /etc/apt/sources.list.d/*.list; do
    [[ -f "$f" ]] || continue
    if grep -qE "packages\.sury\.org|ondrej" "$f" 2>/dev/null; then
        aviso "Removendo: $f"
        rm -f "$f"
    fi
done

# Desabilita no sources.list principal também, se houver
sed -i '/packages\.sury\.org/d' /etc/apt/sources.list 2>/dev/null || true

ok "Repositórios problemáticos removidos"

info "Atualizando lista de pacotes..."
# Ignora erros de repos opcionais mas continua
apt-get update -qq 2>&1 | grep -vE "^W:|^N:|^Get:|^Hit:|^Ign:" || true
ok "Lista de pacotes atualizada"

# ─── Remove instalação anterior ──────────────────────────────────────────────

titulo "Limpeza de instalação anterior"

if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
    info "Parando serviço anterior..."
    systemctl stop "$SERVICE_NAME"
    ok "Serviço parado"
fi
systemctl disable "$SERVICE_NAME" 2>/dev/null || true
if [[ -f "$SERVICE_FILE" ]]; then
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload
    ok "Service file removido"
fi
if [[ -d "$INSTALL_DIR" ]]; then
    info "Removendo instalação anterior: $INSTALL_DIR"
    rm -rf "$INSTALL_DIR"
    ok "Diretório removido"
fi

# ─── Dependências do sistema ──────────────────────────────────────────────────

titulo "Dependências do sistema"
info "Instalando pacotes necessários..."

DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    python3 python3-pip python3-venv \
    curl wget ca-certificates gnupg unzip \
    xvfb \
    libglib2.0-0 libnss3 libnspr4 libatk1.0-0 \
    libatk-bridge2.0-0 libcups2 libdrm2 libdbus-1-3 \
    libexpat1 libxcb1 libxkbcommon0 libx11-6 \
    libxcomposite1 libxdamage1 libxext6 libxfixes3 \
    libxrandr2 libgbm1 libpango-1.0-0 libcairo2 \
    libasound2 libatspi2.0-0 fonts-liberation \
    libx11-xcb1 libxcursor1 libxi6 libxtst6 \
    lsb-release 2>/dev/null || true

ok "Dependências do sistema instaladas"

# ─── Ambiente Python ──────────────────────────────────────────────────────────

titulo "Ambiente Python"

mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

info "Criando ambiente virtual..."
python3 -m venv venv
source venv/bin/activate

info "Atualizando pip..."
pip install --upgrade pip -q

info "Instalando pacotes Python (playwright, requests)..."
pip install -q playwright requests

ok "Pacotes Python instalados"

info "Baixando e instalando Chromium via Playwright (pode levar ~2 min)..."
PLAYWRIGHT_BROWSERS_PATH=/root/.cache/ms-playwright playwright install chromium

info "Instalando dependências do SO para o Chromium..."
PLAYWRIGHT_BROWSERS_PATH=/root/.cache/ms-playwright playwright install-deps chromium 2>/dev/null || \
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        libwoff1 libopus0 libwebpdemux2 libharfbuzz-icu0 \
        libflite1 libgles2 2>/dev/null || true

ok "Chromium instalado com sucesso"

# ─── Download do script principal ────────────────────────────────────────────

titulo "Download do script"

info "Baixando sky_proxy.py de ${REPO_BASE}..."
curl -fsSL "${REPO_BASE}/sky_proxy.py" -o "${INSTALL_DIR}/sky_proxy.py"
chmod +x "${INSTALL_DIR}/sky_proxy.py"
ok "sky_proxy.py baixado"

touch "$LOG_FILE"
chmod 666 "$LOG_FILE"

# ─── Serviço systemd ──────────────────────────────────────────────────────────

titulo "Configurando serviço systemd"

cat > "$SERVICE_FILE" << EOF
[Unit]
Description=SKY Mais IPTV Proxy - Links Fixos
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=120
StartLimitBurst=5

[Service]
Type=simple
User=root
WorkingDirectory=${INSTALL_DIR}
ExecStart=${INSTALL_DIR}/venv/bin/python3 ${INSTALL_DIR}/sky_proxy.py
Restart=on-failure
RestartSec=20
StandardOutput=append:${LOG_FILE}
StandardError=append:${LOG_FILE}
Environment=PYTHONUNBUFFERED=1
Environment=PYTHONDONTWRITEBYTECODE=1
Environment=PLAYWRIGHT_BROWSERS_PATH=/root/.cache/ms-playwright
LimitNOFILE=65536
LimitNPROC=4096

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "$SERVICE_NAME"
systemctl start "$SERVICE_NAME"
ok "Serviço criado e iniciado"

# ─── Verifica status ──────────────────────────────────────────────────────────

titulo "Verificando serviço"
sleep 4

if systemctl is-active --quiet "$SERVICE_NAME"; then
    ok "Serviço rodando"
else
    aviso "Serviço ainda inicializando (normal na 1ª vez — captura todos os canais)"
    aviso "Acompanhe: sudo journalctl -u $SERVICE_NAME -f"
fi

# ─── IP da VPS ────────────────────────────────────────────────────────────────

IP_LOCAL=$(hostname -I | awk '{print $1}')
IP_PUBLICO=$(curl -s --max-time 8 https://api.ipify.org 2>/dev/null || \
             curl -s --max-time 8 https://ifconfig.me 2>/dev/null || \
             echo "$IP_LOCAL")

# ─── Resumo ───────────────────────────────────────────────────────────────────

echo -e ""
echo -e "${NEGRITO}${VERDE}╔══════════════════════════════════════════════════════════╗${RESET}"
echo -e "${NEGRITO}${VERDE}║         ✓  Instalação concluída com sucesso!             ║${RESET}"
echo -e "${NEGRITO}${VERDE}╠══════════════════════════════════════════════════════════╣${RESET}"
echo -e ""
echo -e "  📋  ${NEGRITO}Playlist M3U (todos os canais + 3 qualidades):${RESET}"
echo -e "      http://${IP_PUBLICO}:${PORTA}/playlist.m3u"
echo -e ""
echo -e "  🔍  ${NEGRITO}Status / URLs individuais:${RESET}"
echo -e "      http://${IP_PUBLICO}:${PORTA}/status"
echo -e ""
echo -e "  ▶   ${NEGRITO}Exemplo A&E no VLC:${RESET}"
echo -e "      FHD → http://${IP_PUBLICO}:${PORTA}/stream/ae/fhd"
echo -e "      HD  → http://${IP_PUBLICO}:${PORTA}/stream/ae/hd"
echo -e "      SD  → http://${IP_PUBLICO}:${PORTA}/stream/ae/sd"
echo -e ""
echo -e "  📡  ${NEGRITO}Canais:${RESET} ae | amc | amcseries | animalplanet | axn"
echo -e "              bandnews | bandsports | bis | bmcnews"
echo -e ""
echo -e "${NEGRITO}${VERDE}╠══════════════════════════════════════════════════════════╣${RESET}"
echo -e "  ${NEGRITO}Comandos úteis:${RESET}"
echo -e "  Status   → sudo systemctl status ${SERVICE_NAME}"
echo -e "  Reiniciar→ sudo systemctl restart ${SERVICE_NAME}"
echo -e "  Logs     → sudo tail -f ${LOG_FILE}"
echo -e "  Logs sys → sudo journalctl -u ${SERVICE_NAME} -f"
echo -e "  Refresh  → curl http://localhost:${PORTA}/refresh"
echo -e ""
echo -e "${NEGRITO}${AMARELO}  ⚠  O pré-aquecimento inicial captura todos os 9 canais."
echo -e "     Pode levar até 5 minutos. Acompanhe com:${RESET}"
echo -e "     sudo tail -f ${LOG_FILE}"
echo -e ""
