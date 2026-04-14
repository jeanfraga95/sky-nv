#!/usr/bin/env bash
set -euo pipefail

VERDE='\033[0;32m'; AMARELO='\033[1;33m'; VERMELHO='\033[0;31m'
AZUL='\033[0;34m'; NEGRITO='\033[1m'; RESET='\033[0m'
ok()    { echo -e "${VERDE} v ${*}${RESET}"; }
info()  { echo -e "${AZUL} > ${*}${RESET}"; }
aviso() { echo -e "${AMARELO} ! ${*}${RESET}"; }
erro()  { echo -e "${VERMELHO} X ${*}${RESET}"; exit 1; }

[[ $EUID -ne 0 ]] && erro "Execute como root: sudo skymais login"

INSTALL_DIR="/opt/skymais"
VNC_PORT=5901
PORTA_FLASK=8765
DISPLAY_NUM=":99"

export DISPLAY="$DISPLAY_NUM"
export PLAYWRIGHT_BROWSERS_PATH="/root/.cache/ms-playwright"
export skyMAIS_DIR="$INSTALL_DIR"

echo ""
echo -e "${NEGRITO}${AZUL}=== skyMais — Login via Browser ===${RESET}"
echo ""

# ─── Xvfb ─────────────────────────────────────────────
if ! systemctl is-active --quiet xvfb-skymais 2>/dev/null; then
    info "Iniciando Xvfb..."
    systemctl start xvfb-skymais || true
    sleep 2
fi

if DISPLAY=:99 xdpyinfo &>/dev/null 2>&1; then
    ok "Xvfb rodando em :99"
else
    pkill -9 Xvfb 2>/dev/null || true
    sleep 1
    Xvfb :99 -screen 0 1280x800x24 -nolisten tcp &
    sleep 2
    ok "Xvfb iniciado manualmente em :99"
fi

# ─── x11vnc ───────────────────────────────────────────
if ! command -v x11vnc &>/dev/null; then
    info "Instalando x11vnc..."
    apt-get install -y -qq x11vnc || erro "Falha ao instalar x11vnc"
fi
ok "x11vnc disponivel"

pkill -9 x11vnc 2>/dev/null || true
sleep 1

info "Iniciando x11vnc em localhost:${VNC_PORT}..."

x11vnc \
    -display "${DISPLAY_NUM}" \
    -rfbport "${VNC_PORT}" \
    -localhost \
    -nopw \
    -forever \
    -shared \
    -noxdamage \
    -noipv6 \
    -bg \
    -logfile /tmp/x11vnc.log \
    2>/dev/null || true

sleep 2

if pgrep -x x11vnc &>/dev/null; then
    ok "x11vnc rodando em localhost:${VNC_PORT}"
else
    aviso "x11vnc nao iniciou, tentando modo verbose..."

    x11vnc -display "${DISPLAY_NUM}" -rfbport "${VNC_PORT}" -localhost -nopw \
        -forever -shared -noxdamage -noipv6 \
        > /tmp/x11vnc.log 2>&1 &

    sleep 3

    if ! pgrep -x x11vnc &>/dev/null; then
        echo ""
        echo "Log do x11vnc:"
        cat /tmp/x11vnc.log || true
        erro "x11vnc nao conseguiu iniciar"
    fi

    ok "x11vnc iniciado"
fi

# ─── IP ───────────────────────────────────────────────
IP=$(curl -s --max-time 8 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')

# ─── Instruções ───────────────────────────────────────
echo ""
echo -e "${NEGRITO}${VERDE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${NEGRITO}Acesse:${RESET}"
echo -e "  ${VERDE}http://${IP}:${PORTA_FLASK}/vnc${RESET}"
echo -e "${NEGRITO}${VERDE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""

read -r -p "Pressione ENTER para abrir o browser na VPS... " _

# ─── Login ────────────────────────────────────────────
info "Abrindo browser..."
"${INSTALL_DIR}/venv/bin/python3" "${INSTALL_DIR}/login.py" &
LOGIN_PID=$!

echo ""
echo "Resolva o captcha via noVNC..."

if wait "$LOGIN_PID" 2>/dev/null; then
    ok "Login concluido"
    SUCESSO=true
else
    aviso "Login falhou"
    SUCESSO=false
fi

# ─── Finalização ──────────────────────────────────────
info "Encerrando x11vnc..."
pkill -9 x11vnc 2>/dev/null || true

if [[ "$SUCESSO" == "true" ]]; then
    systemctl restart skymais
    sleep 3

    if systemctl is-active --quiet skymais; then
        ok "Servico ativo"
        echo "Playlist: http://${IP}:${PORTA_FLASK}/playlist.m3u"
    else
        aviso "Erro ao reiniciar serviço"
    fi
fi
