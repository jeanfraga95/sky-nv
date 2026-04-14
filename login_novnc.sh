#!/usr/bin/env bash
# =============================================================================
#  login_novnc.sh — Inicia x11vnc e abre o login via noVNC embutido no Flask
#  O noVNC roda dentro do Flask na porta 8765 (já aberta).
#  Nenhuma porta extra necessária.
#
#  Uso: skymais login   (ou: sudo bash /opt/skymais/login_novnc.sh)
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

if DISPLAY=:99 xdpyinfo &>/dev/null 2>&1; then
    ok "Xvfb rodando em :99"
else
    # Tenta iniciar Xvfb manualmente
    pkill -9 Xvfb 2>/dev/null || true
    sleep 1
    Xvfb :99 -screen 0 1280x800x24 -nolisten tcp &
    sleep 2
    ok "Xvfb iniciado manualmente em :99"
fi

# ─── Instala x11vnc ──────────────────────────────────────────────────────────
if ! command -v x11vnc &>/dev/null; then
    info "Instalando x11vnc..."
    apt-get install -y -qq x11vnc 2>/dev/null || erro "Falha ao instalar x11vnc"
fi
ok "x11vnc disponivel"

# ─── Para x11vnc anterior ────────────────────────────────────────────────────
pkill -9 x11vnc 2>/dev/null || true
sleep 1

# ─── Inicia x11vnc vinculado apenas ao localhost ─────────────────────────────
info "Iniciando x11vnc em localhost:${VNC_PORT}..."

x11vnc \
    -display "${DISPLAY_NUM}" \
    -port    "${VNC_PORT}" \
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
    # Tenta sem -bg para ver o erro
    aviso "x11vnc nao iniciou, tentando modo verbose..."
    x11vnc -display "${DISPLAY_NUM}" -port "${VNC_PORT}" -localhost -nopw \
        -forever -shared -noxdamage -noipv6 \
        > /tmp/x11vnc.log 2>&1 &
    sleep 3
    if ! pgrep -x x11vnc &>/dev/null; then
        echo ""
        echo "Log do x11vnc:"
        cat /tmp/x11vnc.log || true
        erro "x11vnc nao conseguiu iniciar. Veja /tmp/x11vnc.log"
    fi
    ok "x11vnc iniciado"
fi

# ─── IP público ──────────────────────────────────────────────────────────────
IP=$(curl -s --max-time 8 https://api.ipify.org 2>/dev/null \
    || hostname -I | awk '{print $1}')

# ─── Instrucoes ──────────────────────────────────────────────────────────────
echo ""
echo -e "${NEGRITO}${VERDE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${NEGRITO}  Acesse pelo browser (Chrome, Firefox, Edge...):${RESET}"
echo ""
echo -e "  ${NEGRITO}${VERDE}http://${IP}:${PORTA_FLASK}/vnc${RESET}"
echo ""
echo -e "  Porta ${PORTA_FLASK} — a mesma que ja esta aberta!"
echo -e "  Sem instalar nada, sem portas extras."
echo -e "${NEGRITO}${VERDE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""
echo -e "  ${AMARELO}PASSOS:${RESET}"
echo -e "  1. Abra no browser: http://${IP}:${PORTA_FLASK}/vnc"
echo -e "  2. Clique em 'Conectar'"
echo -e "  3. Aguarde — abriremos o browser na VPS"
echo -e "  4. Resolva o captcha"
echo -e "  5. Clique no perfil P1"
echo -e "  6. O browser da VPS fechara sozinho"
echo ""
echo -e "  ${AMARELO}Quando estiver vendo o desktop no browser, pressione ENTER:${RESET}"
read -r -p "  [ENTER para abrir o browser de login na VPS] " _

# ─── Abre browser de login ───────────────────────────────────────────────────
info "Abrindo browser para login..."
"${INSTALL_DIR}/venv/bin/python3" "${INSTALL_DIR}/login.py" &
LOGIN_PID=$!

echo ""
echo -e "  ${AZUL}Browser aberto! Resolva o captcha na janela do noVNC.${RESET}"
echo -e "  Aguardando login (timeout: 5 minutos)..."
echo ""

# ─── Aguarda login ───────────────────────────────────────────────────────────
if wait "$LOGIN_PID" 2>/dev/null; then
    echo ""
    ok "Login concluido! Cookies salvos."
    SUCESSO=true
else
    echo ""
    aviso "Login falhou ou expirou."
    aviso "Tente novamente: skymais login"
    SUCESSO=false
fi

# ─── Encerra x11vnc ──────────────────────────────────────────────────────────
info "Encerrando x11vnc..."
pkill -9 x11vnc 2>/dev/null || true

if [[ "$SUCESSO" == "true" ]]; then
    echo ""
    info "Reiniciando servico skymais..."
    systemctl restart skymais
    sleep 3

    if systemctl is-active --quiet skymais; then
        ok "Servico reiniciado com sucesso!"
        echo ""
        echo -e "  Playlist: http://${IP}:${PORTA_FLASK}/playlist.m3u"
        echo -e "  Status  : http://${IP}:${PORTA_FLASK}/status"
        echo ""
        ok "Sistema pronto! Os links VLC ja funcionam."
    else
        aviso "Servico nao reiniciou. Verifique: journalctl -u skymais -n 30"
    fi
fi
