#!/usr/bin/env bash
# =============================================================================
#  skyMais IPTV Proxy — Instalador
#  Ubuntu 20.04 / 22.04 | ARM64 | x86_64 | Oracle Cloud VPS
#  Uso: sudo bash install.sh
#   ou: bash <(curl -s https://raw.githubusercontent.com/jeanfraga95/sky-nv/main/install.sh)
# =============================================================================
set -euo pipefail

VERDE='\033[0;32m'; AMARELO='\033[1;33m'; VERMELHO='\033[0;31m'
AZUL='\033[0;34m'; NEGRITO='\033[1m'; RESET='\033[0m'

ok()     { echo -e "${VERDE} v ${*}${RESET}"; }
info()   { echo -e "${AZUL} > ${*}${RESET}"; }
aviso()  { echo -e "${AMARELO} ! ${*}${RESET}"; }
erro()   { echo -e "${VERMELHO} X ${*}${RESET}"; exit 1; }
titulo() { echo -e "\n${NEGRITO}${AZUL}=== ${*} ===${RESET}"; }

# ─── Configurações ────────────────────────────────────────────────────────────
REPO_URL="https://github.com/jeanfraga95/sky-nv"
REPO_RAW="https://raw.githubusercontent.com/jeanfraga95/sky-nv/main"
INSTALL_DIR="/opt/skymais"
SERVICE_NAME="skymais"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
XVFB_SERVICE_FILE="/etc/systemd/system/xvfb-skymais.service"
LOG_DIR="/var/log/skymais"
LOG_FILE="${LOG_DIR}/app.log"
PORTA=8765

ARQUIVOS_PY=("app.py" "auth.py" "channels.py" "stream_manager.py" "login.py")

# ─── Cabeçalho ────────────────────────────────────────────────────────────────
echo ""
echo -e "${NEGRITO}${AZUL}=== skyMais IPTV Proxy - Instalador ===${RESET}"
echo ""

# ─── Verificações iniciais ────────────────────────────────────────────────────
titulo "Verificacoes"
[[ $EUID -ne 0 ]] && erro "Execute como root: sudo bash install.sh"
ok "Root OK"
ARCH=$(uname -m); ok "Arch: ${ARCH}"
[[ -f /etc/os-release ]] && { source /etc/os-release; info "SO: ${PRETTY_NAME}"; }

# ─── Corrige repos APT com problema (Oracle/Sury) ────────────────────────────
titulo "Corrigindo repos APT"

rm -f /etc/apt/sources.list.d/php.list \
      /etc/apt/sources.list.d/sury*.list \
      /etc/apt/sources.list.d/*php*.list 2>/dev/null || true

for f in /etc/apt/sources.list.d/*.list; do
    [[ -f "$f" ]] || continue
    grep -qE "packages\.sury\.org|ondrej" "$f" 2>/dev/null \
        && { aviso "Removendo: $f"; rm -f "$f"; } || true
done

sed -i '/packages\.sury\.org/d' /etc/apt/sources.list 2>/dev/null || true
ok "Repos limpos"

info "apt-get update..."
apt-get update -qq 2>&1 | grep -vE "^W:|^N:|^Get:|^Hit:|^Ign:" || true
ok "Pacotes atualizados"

# ─── Limpeza TOTAL da instalação anterior ─────────────────────────────────────
titulo "Limpeza TOTAL de instalacao anterior"

info "Parando servicos..."
systemctl stop  "${SERVICE_NAME}"    2>/dev/null || true
systemctl stop  "xvfb-skymais"   2>/dev/null || true
systemctl disable "${SERVICE_NAME}" 2>/dev/null || true
systemctl disable "xvfb-skymais" 2>/dev/null || true

info "Liberando porta ${PORTA}..."
if command -v fuser &>/dev/null; then
    fuser -k "${PORTA}/tcp" 2>/dev/null || true
fi
if command -v lsof &>/dev/null; then
    lsof -ti "tcp:${PORTA}" | xargs -r kill -9 2>/dev/null || true
fi
SS_PIDS=$(ss -tlnp "sport = :${PORTA}" 2>/dev/null \
    | grep -oP 'pid=\K[0-9]+' || true)
[[ -n "$SS_PIDS" ]] && echo "$SS_PIDS" | xargs -r kill -9 2>/dev/null || true

info "Matando processos do proxy..."
pkill -9 -f "${INSTALL_DIR}/app.py" 2>/dev/null || true
pkill -9 -f "skymais"            2>/dev/null || true
sleep 2

[[ -f "$SERVICE_FILE"      ]] && rm -f "$SERVICE_FILE"
[[ -f "$XVFB_SERVICE_FILE" ]] && rm -f "$XVFB_SERVICE_FILE"
systemctl daemon-reload

if [[ -d "$INSTALL_DIR" ]]; then
    info "Removendo ${INSTALL_DIR}..."
    rm -rf "$INSTALL_DIR"
fi

if ss -tlnp | grep -q ":${PORTA}"; then
    erro "Porta ${PORTA} ainda ocupada! Execute: fuser -k ${PORTA}/tcp"
fi
ok "Limpeza OK - porta ${PORTA} livre"

# ─── Dependências do sistema ──────────────────────────────────────────────────
titulo "Dependencias do sistema"

DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    python3 python3-pip python3-venv \
    git curl wget ca-certificates \
    net-tools lsof psmisc \
    xvfb \
    libglib2.0-0 libnss3 libnspr4 libatk1.0-0 libatk-bridge2.0-0 \
    libcups2 libdrm2 libdbus-1-3 libexpat1 libxcb1 libxkbcommon0 \
    libx11-6 libxcomposite1 libxdamage1 libxext6 libxfixes3 libxrandr2 \
    libgbm1 libpango-1.0-0 libcairo2 libasound2 libatspi2.0-0 \
    libx11-xcb1 libxcursor1 libxi6 libxtst6 \
    fonts-liberation lsb-release scrot xdotool imagemagick 2>/dev/null || true

ok "Dependencias OK"

# ─── Download dos arquivos do GitHub ─────────────────────────────────────────
titulo "Baixando arquivos do GitHub"

mkdir -p "${INSTALL_DIR}" "${LOG_DIR}"
touch "${LOG_FILE}"
chmod 666 "${LOG_FILE}"

info "Repositorio: ${REPO_URL}"

# Tenta git clone; fallback para wget por arquivo
CLONE_OK=false
if command -v git &>/dev/null; then
    info "Clonando via git..."
    if git clone --depth=1 --quiet "${REPO_URL}" /tmp/_skymais_clone 2>/dev/null; then
        cp -f /tmp/_skymais_clone/*.py      "${INSTALL_DIR}/" 2>/dev/null || true
        cp -f /tmp/_skymais_clone/*.txt     "${INSTALL_DIR}/" 2>/dev/null || true
        cp -f /tmp/_skymais_clone/*.service "${INSTALL_DIR}/" 2>/dev/null || true
        rm -rf /tmp/_skymais_clone
        CLONE_OK=true
        ok "git clone OK"
    else
        aviso "git clone falhou, usando wget por arquivo..."
    fi
fi

if [[ "$CLONE_OK" == "false" ]]; then
    for arq in "${ARQUIVOS_PY[@]}" "requeriments.txt" "requirements.txt"; do
        if wget -q --timeout=15 -O "${INSTALL_DIR}/${arq}" \
                "${REPO_RAW}/${arq}" 2>/dev/null; then
            ok "${arq} baixado"
        else
            rm -f "${INSTALL_DIR}/${arq}" 2>/dev/null || true
        fi
    done
fi

# Valida que os arquivos essenciais existem
for arq in "${ARQUIVOS_PY[@]}"; do
    [[ -f "${INSTALL_DIR}/${arq}" ]] \
        || erro "Arquivo essencial ausente: ${INSTALL_DIR}/${arq} — verifique o repositorio ${REPO_URL}"
done
ok "Todos os arquivos presentes em ${INSTALL_DIR}"

# ─── Ambiente Python ──────────────────────────────────────────────────────────
titulo "Ambiente Python"

cd "${INSTALL_DIR}"
python3 -m venv venv
ok "Virtualenv criado"

info "Atualizando pip..."
"${INSTALL_DIR}/venv/bin/pip" install --upgrade pip -q

# Detecta nome do arquivo de requirements
REQ=""
for nome in "requirements.txt" "requeriments.txt"; do
    [[ -f "${INSTALL_DIR}/${nome}" ]] && { REQ="${INSTALL_DIR}/${nome}"; break; }
done

if [[ -n "$REQ" ]]; then
    info "Instalando dependencias de ${REQ}..."
    "${INSTALL_DIR}/venv/bin/pip" install -q -r "${REQ}"
else
    info "requirements.txt nao encontrado, instalando pacotes base..."
    "${INSTALL_DIR}/venv/bin/pip" install -q flask requests playwright
fi
ok "Pacotes Python OK"

# ─── Playwright + Chromium ───────────────────────────────────────────────────
titulo "Instalando Chromium via Playwright"

info "Pode levar 2-5 minutos..."
export PLAYWRIGHT_BROWSERS_PATH="/root/.cache/ms-playwright"

"${INSTALL_DIR}/venv/bin/playwright" install chromium 2>&1 | tail -5
"${INSTALL_DIR}/venv/bin/playwright" install-deps chromium 2>/dev/null \
    || aviso "install-deps retornou aviso (normal em ARM)"

ok "Chromium OK"

# ─── Xvfb ────────────────────────────────────────────────────────────────────
titulo "Configurando Xvfb (display virtual)"

cat > "${XVFB_SERVICE_FILE}" << 'EOF'
[Unit]
Description=Xvfb Virtual Display - skyMais
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/Xvfb :99 -screen 0 1280x800x24 -nolisten tcp
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable xvfb-skymais
systemctl start  xvfb-skymais
sleep 2

if systemctl is-active --quiet xvfb-skymais; then
    ok "Xvfb rodando em :99"
else
    aviso "Xvfb nao iniciou - verifique: journalctl -u xvfb-skymais"
fi

# ─── Serviço systemd ─────────────────────────────────────────────────────────
titulo "Servico systemd"

cat > "${SERVICE_FILE}" << EOF
[Unit]
Description=skyMais IPTV Proxy
After=network-online.target xvfb-skymais.service
Wants=network-online.target xvfb-skymais.service
StartLimitIntervalSec=0

[Service]
Type=simple
User=root
WorkingDirectory=${INSTALL_DIR}
ExecStart=${INSTALL_DIR}/venv/bin/python3 ${INSTALL_DIR}/app.py
Restart=on-failure
RestartSec=10
StandardOutput=append:${LOG_FILE}
StandardError=append:${LOG_FILE}
Environment=PYTHONUNBUFFERED=1
Environment=PLAYWRIGHT_BROWSERS_PATH=/root/.cache/ms-playwright
Environment=DISPLAY=:99
Environment=skyMAIS_DIR=${INSTALL_DIR}
Environment=skyMAIS_PORT=${PORTA}
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "${SERVICE_NAME}"
ok "Servico systemd configurado"

# ─── Firewall ────────────────────────────────────────────────────────────────
titulo "Firewall - porta ${PORTA}"

command -v ufw &>/dev/null \
    && ufw allow "${PORTA}/tcp" >/dev/null 2>&1 \
    && ok "ufw: porta ${PORTA} aberta"

iptables -C INPUT -p tcp --dport "${PORTA}" -j ACCEPT 2>/dev/null \
    || { iptables -I INPUT -p tcp --dport "${PORTA}" -j ACCEPT; ok "iptables: porta ${PORTA} liberada"; }

# Persiste
if command -v netfilter-persistent &>/dev/null; then
    netfilter-persistent save >/dev/null 2>&1 || true
elif [[ -d /etc/iptables ]]; then
    iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
fi

# ─── Sobe o serviço ──────────────────────────────────────────────────────────
titulo "Instalando x11vnc (login remoto)"
if ! command -v x11vnc &>/dev/null; then
    apt-get install -y -qq x11vnc 2>/dev/null && ok "x11vnc instalado" \
        || aviso "x11vnc nao instalou - login vnc pode falhar"
else
    ok "x11vnc ja disponivel"
fi

# Copia login_novnc.sh para INSTALL_DIR (vem do clone ou baixa separado)
SCRIPT_ORIGIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/login_novnc.sh"
if [[ -f "$SCRIPT_ORIGIN" ]]; then
    cp -f "$SCRIPT_ORIGIN" "${INSTALL_DIR}/login_novnc.sh"
elif [[ ! -f "${INSTALL_DIR}/login_novnc.sh" ]]; then
    info "Baixando login_novnc.sh do GitHub..."
    wget -q -O "${INSTALL_DIR}/login_novnc.sh" "${REPO_RAW}/login_novnc.sh" 2>/dev/null \
        || aviso "login_novnc.sh nao encontrado no repo ainda - adicione ao GitHub"
fi
[[ -f "${INSTALL_DIR}/login_novnc.sh" ]] && chmod +x "${INSTALL_DIR}/login_novnc.sh" && ok "login_novnc.sh OK"

titulo "Iniciando servico"

ss -tlnp | grep -q ":${PORTA}" \
    && { aviso "Porta ocupada, forcando liberacao..."; fuser -k "${PORTA}/tcp" 2>/dev/null || true; sleep 2; }

systemctl start "${SERVICE_NAME}"

info "Aguardando estabilizacao (ate 20s)..."
for i in $(seq 1 20); do
    sleep 1
    if systemctl is-active --quiet "${SERVICE_NAME}"; then
        ok "Servico ativo! (${i}s)"
        break
    fi
    [[ $i -eq 20 ]] && aviso "Ainda iniciando (normal na 1a vez - capturando canais)"
done

# ─── Comando 'skymais' ────────────────────────────────────────────────────
titulo "Criando comando skymais"

cat > /usr/local/bin/skymais << CMDEOF
#!/usr/bin/env bash
SVC="${SERVICE_NAME}"
DIR="${INSTALL_DIR}"
LOG="${LOG_FILE}"
PORTA="${PORTA}"
REPO_RAW="${REPO_RAW}"

case "\${1:-status}" in
    start)
        systemctl start xvfb-skymais && systemctl start "\$SVC"
        echo "Servico iniciado."
        ;;
    stop)
        systemctl stop "\$SVC"
        echo "Servico parado."
        ;;
    restart)
        systemctl restart xvfb-skymais && systemctl restart "\$SVC"
        echo "Servico reiniciado."
        ;;
    status)
        systemctl status "\$SVC" --no-pager -l
        ;;
    login)
        echo "Iniciando login via VNC (resolva o captcha remotamente)..."
        bash "\$DIR/login_novnc.sh"
        ;;
    refresh)
        curl -sf "http://localhost:\${PORTA}/refresh" \
            | python3 -m json.tool 2>/dev/null \
            || curl -sf "http://localhost:\${PORTA}/refresh"
        ;;
    logs)
        journalctl -u "\$SVC" -f --no-pager
        ;;
    urls)
        curl -sf "http://localhost:\${PORTA}/status" | python3 -m json.tool
        ;;
    update)
        echo "Atualizando arquivos do GitHub..."
        for f in app.py auth.py channels.py stream_manager.py login.py; do
            wget -q -O "\$DIR/\$f" "\$REPO_RAW/\$f" && echo "  ok \$f" || echo "  falhou \$f"
        done
        systemctl restart "\$SVC"
        echo "Atualizado e reiniciado."
        ;;
    *)
        echo "Uso: skymais {start|stop|restart|status|login|refresh|logs|urls|update}"
        ;;
esac
CMDEOF

chmod +x /usr/local/bin/skymais
ok "Comando skymais disponivel"

# ─── Resumo ───────────────────────────────────────────────────────────────────
IP_LOCAL=$(hostname -I | awk '{print $1}')
IP=$(curl -s --max-time 8 https://api.ipify.org 2>/dev/null || echo "$IP_LOCAL")

echo ""
echo -e "${NEGRITO}${VERDE}=== Instalacao concluida! ===${RESET}"
echo ""
echo -e "  Playlist M3U : http://${IP}:${PORTA}/playlist.m3u"
echo -e "  Status       : http://${IP}:${PORTA}/status"
echo ""
echo -e "  Links fixos para VLC:"
echo -e "    A&E           http://${IP}:${PORTA}/live/aee"
echo -e "    AMC           http://${IP}:${PORTA}/live/amc"
echo -e "    AMC Series    http://${IP}:${PORTA}/live/amc-series"
echo -e "    Animal Planet http://${IP}:${PORTA}/live/animal-planet"
echo -e "    AXN           http://${IP}:${PORTA}/live/axn"
echo ""
echo -e "${AMARELO}  PROXIMO PASSO: faca o login via VNC (uma unica vez):${RESET}"
echo -e "  $ skymais login

  Isso ira:
   1. Abrir VNC na porta 5900 com senha: sky123
   2. Conecte com RealVNC/TightVNC → ${IP}:5900
   3. Resolva o captcha na janela do browser
   4. VNC encerra sozinho apos o login"
echo ""
echo -e "  Logs : tail -f ${LOG_FILE}"
echo -e "  Ajuda: skymais --help"
echo ""
