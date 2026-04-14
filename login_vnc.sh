#!/usr/bin/env bash
# =============================================================================
#  login_vnc.sh â€” Login skyMais via VNC remoto
#  Inicia x11vnc no display :99 (Xvfb), abre o browser para vocÃª
#  conectar remotamente e resolver o captcha.
#
#  Uso: sudo bash /opt/skymais/login_vnc.sh
# =============================================================================
set -euo pipefail

VERDE='\033[0;32m'; AMARELO='\033[1;33m'; VERMELHO='\033[0;31m'
AZUL='\033[0;34m'; NEGRITO='\033[1m'; RESET='\033[0m'

ok()    { echo -e "${VERDE} v ${*}${RESET}"; }
info()  { echo -e "${AZUL} > ${*}${RESET}"; }
aviso() { echo -e "${AMARELO} ! ${*}${RESET}"; }
erro()  { echo -e "${VERMELHO} X ${*}${RESET}"; exit 1; }

INSTALL_DIR="/opt/skymais"
VNC_PORT=5900
VNC_SENHA="sky123"
DISPLAY_NUM=":99"
export DISPLAY="$DISPLAY_NUM"
export PLAYWRIGHT_BROWSERS_PATH="/root/.cache/ms-playwright"
export skyMAIS_DIR="$INSTALL_DIR"

# â”€â”€â”€ Verifica root â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
[[ $EUID -ne 0 ]] && erro "Execute como root: sudo bash ${0}"

echo ""
echo -e "${NEGRITO}${AZUL}=== skyMais â€” Login via VNC ===${RESET}"
echo ""

# â”€â”€â”€ Garante Xvfb rodando â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
if ! systemctl is-active --quiet xvfb-skymais 2>/dev/null; then
    info "Iniciando Xvfb..."
    systemctl start xvfb-skymais
    sleep 2
fi
ok "Xvfb rodando em ${DISPLAY_NUM}"

# â”€â”€â”€ Instala x11vnc se necessÃ¡rio â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
if ! command -v x11vnc &>/dev/null; then
    info "Instalando x11vnc..."
    apt-get install -y -qq x11vnc 2>/dev/null
fi
ok "x11vnc disponÃ­vel"

# â”€â”€â”€ Mata instÃ¢ncia anterior do x11vnc â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
pkill -9 x11vnc 2>/dev/null || true
sleep 1

# â”€â”€â”€ Pega IP pÃºblico da VPS â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
IP=$(curl -s --max-time 8 https://api.ipify.org 2>/dev/null \
    || hostname -I | awk '{print $1}')

# â”€â”€â”€ Abre porta VNC no firewall â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
iptables -C INPUT -p tcp --dport "${VNC_PORT}" -j ACCEPT 2>/dev/null \
    || iptables -I INPUT -p tcp --dport "${VNC_PORT}" -j ACCEPT 2>/dev/null || true
command -v ufw &>/dev/null \
    && ufw allow "${VNC_PORT}/tcp" >/dev/null 2>&1 || true

# â”€â”€â”€ Inicia x11vnc em background â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
info "Iniciando servidor VNC na porta ${VNC_PORT}..."
x11vnc \
    -display "${DISPLAY_NUM}" \
    -passwd  "${VNC_SENHA}" \
    -port    "${VNC_PORT}" \
    -forever \
    -shared  \
    -noxdamage \
    -bg \
    -o /tmp/x11vnc.log \
    2>/dev/null

sleep 2

if ! pgrep -x x11vnc &>/dev/null; then
    erro "x11vnc nÃ£o iniciou. Veja: cat /tmp/x11vnc.log"
fi
ok "VNC rodando na porta ${VNC_PORT}"

# â”€â”€â”€ InstruÃ§Ãµes de conexÃ£o â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
echo ""
echo -e "${NEGRITO}${VERDE}â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”${RESET}"
echo -e "${NEGRITO}  Conecte agora no seu VNC Viewer:${RESET}"
echo ""
echo -e "  ${NEGRITO}EndereÃ§o : ${VERDE}${IP}:${VNC_PORT}${RESET}"
echo -e "  ${NEGRITO}Senha    : ${VERDE}${VNC_SENHA}${RESET}"
echo ""
echo -e "  Clientes VNC gratuitos:"
echo -e "   â€¢ Windows/Mac/Linux: https://www.realvnc.com/pt/connect/download/viewer/"
echo -e "   â€¢ Windows: TightVNC  https://www.tightvnc.com/download.php"
echo -e "   â€¢ Linux:   $ vncviewer ${IP}:${VNC_PORT}"
echo -e "${NEGRITO}${VERDE}â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”${RESET}"
echo ""
echo -e "${AMARELO}  Aguardando vocÃª se conectar via VNC antes de abrir o browser...${RESET}"
echo -e "  (pressione ENTER quando estiver conectado e pronto)"
read -r -p "" _

# â”€â”€â”€ Abre browser no Xvfb via Playwright â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
info "Abrindo browser para login..."

"${INSTALL_DIR}/venv/bin/python3" "${INSTALL_DIR}/login.py" &
LOGIN_PID=$!

echo ""
echo -e "${NEGRITO}${AZUL}â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”${RESET}"
echo -e "${NEGRITO}  Browser aberto! No VNC Viewer vocÃª verÃ¡ a janela.${RESET}"
echo ""
echo -e "  ${AMARELO}AGORA:${RESET}"
echo -e "  1. Olhe a tela no VNC Viewer"
echo -e "  2. O email e senha jÃ¡ estarÃ£o preenchidos"
echo -e "  3. Resolva o captcha que aparecer"
echo -e "  4. ApÃ³s redirecionar para o perfil, clique em P1"
echo -e "  5. Aguarde â€” o browser fecharÃ¡ sozinho"
echo -e "${NEGRITO}${AZUL}â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”â”${RESET}"
echo ""

# Aguarda o processo de login terminar
if wait "$LOGIN_PID" 2>/dev/null; then
    echo ""
    ok "Login concluÃ­do com sucesso! Cookies salvos."
    echo ""
    info "Encerrando VNC e reiniciando serviÃ§o..."
    pkill -9 x11vnc 2>/dev/null || true

    # Fecha porta VNC no firewall
    iptables -D INPUT -p tcp --dport "${VNC_PORT}" -j ACCEPT 2>/dev/null || true
    command -v ufw &>/dev/null \
        && ufw delete allow "${VNC_PORT}/tcp" >/dev/null 2>&1 || true

    systemctl restart skymais
    sleep 3

    if systemctl is-active --quiet skymais; then
        ok "ServiÃ§o skymais reiniciado com novos cookies!"
        echo ""
        IP2=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || echo "$IP")
        echo -e "  Playlist: http://${IP2}:8765/playlist.m3u"
        echo -e "  Status  : http://${IP2}:8765/status"
    else
        aviso "ServiÃ§o nÃ£o iniciou. Verifique: journalctl -u skymais -n 30"
    fi
else
    echo ""
    aviso "Login pode ter falhado ou foi cancelado."
    aviso "Verifique: tail -f /var/log/skymais/app.log"
    pkill -9 x11vnc 2>/dev/null || true
fi
