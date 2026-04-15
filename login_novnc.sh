#!/usr/bin/env bash
# =============================================================================
#  login_novnc.sh — Login skyMais via noVNC embutido no Flask (porta 8765)
#  Uso: skymais login   /   sudo bash /opt/skymais/login_novnc.sh
# =============================================================================
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

# ─── Garante Xvfb ────────────────────────────────────────────────────────────
if ! systemctl is-active --quiet xvfb-skymais 2>/dev/null; then
    info "Iniciando Xvfb..."
    systemctl start xvfb-skymais || true
    sleep 2
fi

# Verifica se display :99 responde
if ! DISPLAY=:99 xdpyinfo &>/dev/null 2>&1; then
    pkill -9 Xvfb 2>/dev/null || true
    sleep 1
    Xvfb :99 -screen 0 1280x800x24 -nolisten tcp &
    sleep 3
fi

DISPLAY=:99 xdpyinfo &>/dev/null 2>&1 \
    && ok "Xvfb rodando em :99" \
    || erro "Xvfb nao respondeu. Verifique: systemctl status xvfb-skymais"

# ─── x11vnc ──────────────────────────────────────────────────────────────────
if ! command -v x11vnc &>/dev/null; then
    info "Instalando x11vnc..."
    apt-get install -y -qq x11vnc || erro "Falha ao instalar x11vnc"
fi

pkill -9 x11vnc 2>/dev/null || true
sleep 1

info "Iniciando x11vnc em localhost:${VNC_PORT}..."

# -rfbport é o flag correto no x11vnc 0.9.16 (não -port)
x11vnc \
    -display   "${DISPLAY_NUM}" \
    -rfbport   "${VNC_PORT}" \
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

if ! pgrep -x x11vnc &>/dev/null; then
    echo "Log x11vnc:"
    cat /tmp/x11vnc.log 2>/dev/null || true
    erro "x11vnc nao iniciou. Veja /tmp/x11vnc.log"
fi
ok "x11vnc rodando em localhost:${VNC_PORT}"

# ─── Abre o browser de login AGORA (antes do usuário conectar) ───────────────
# Assim quando o usuário abrir o noVNC já verá o browser na tela
info "Abrindo browser de login na VPS..."
"${INSTALL_DIR}/venv/bin/python3" "${INSTALL_DIR}/login.py" &
LOGIN_PID=$!

# Aguarda o browser iniciar (alguns segundos para carregar a pagina)
sleep 5

# ─── IP público ──────────────────────────────────────────────────────────────
IP=$(curl -s --max-time 8 https://api.ipify.org 2>/dev/null \
    || hostname -I | awk '{print $1}')

# ─── Instruções ──────────────────────────────────────────────────────────────
echo ""
echo -e "${NEGRITO}${VERDE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${NEGRITO}  Browser aberto! Agora conecte via noVNC:${RESET}"
echo ""
echo -e "  ${NEGRITO}${VERDE}http://${IP}:${PORTA_FLASK}/vnc${RESET}"
echo ""
echo -e "  1. Acesse o link acima no seu browser (Chrome/Firefox)"
echo -e "  2. Clique em 'Conectar'"
echo -e "  3. Voce vera a janela do browser na VPS"
echo -e "  4. Resolva o captcha"
echo -e "  5. Clique no perfil P1"
echo -e "  6. O browser fechara sozinho e o login sera salvo"
echo -e "${NEGRITO}${VERDE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""
echo -e "  ${AMARELO}Aguardando conclusao do login (timeout: 5 minutos)...${RESET}"
echo -e "  ${AZUL}(Nao precisa pressionar nada — aguarde automaticamente)${RESET}"
echo ""

# ─── Aguarda login terminar ──────────────────────────────────────────────────
if wait "$LOGIN_PID" 2>/dev/null; then
    echo ""
    ok "Login concluido! Cookies salvos."
    SUCESSO=true
else
    echo ""
    aviso "Login falhou ou expirou (5 min)."
    aviso "Tente novamente: skymais login"
    SUCESSO=false
fi

# ─── Encerra x11vnc ──────────────────────────────────────────────────────────
info "Encerrando x11vnc..."
pkill -9 x11vnc 2>/dev/null || true

# ─── Reinicia serviço ────────────────────────────────────────────────────────
if [[ "$SUCESSO" == "true" ]]; then
    echo ""
    info "Reiniciando servico skymais..."
    systemctl restart skymais
    sleep 3

    if systemctl is-active --quiet skymais; then
        ok "Servico reiniciado com sucesso!"
        echo ""
        echo -e "  Playlist : http://${IP}:${PORTA_FLASK}/playlist.m3u"
        echo -e "  Status   : http://${IP}:${PORTA_FLASK}/status"
        echo ""
        ok "Pronto! Links VLC funcionando."
    else
        aviso "Servico nao reiniciou. Verifique: journalctl -u skymais -n 30"
    fi
fi
