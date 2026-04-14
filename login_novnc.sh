#!/usr/bin/env bash
# =============================================================================
#  login_novnc.sh — Login skyMais via noVNC (browser HTTP)
#
#  Não precisa de cliente VNC.
#  Não usa portas extras — proxia o VNC pelo websockify na porta 6080
#  (ou qualquer porta aberta que você informar).
#
#  Uso: sudo bash /opt/skymais/login_novnc.sh
#   ou: skymais login
# =============================================================================
set -euo pipefail

VERDE='\033[0;32m'; AMARELO='\033[1;33m'; VERMELHO='\033[0;31m'
AZUL='\033[0;34m'; NEGRITO='\033[1m'; RESET='\033[0m'
ok()    { echo -e "${VERDE} v ${*}${RESET}"; }
info()  { echo -e "${AZUL} > ${*}${RESET}"; }
aviso() { echo -e "${AMARELO} ! ${*}${RESET}"; }
erro()  { echo -e "${VERMELHO} X ${*}${RESET}"; exit 1; }

[[ $EUID -ne 0 ]] && erro "Execute como root: sudo bash ${0}"

INSTALL_DIR="/opt/skymais"
NOVNC_DIR="/opt/novnc"
DISPLAY_NUM=":99"
VNC_PORT=5901          # porta interna VNC (localhost only)
NOVNC_PORT=6080        # porta HTTP do noVNC (browser)

export DISPLAY="$DISPLAY_NUM"
export PLAYWRIGHT_BROWSERS_PATH="/root/.cache/ms-playwright"
export skyMAIS_DIR="$INSTALL_DIR"

echo ""
echo -e "${NEGRITO}${AZUL}=== skyMais - Login via Browser (noVNC) ===${RESET}"
echo ""

# ─── Garante Xvfb ────────────────────────────────────────────────────────────
if ! systemctl is-active --quiet xvfb-skymais 2>/dev/null; then
    info "Iniciando Xvfb..."
    systemctl start xvfb-skymais
    sleep 2
fi
ok "Xvfb rodando em ${DISPLAY_NUM}"

# ─── Instala x11vnc ──────────────────────────────────────────────────────────
if ! command -v x11vnc &>/dev/null; then
    info "Instalando x11vnc..."
    apt-get install -y -qq x11vnc
fi
ok "x11vnc OK"

# ─── Instala noVNC + websockify ──────────────────────────────────────────────
if [[ ! -d "$NOVNC_DIR" ]]; then
    info "Instalando noVNC..."
    apt-get install -y -qq python3-websockify git 2>/dev/null || \
        pip3 install websockify -q 2>/dev/null || true

    if command -v git &>/dev/null; then
        git clone --depth=1 --quiet \
            https://github.com/novnc/noVNC.git "$NOVNC_DIR" 2>/dev/null \
            || { aviso "git clone noVNC falhou, tentando wget..."; _instalar_novnc_wget; }
    else
        _instalar_novnc_wget
    fi
fi

_instalar_novnc_wget() {
    mkdir -p "$NOVNC_DIR"
    wget -q -O /tmp/novnc.tar.gz \
        "https://github.com/novnc/noVNC/archive/refs/heads/master.tar.gz" \
        && tar -xzf /tmp/novnc.tar.gz -C /tmp \
        && cp -r /tmp/noVNC-master/. "$NOVNC_DIR/" \
        && rm -f /tmp/novnc.tar.gz \
        && ok "noVNC extraído"
}

# Cria link vnc.html → vnc_lite.html se necessário
[[ ! -f "$NOVNC_DIR/vnc.html" && -f "$NOVNC_DIR/vnc_lite.html" ]] \
    && ln -sf "$NOVNC_DIR/vnc_lite.html" "$NOVNC_DIR/vnc.html"

ok "noVNC OK em $NOVNC_DIR"

# ─── Para instâncias anteriores ──────────────────────────────────────────────
pkill -9 x11vnc     2>/dev/null || true
pkill -9 websockify 2>/dev/null || true
sleep 1

# ─── Abre portas no firewall ─────────────────────────────────────────────────
for p in "$VNC_PORT" "$NOVNC_PORT"; do
    iptables -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null \
        || iptables -I INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || true
    command -v ufw &>/dev/null \
        && ufw allow "$p/tcp" >/dev/null 2>&1 || true
done

# ─── Inicia x11vnc (apenas localhost) ────────────────────────────────────────
info "Iniciando x11vnc na porta ${VNC_PORT} (localhost)..."
x11vnc \
    -display "${DISPLAY_NUM}" \
    -port    "${VNC_PORT}" \
    -localhost \
    -nopw \
    -forever \
    -shared  \
    -noxdamage \
    -bg \
    -o /tmp/x11vnc.log \
    2>/dev/null

sleep 2
pgrep -x x11vnc &>/dev/null || erro "x11vnc nao iniciou. Veja: cat /tmp/x11vnc.log"
ok "x11vnc rodando na porta ${VNC_PORT}"

# ─── Inicia websockify (VNC → WebSocket) ─────────────────────────────────────
info "Iniciando websockify na porta ${NOVNC_PORT}..."

# Tenta websockify do sistema, depois do pip, depois do noVNC utils
WEBSOCKIFY=""
for cmd in websockify /usr/bin/websockify "${NOVNC_DIR}/utils/websockify/run" \
           "$(python3 -m websockify 2>/dev/null || true)"; do
    command -v "$cmd" &>/dev/null 2>&1 && { WEBSOCKIFY="$cmd"; break; }
    [[ -f "$cmd" ]] && { WEBSOCKIFY="python3 $cmd"; break; }
done

if [[ -z "$WEBSOCKIFY" ]]; then
    pip3 install websockify -q 2>/dev/null && WEBSOCKIFY="websockify"
fi

[[ -z "$WEBSOCKIFY" ]] && erro "websockify não encontrado. Instale: pip3 install websockify"

nohup $WEBSOCKIFY \
    --web "$NOVNC_DIR" \
    "${NOVNC_PORT}" \
    "localhost:${VNC_PORT}" \
    > /tmp/websockify.log 2>&1 &

WSPY_PID=$!
sleep 3

if ! kill -0 "$WSPY_PID" 2>/dev/null; then
    erro "websockify nao iniciou. Veja: cat /tmp/websockify.log"
fi
ok "websockify PID ${WSPY_PID} rodando na porta ${NOVNC_PORT}"

# ─── Pega IP ─────────────────────────────────────────────────────────────────
IP=$(curl -s --max-time 8 https://api.ipify.org 2>/dev/null \
    || hostname -I | awk '{print $1}')

# ─── Mostra instruções ───────────────────────────────────────────────────────
echo ""
echo -e "${NEGRITO}${VERDE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${NEGRITO}  Acesse pelo browser (Chrome, Firefox, Edge...):${RESET}"
echo ""
echo -e "  ${NEGRITO}${VERDE}http://${IP}:${NOVNC_PORT}/vnc.html${RESET}"
echo ""
echo -e "  Sem instalar nada — funciona direto no browser!"
echo -e "${NEGRITO}${VERDE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""
echo -e "  ${AMARELO}Quando estiver conectado no browser, pressione ENTER aqui${RESET}"
echo -e "  para abrir o browser na VPS e resolver o captcha:"
read -r -p "  [ENTER para abrir o browser na VPS] " _

# ─── Abre browser na VPS ─────────────────────────────────────────────────────
info "Abrindo browser para login..."
"${INSTALL_DIR}/venv/bin/python3" "${INSTALL_DIR}/login.py" &
LOGIN_PID=$!

echo ""
echo -e "${NEGRITO}${AZUL}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${NEGRITO}  Browser aberto! Veja no noVNC no seu browser.${RESET}"
echo ""
echo -e "  ${AMARELO}PASSOS:${RESET}"
echo -e "  1. No browser, acesse: http://${IP}:${NOVNC_PORT}/vnc.html"
echo -e "  2. Clique em 'Conectar'"
echo -e "  3. Você verá a janela do browser na VPS"
echo -e "  4. Resolva o captcha"
echo -e "  5. Clique no perfil P1"
echo -e "  6. O browser da VPS fechará sozinho"
echo -e "${NEGRITO}${AZUL}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""

# ─── Aguarda o login terminar ────────────────────────────────────────────────
if wait "$LOGIN_PID" 2>/dev/null; then
    echo ""
    ok "Login concluido! Cookies salvos."
else
    aviso "Login pode ter falhado ou expirou (5 min)."
    aviso "Tente novamente: skymais login"
fi

# ─── Encerra VNC/websockify e fecha porta ────────────────────────────────────
info "Encerrando noVNC e x11vnc..."
kill "$WSPY_PID" 2>/dev/null || true
pkill -9 x11vnc     2>/dev/null || true
pkill -9 websockify 2>/dev/null || true

# Fecha porta noVNC (mantém só 8765)
iptables -D INPUT -p tcp --dport "$NOVNC_PORT" -j ACCEPT 2>/dev/null || true
command -v ufw &>/dev/null \
    && ufw delete allow "$NOVNC_PORT/tcp" >/dev/null 2>&1 || true

echo ""
info "Reiniciando servico skymais..."
systemctl restart skymais
sleep 3

if systemctl is-active --quiet skymais; then
    ok "Servico reiniciado com novos cookies!"
    echo ""
    echo -e "  Playlist: http://${IP}:8765/playlist.m3u"
    echo -e "  Status  : http://${IP}:8765/status"
else
    aviso "Servico nao reiniciou. Verifique: journalctl -u skymais -n 30"
fi
