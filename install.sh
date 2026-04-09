#!/usr/bin/env bash
# sky Mais IPTV Proxy - Instalador v5
# Ubuntu 20.04 / 22.04 | ARM64 | x86_64

set -euo pipefail

VERDE='\033[0;32m'; AMARELO='\033[1;33m'; VERMELHO='\033[0;31m'
AZUL='\033[0;34m'; NEGRITO='\033[1m'; RESET='\033[0m'
ok()    { echo -e "${VERDE}  v ${*}${RESET}"; }
info()  { echo -e "${AZUL}  > ${*}${RESET}"; }
aviso() { echo -e "${AMARELO}  ! ${*}${RESET}"; }
erro()  { echo -e "${VERMELHO}  X ${*}${RESET}"; exit 1; }
titulo(){ echo -e "\n${NEGRITO}${AZUL}=== ${*} ===${RESET}"; }

INSTALL_DIR="/opt/sky_proxy"
SERVICE_NAME="sky_proxy"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
LOG_FILE="/var/log/sky_proxy.log"
PORTA=8888

echo -e "\n${NEGRITO}${AZUL}=== sky Mais IPTV Proxy ===${RESET}\n"

titulo "Verificacoes"
[[ $EUID -ne 0 ]] && erro "Execute como root: sudo bash install.sh"
ok "Root OK"
ARCH=$(uname -m); ok "Arch: $ARCH"
[[ -f /etc/os-release ]] && { source /etc/os-release; info "SO: $PRETTY_NAME"; }

titulo "Corrigindo repos APT"
rm -f /etc/apt/sources.list.d/php.list \
      /etc/apt/sources.list.d/sury*.list \
      /etc/apt/sources.list.d/*php*.list 2>/dev/null || true
for f in /etc/apt/sources.list.d/*.list; do
    [[ -f "$f" ]] || continue
    grep -qE "packages\.sury\.org|ondrej" "$f" 2>/dev/null && { aviso "Removendo: $f"; rm -f "$f"; } || true
done
sed -i '/packages\.sury\.org/d' /etc/apt/sources.list 2>/dev/null || true
ok "Repos limpos"
info "apt-get update..."
apt-get update -qq 2>&1 | grep -vE "^W:|^N:|^Get:|^Hit:|^Ign:" || true
ok "Pacotes atualizados"

titulo "Limpeza TOTAL de instalacao anterior"

# 1) Para e desabilita o servico
info "Parando servico..."
systemctl stop "$SERVICE_NAME"  2>/dev/null || true
systemctl disable "$SERVICE_NAME" 2>/dev/null || true

# 2) Mata QUALQUER processo usando a porta (inclusive orfaos)
info "Liberando porta ${PORTA}..."
if command -v fuser &>/dev/null; then
    fuser -k "${PORTA}/tcp" 2>/dev/null || true
elif command -v lsof &>/dev/null; then
    lsof -ti tcp:${PORTA} | xargs -r kill -9 2>/dev/null || true
fi
# Garante com ss tambem
SS_PIDS=$(ss -tlnp "sport = :${PORTA}" 2>/dev/null | grep -oP 'pid=\K[0-9]+' || true)
[[ -n "$SS_PIDS" ]] && echo "$SS_PIDS" | xargs -r kill -9 2>/dev/null || true

# 3) Mata qualquer python rodando sky_proxy
info "Matando processos sky_proxy..."
pkill -9 -f "sky_proxy.py" 2>/dev/null || true
pkill -9 -f "${INSTALL_DIR}" 2>/dev/null || true

sleep 2

# 4) Remove arquivos
[[ -f "$SERVICE_FILE" ]] && { rm -f "$SERVICE_FILE"; systemctl daemon-reload; }
[[ -d "$INSTALL_DIR" ]] && { info "Removendo $INSTALL_DIR..."; rm -rf "$INSTALL_DIR"; }

# 5) Confirma que a porta esta livre
if ss -tlnp | grep -q ":${PORTA}"; then
    erro "Porta ${PORTA} ainda ocupada! Execute: fuser -k ${PORTA}/tcp"
fi

ok "Limpeza OK - porta ${PORTA} livre"

titulo "Dependencias do sistema"
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    python3 python3-pip python3-venv curl wget ca-certificates \
    net-tools lsof psmisc \
    xvfb libglib2.0-0 libnss3 libnspr4 libatk1.0-0 libatk-bridge2.0-0 \
    libcups2 libdrm2 libdbus-1-3 libexpat1 libxcb1 libxkbcommon0 libx11-6 \
    libxcomposite1 libxdamage1 libxext6 libxfixes3 libxrandr2 libgbm1 \
    libpango-1.0-0 libcairo2 libasound2 libatspi2.0-0 fonts-liberation \
    libx11-xcb1 libxcursor1 libxi6 libxtst6 lsb-release 2>/dev/null || true
ok "Dependencias OK"

titulo "Ambiente Python"
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"
python3 -m venv venv
source venv/bin/activate
pip install --upgrade pip -q
pip install -q playwright requests
ok "Pacotes Python OK"

info "Instalando Chromium (~2 min)..."
PLAYWRIGHT_BROWSERS_PATH=/root/.cache/ms-playwright playwright install chromium
PLAYWRIGHT_BROWSERS_PATH=/root/.cache/ms-playwright playwright install-deps chromium 2>/dev/null || true
ok "Chromium OK"

titulo "Criando sky_proxy.py"

cat > "${INSTALL_DIR}/sky_proxy.py" << 'ENDOFPYSCRIPT'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
╔══════════════════════════════════════════════════════════╗
║        sky Mais IPTV Proxy - Links Fixos              ║
║  Gera links estáveis para canais ao vivo com DASH        ║
║  Renova tokens automaticamente via Playwright            ║
╚══════════════════════════════════════════════════════════╝
"""

import json
import logging
import os
import re
import sys
import threading
import time
import xml.etree.ElementTree as ET
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse
import urllib.request
import urllib.error
import socket

# ─── Dependências opcionais ──────────────────────────────────────────────────
try:
    from playwright.sync_api import sync_playwright, TimeoutError as PlaywrightTimeout
except ImportError:
    print("ERRO: Playwright não instalado. Execute o install.sh primeiro.")
    sys.exit(1)

# ─── Configuração ────────────────────────────────────────────────────────────

EMAIL    = "eliezio2000@hotmail.com"
PASSWORD = "R5n9y5y5@$"
PORT     = 8888
CACHE_TTL           = 3600   # segundos (1 hora)
TOKEN_REFRESH_AHEAD = 300    # renovar 5 min antes de expirar
MAX_RETRIES         = 3
CACHE_FILE          = "/opt/sky_proxy/cache.json"
LOG_FILE            = "/var/log/sky_proxy.log"

# ─── Canais disponíveis ──────────────────────────────────────────────────────

CHANNELS = {
    "ae": {
        "nome":   "A&E",
        "url":    "https://www.skymais.com.br/player/live/CH0100000000110",
        "grupo":  "Entretenimento",
        "logo":   "https://upload.wikimedia.org/wikipedia/commons/thumb/d/df/A%26E_logo.svg/200px-A%26E_logo.svg.png",
    },
    "amc": {
        "nome":   "AMC",
        "url":    "https://www.skymais.com.br/player/live/CH0100000000082",
        "grupo":  "Entretenimento",
        "logo":   "",
    },
    "amcseries": {
        "nome":   "AMC Series",
        "url":    "https://www.skymais.com.br/player/live/CH0100000000308",
        "grupo":  "Entretenimento",
        "logo":   "",
    },
    "animalplanet": {
        "nome":   "Animal Planet",
        "url":    "https://www.skymais.com.br/player/live/CH0100000000116",
        "grupo":  "Documentários",
        "logo":   "",
    },
    "axn": {
        "nome":   "AXN",
        "url":    "https://www.skymais.com.br/player/live/CH0100000000086",
        "grupo":  "Entretenimento",
        "logo":   "",
    },
    "bandnews": {
        "nome":   "Band News",
        "url":    "https://www.skymais.com.br/player/live/CH0100000000089",
        "grupo":  "Notícias",
        "logo":   "",
    },
    "bandsports": {
        "nome":   "Band Sports",
        "url":    "https://www.skymais.com.br/player/live/CH0100000000124",
        "grupo":  "Esportes",
        "logo":   "",
    },
    "bis": {
        "nome":   "BIS",
        "url":    "https://www.skymais.com.br/player/live/CH0100000000073",
        "grupo":  "Música",
        "logo":   "",
    },
    "bmcnews": {
        "nome":   "BM&C News",
        "url":    "https://www.skymais.com.br/player/live/CH0100000000216",
        "grupo":  "Notícias",
        "logo":   "",
    },
}

# Mapeamento de qualidade → representações DASH por largura de banda
QUALIDADES = {
    "fhd": {"label": "FHD", "bw_min": 2_000_000, "bw_max": 99_999_999},
    "hd":  {"label": "HD",  "bw_min": 800_000,   "bw_max": 1_999_999},
    "sd":  {"label": "SD",  "bw_min": 0,          "bw_max": 799_999},
}

# ─── Logger ──────────────────────────────────────────────────────────────────

os.makedirs(os.path.dirname(LOG_FILE), exist_ok=True)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[
        logging.StreamHandler(sys.stdout),
        logging.FileHandler(LOG_FILE, encoding="utf-8"),
    ],
)
log = logging.getLogger("sky_proxy")

# ─── Cache persistente ───────────────────────────────────────────────────────

class CacheStream:
    """Cache thread-safe com persistência em disco"""

    def __init__(self):
        self._dados: dict = {}
        self._lock = threading.Lock()
        self._carregar()

    # -- persistência --

    def _salvar(self):
        os.makedirs(os.path.dirname(CACHE_FILE), exist_ok=True)
        with open(CACHE_FILE, "w", encoding="utf-8") as f:
            json.dump(self._dados, f, ensure_ascii=False, indent=2)

    def _carregar(self):
        if os.path.exists(CACHE_FILE):
            try:
                with open(CACHE_FILE, encoding="utf-8") as f:
                    self._dados = json.load(f)
                log.info(f"Cache carregado de {CACHE_FILE} ({len(self._dados)} entradas)")
            except Exception as e:
                log.warning(f"Não foi possível carregar cache: {e}")
                self._dados = {}

    # -- interface --

    def get(self, chave: str) -> "Optional[dict]":
        with self._lock:
            entrada = self._dados.get(chave)
            if entrada and time.time() < entrada.get("expira", 0):
                return entrada["dados"]
            return None

    def set(self, chave: str, dados: dict, ttl: int = CACHE_TTL):
        with self._lock:
            self._dados[chave] = {
                "dados":  dados,
                "expira": time.time() + ttl,
            }
            self._salvar()

    def invalidar(self, chave=None):
        with self._lock:
            if chave:
                self._dados.pop(chave, None)
            else:
                self._dados.clear()
            self._salvar()

    def proximos_a_expirar(self, segundos: int = TOKEN_REFRESH_AHEAD):
        agora = time.time()
        with self._lock:
            return [
                k for k, v in self._dados.items()
                if 0 < v.get("expira", 0) - agora <= segundos
            ]


cache = CacheStream()

# ─── Playwright – captura da URL do manifest ─────────────────────────────────

def _fazer_login(page, context):
    """Executa o fluxo de login e seleção de perfil"""
    log.info("  → Abrindo página de login...")
    page.goto(
        "https://www.skymais.com.br/acessar",
        wait_until="domcontentloaded",
        timeout=30_000,
    )

    # Aguarda campo de email (pode já estar na página da Vrio)
    log.info("  → Preenchendo credenciais...")
    page.wait_for_selector('input[type="text"], input[type="email"]', timeout=20_000)
    page.fill('input[type="text"], input[type="email"]', EMAIL)

    # Clica em continuar (habilita campo senha)
    botao_continuar = page.locator('button.btn-primary, button[type="submit"]').first
    botao_continuar.wait_for(state="attached", timeout=10_000)
    botao_continuar.click()

    # Aguarda campo de senha aparecer
    page.wait_for_selector('input[type="password"]', timeout=15_000)
    page.fill('input[type="password"]', PASSWORD)

    # Clica em Entrar
    page.locator('button.btn-primary:not([disabled])').first.click()

    # Aguarda redirecionamento para seleção de perfil
    log.info("  → Aguardando seleção de perfil...")
    page.wait_for_url("**/user/profile**", timeout=30_000)

    # Clica no primeiro perfil disponível ("Perfil1")
    page.wait_for_selector('.dtv-web-user-profile__card-logo', timeout=15_000)
    page.locator('.dtv-web-user-profile__card-logo').first.click()

    # Aguarda redirecionamento para home
    page.wait_for_url("**/home/**", timeout=20_000)
    log.info("  → Login concluído com sucesso!")


def capturar_url_stream(channel_key: str) -> "Optional[dict]":
    """
    Usa Playwright para fazer login e capturar a URL do manifest DASH
    do canal solicitado. Retorna dict com manifest_url e headers.
    """
    canal = CHANNELS[channel_key]
    log.info(f"Capturando stream: {canal['nome']}")

    for tentativa in range(1, MAX_RETRIES + 1):
        try:
            with sync_playwright() as pw:
                browser = pw.chromium.launch(
                    headless=True,
                    args=[
                        "--no-sandbox",
                        "--disable-setuid-sandbox",
                        "--disable-dev-shm-usage",
                        "--disable-gpu",
                        "--disable-extensions",
                        "--no-first-run",
                    ],
                )
                context = browser.new_context(
                    user_agent=(
                        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
                        "AppleWebKit/537.36 (KHTML, like Gecko) "
                        "Chrome/122.0.0.0 Safari/537.36"
                    ),
                    viewport={"width": 1920, "height": 1080},
                    ignore_https_errors=True,
                )

                capturados: list[dict] = []

                def on_request(req):
                    url = req.url
                    if (
                        (".mpd" in url or "manifest.mpd" in url)
                        and ("mediatailor" in url or "amazonaws" in url)
                    ):
                        capturados.append({"url": url, "headers": dict(req.headers)})
                        log.info(f"  → Manifest interceptado: {url[:90]}...")

                page = context.new_page()
                page.on("request", on_request)

                _fazer_login(page, context)

                log.info(f"  → Abrindo player: {canal['url']}")
                page.goto(canal["url"], wait_until="networkidle", timeout=40_000)

                # Espera até 20 s pelo manifest
                deadline = time.time() + 20
                while not capturados and time.time() < deadline:
                    time.sleep(0.5)

                resultado = None
                if capturados:
                    dados = capturados[0]
                    cookies = {c["name"]: c["value"] for c in context.cookies()}
                    resultado = {
                        "manifest_url": dados["url"],
                        "req_headers":  dados["headers"],
                        "cookies":      cookies,
                        "capturado_em": time.time(),
                    }
                    log.info(f"  ✓ Stream capturado para {canal['nome']}")
                else:
                    log.warning(f"  ✗ Manifest não encontrado para {canal['nome']}")

                browser.close()

                if resultado:
                    return resultado

        except PlaywrightTimeout as exc:
            log.error(f"  Timeout (tentativa {tentativa}/{MAX_RETRIES}): {exc}")
        except Exception as exc:
            log.error(f"  Erro (tentativa {tentativa}/{MAX_RETRIES}): {exc}", exc_info=True)

        if tentativa < MAX_RETRIES:
            time.sleep(5 * tentativa)

    return None


# ─── Obtenção e filtragem do MPD ─────────────────────────────────────────────

_NS = {"mpd": "urn:mpeg:dash:schema:mpd:2011", "cenc": "urn:mpeg:cenc:2013"}

def _buscar_mpd(manifest_url: str, req_headers: dict):
    """Faz o download do manifest MPD com os headers originais"""
    headers = {
        "User-Agent":      req_headers.get("user-agent", "Mozilla/5.0"),
        "Origin":          "https://www.skymais.com.br",
        "Referer":         "https://www.skymais.com.br/",
        "Accept":          "*/*",
        "Accept-Encoding": "identity",
    }
    req = urllib.request.Request(manifest_url, headers=headers)
    with urllib.request.urlopen(req, timeout=15) as resp:
        conteudo = resp.read()
        # descomprime gzip se necessário
        enc = resp.headers.get("Content-Encoding", "")
        if enc == "gzip":
            import gzip
            conteudo = gzip.decompress(conteudo)
        return conteudo.decode("utf-8")


def _filtrar_mpd(mpd_str: str, qualidade: str):
    """
    Filtra o MPD para conter apenas a representação de vídeo
    adequada à qualidade solicitada. Áudio e DRM são preservados.
    """
    qual = QUALIDADES.get(qualidade, QUALIDADES["hd"])
    bw_min, bw_max = qual["bw_min"], qual["bw_max"]

    # Registra todos os namespaces encontrados no XML
    namespaces: dict[str, str] = {}
    for _ev, elem in ET.iterparse(sys.stdin.__class__(mpd_str), events=["start-ns"]) if False else []:
        pass  # placeholder – usamos abordagem abaixo

    # Extrai prefixos de namespace do texto para preservá-los
    for match in re.finditer(r'xmlns(?::(\w+))?="([^"]+)"', mpd_str):
        prefixo = match.group(1) or ""
        uri     = match.group(2)
        ET.register_namespace(prefixo, uri)

    try:
        root = ET.fromstring(mpd_str)
    except ET.ParseError as e:
        log.error(f"Erro ao parsear MPD: {e}")
        return mpd_str  # retorna original sem filtro

    ns_mpd = root.tag.split("}")[0].lstrip("{") if "}" in root.tag else ""
    tag = lambda t: f"{{{ns_mpd}}}{t}" if ns_mpd else t

    for period in root.iter(tag("Period")):
        for ad_set in period.findall(tag("AdaptationSet")):
            mime = ad_set.get("mimeType", "")
            content_type = ad_set.get("contentType", "")
            if "video" not in mime and "video" not in content_type:
                continue  # mantém áudio sem alterar

            reps = ad_set.findall(tag("Representation"))
            if not reps:
                continue

            # Ordena por bandwidth descendente
            reps_ordenadas = sorted(reps, key=lambda r: int(r.get("bandwidth", 0)), reverse=True)

            # Seleciona a melhor representação dentro do intervalo de qualidade
            escolhida = None
            for rep in reps_ordenadas:
                bw = int(rep.get("bandwidth", 0))
                if bw_min <= bw <= bw_max:
                    escolhida = rep
                    break

            # Fallback: maior disponível para FHD, menor para SD, meio para HD
            if escolhida is None:
                if qualidade == "fhd":
                    escolhida = reps_ordenadas[0]
                elif qualidade == "sd":
                    escolhida = reps_ordenadas[-1]
                else:
                    escolhida = reps_ordenadas[len(reps_ordenadas) // 2]

            # Remove representações não escolhidas
            for rep in reps:
                if rep is not escolhida:
                    ad_set.remove(rep)

    xml_str = ET.tostring(root, encoding="unicode", xml_declaration=False)
    return '<?xml version="1.0" encoding="UTF-8"?>\n' + xml_str


def _obter_dados_canal(channel_key: str) -> "Optional[dict]":
    """Retorna dados do cache ou captura novos se necessário"""
    dados = cache.get(channel_key)
    if dados:
        return dados

    dados = capturar_url_stream(channel_key)
    if dados:
        cache.set(channel_key, dados)
    return dados


# ─── Servidor HTTP ───────────────────────────────────────────────────────────

class ProxyHandler(BaseHTTPRequestHandler):

    server_version = "skyProxy/1.0"

    def log_message(self, fmt, *args):
        log.debug(f"HTTP {self.address_string()} – {fmt % args}")

    def _resposta(self, codigo: int, content_type: str, corpo):
        if isinstance(corpo, str):
            corpo = corpo.encode("utf-8")
        self.send_response(codigo)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(corpo)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Cache-Control", "no-cache, no-store")
        self.end_headers()
        self.wfile.write(corpo)

    def _erro(self, codigo: int, msg: str):
        self._resposta(codigo, "text/plain; charset=utf-8", msg)

    # ── Roteamento ────────────────────────────────────────────────────────────

    def do_GET(self):
        caminho = self.path.split("?")[0].rstrip("/")

        if caminho in ("", "/", "/playlist.m3u", "/playlist"):
            self._rota_playlist()
            return

        m = re.match(r"^/stream/([a-z0-9]+)(?:/(fhd|hd|sd))?$", caminho)
        if m:
            self._rota_stream(m.group(1), m.group(2) or "fhd")
            return

        if caminho == "/status":
            self._rota_status()
            return

        if caminho == "/refresh":
            self._rota_refresh()
            return

        self._erro(404, "Rota não encontrada.\n\nRotas disponíveis:\n"
                        "  /playlist.m3u\n"
                        "  /stream/{canal}/{qualidade}  (qualidade: fhd | hd | sd)\n"
                        "  /status\n"
                        "  /refresh\n\n"
                        f"Canais: {', '.join(CHANNELS.keys())}\n")

    # ── Rota: playlist M3U ────────────────────────────────────────────────────

    def _rota_playlist(self):
        host = self.headers.get("Host", f"localhost:{PORT}")

        linhas = ["#EXTM3U\n"]
        for key, info in CHANNELS.items():
            for qual_key, qual_info in QUALIDADES.items():
                url = f"http://{host}/stream/{key}/{qual_key}"
                linhas.append(
                    f'#EXTINF:-1 tvg-id="{key}_{qual_key}" '
                    f'tvg-name="{info["nome"]} {qual_info["label"]}" '
                    f'tvg-logo="{info["logo"]}" '
                    f'group-title="{info["grupo"]}",'
                    f'{info["nome"]} {qual_info["label"]}\n'
                    f'{url}\n'
                )

        playlist = "\n".join(linhas)
        self._resposta(
            200,
            "application/x-mpegurl; charset=utf-8",
            playlist,
        )

    # ── Rota: stream (MPD filtrado) ───────────────────────────────────────────

    def _rota_stream(self, channel_key: str, qualidade: str):
        if channel_key not in CHANNELS:
            self._erro(404, f"Canal '{channel_key}' não encontrado.\n"
                            f"Canais válidos: {', '.join(CHANNELS.keys())}")
            return

        dados = _obter_dados_canal(channel_key)
        if not dados:
            self._erro(503,
                f"Falha ao capturar stream de '{CHANNELS[channel_key]['nome']}'.\n"
                "Verifique as credenciais e o log: /var/log/sky_proxy.log\n")
            return

        for tentativa in range(2):
            try:
                mpd_raw     = _buscar_mpd(dados["manifest_url"], dados["req_headers"])
                mpd_filtrado = _filtrar_mpd(mpd_raw, qualidade)
                self._resposta(200, "application/dash+xml", mpd_filtrado)
                return

            except urllib.error.HTTPError as exc:
                if exc.code in (401, 403, 410) and tentativa == 0:
                    # Token expirado → renova
                    log.warning(f"Token expirado ({exc.code}) para {channel_key}. Renovando...")
                    cache.invalidar(channel_key)
                    dados = _obter_dados_canal(channel_key)
                    if not dados:
                        self._erro(503, "Falha ao renovar token.")
                        return
                    continue
                self._erro(502, f"Erro ao buscar manifest: {exc}")
                return

            except Exception as exc:
                log.error(f"Erro ao servir stream: {exc}", exc_info=True)
                self._erro(500, f"Erro interno: {exc}")
                return

    # ── Rota: status JSON ─────────────────────────────────────────────────────

    def _rota_status(self):
        host = self.headers.get("Host", f"localhost:{PORT}")
        status = {
            "status": "online",
            "porta":  PORT,
            "canais_configurados": len(CHANNELS),
            "canais_em_cache": list(cache._dados.keys()),
            "canais": {
                key: {
                    "nome":         info["nome"],
                    "em_cache":     cache.get(key) is not None,
                    "urls": {
                        "fhd": f"http://{host}/stream/{key}/fhd",
                        "hd":  f"http://{host}/stream/{key}/hd",
                        "sd":  f"http://{host}/stream/{key}/sd",
                    },
                }
                for key, info in CHANNELS.items()
            },
            "playlist": f"http://{host}/playlist.m3u",
        }
        self._resposta(200, "application/json; charset=utf-8",
                       json.dumps(status, ensure_ascii=False, indent=2))

    # ── Rota: forçar renovação de todos os tokens ─────────────────────────────

    def _rota_refresh(self):
        cache.invalidar()
        self._resposta(200, "text/plain; charset=utf-8",
                       "Cache limpo. Tokens serão renovados na próxima requisição.\n")


# ─── Thread de renovação automática de tokens ────────────────────────────────

def _thread_renovacao():
    """Renova tokens antes de expirarem em background"""
    time.sleep(60)  # espera inicial
    while True:
        try:
            proximos = cache.proximos_a_expirar(TOKEN_REFRESH_AHEAD + 60)
            for key in proximos:
                if key in CHANNELS:
                    log.info(f"Renovação preventiva: {CHANNELS[key]['nome']}")
                    dados = capturar_url_stream(key)
                    if dados:
                        cache.set(key, dados)
        except Exception as exc:
            log.error(f"Erro na thread de renovação: {exc}")
        time.sleep(60)


# ─── Thread de pré-aquecimento ───────────────────────────────────────────────

def _thread_preaquecimento():
    """Captura streams de todos os canais ao iniciar (opcional)"""
    log.info("Pré-aquecimento do cache iniciado...")
    for key in CHANNELS:
        if not cache.get(key):
            dados = capturar_url_stream(key)
            if dados:
                cache.set(key, dados)
            time.sleep(3)  # respeita o servidor
    log.info("Pré-aquecimento concluído!")


# ─── Ponto de entrada ────────────────────────────────────────────────────────

def _ip_local():
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.connect(("8.8.8.8", 80))
            return s.getsockname()[0]
    except Exception:
        return "SEU_IP"


def main():
    ip = _ip_local()

    log.info("╔══════════════════════════════════════════════╗")
    log.info("║        sky Mais IPTV Proxy                ║")
    log.info("╠══════════════════════════════════════════════╣")
    log.info(f"║  Porta   : {PORT:<35}║")
    log.info(f"║  Canais  : {len(CHANNELS):<35}║")
    log.info("╠══════════════════════════════════════════════╣")
    log.info(f"║  Playlist: http://{ip}:{PORT}/playlist.m3u")
    log.info(f"║  Status  : http://{ip}:{PORT}/status")
    log.info(f"║  Exemplo : http://{ip}:{PORT}/stream/ae/fhd")
    log.info("╚══════════════════════════════════════════════╝")

    # Threads de background
    threading.Thread(target=_thread_renovacao,     daemon=True, name="renovacao").start()
    threading.Thread(target=_thread_preaquecimento, daemon=True, name="preaquecimento").start()

    servidor = HTTPServer(("0.0.0.0", PORT), ProxyHandler)
    log.info(f"Servidor HTTP iniciado na porta {PORT}")

    try:
        servidor.serve_forever()
    except KeyboardInterrupt:
        log.info("Servidor encerrado pelo usuário.")
        servidor.shutdown()


if __name__ == "__main__":
    main()

ENDOFPYSCRIPT

chmod +x "${INSTALL_DIR}/sky_proxy.py"
ok "sky_proxy.py criado"

# Rotaciona log antigo
[[ -f "$LOG_FILE" ]] && mv "$LOG_FILE" "${LOG_FILE}.bak" 2>/dev/null || true
touch "$LOG_FILE"; chmod 666 "$LOG_FILE"

titulo "Servico systemd"

cat > "$SERVICE_FILE" << SVCEOF
[Unit]
Description=sky Mais IPTV Proxy
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
User=root
WorkingDirectory=${INSTALL_DIR}
ExecStart=${INSTALL_DIR}/venv/bin/python3 ${INSTALL_DIR}/sky_proxy.py
Restart=on-failure
RestartSec=10
StandardOutput=append:${LOG_FILE}
StandardError=append:${LOG_FILE}
Environment=PYTHONUNBUFFERED=1
Environment=PLAYWRIGHT_BROWSERS_PATH=/root/.cache/ms-playwright
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable "$SERVICE_NAME"

# Ultima verificacao de porta antes de subir
if ss -tlnp | grep -q ":${PORTA}"; then
    aviso "Porta ainda ocupada, forcando liberacao..."
    fuser -k "${PORTA}/tcp" 2>/dev/null || true
    sleep 2
fi

systemctl start "$SERVICE_NAME"
ok "Servico iniciado"

# Aguarda ate 15s o servico estabilizar
info "Aguardando estabilizacao..."
for i in $(seq 1 15); do
    sleep 1
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        ok "Servico rodando! (${i}s)"
        break
    fi
    [[ $i -eq 15 ]] && aviso "Ainda iniciando (normal na 1a vez - capturando canais)"
done

IP_LOCAL=$(hostname -I | awk '{print $1}')
IP=$(curl -s --max-time 8 https://api.ipify.org 2>/dev/null || echo "$IP_LOCAL")

echo -e "\n${NEGRITO}${VERDE}=== Instalacao concluida! ===${RESET}\n"
echo -e "  Playlist : http://${IP}:${PORTA}/playlist.m3u"
echo -e "  Status   : http://${IP}:${PORTA}/status"
echo -e "  A&E FHD  : http://${IP}:${PORTA}/stream/ae/fhd"
echo -e "  A&E HD   : http://${IP}:${PORTA}/stream/ae/hd"
echo -e "  A&E SD   : http://${IP}:${PORTA}/stream/ae/sd"
echo -e "\n  Canais: ae amc amcseries animalplanet axn bandnews bandsports bis bmcnews"
echo -e "\n  Logs    : sudo tail -f ${LOG_FILE}"
echo -e "  Status  : sudo systemctl status ${SERVICE_NAME}"
echo -e "  Refresh : curl http://localhost:${PORTA}/refresh\n"
aviso "Pre-aquecimento pode levar ate 5 min. Acompanhe: sudo tail -f ${LOG_FILE}"
echo ""
