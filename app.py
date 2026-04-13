"""
app.py — Servidor Flask proxy skyMais
Expõe links fixos por canal que funcionam no VLC (DASH/MPD).
"""

import logging
import os
import signal
import sys
from pathlib import Path

import requests
from flask import Flask, Response, abort, jsonify, redirect, request

from channels import CHANNELS
from stream_manager import StreamManager

# ------------------------------------------------------------------ #
#  Logging                                                             #
# ------------------------------------------------------------------ #
BASE_DIR = Path(os.environ.get("skyMAIS_DIR", "/opt/skymais"))
LOG_FILE = BASE_DIR / "logs" / "app.log"
LOG_FILE.parent.mkdir(parents=True, exist_ok=True)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s — %(message)s",
    handlers=[
        logging.FileHandler(LOG_FILE),
        logging.StreamHandler(sys.stdout),
    ],
)
logger = logging.getLogger(__name__)

# ------------------------------------------------------------------ #
#  Configuração                                                        #
# ------------------------------------------------------------------ #
PORT = int(os.environ.get("skyMAIS_PORT", "8765"))
HOST = os.environ.get("skyMAIS_HOST", "0.0.0.0")

PROXY_HEADERS = {
    "User-Agent": (
        "Mozilla/5.0 (Windows NT 6.1; Win64; x64; rv:109.0) "
        "Gecko/20100101 Firefox/115.0"
    ),
    "Origin": "https://www.skymais.com.br",
    "Referer": "https://www.skymais.com.br/",
    "Accept": "*/*",
}

# ------------------------------------------------------------------ #
#  Flask app                                                           #
# ------------------------------------------------------------------ #
app = Flask(__name__)
stream_manager = StreamManager()


# ------------------------------------------------------------------ #
#  Rotas de stream                                                     #
# ------------------------------------------------------------------ #

@app.route("/live/<slug>")
@app.route("/live/<slug>.mpd")
def live_channel(slug: str):
    """
    Link fixo do canal. Busca o MPD atual e retorna para o VLC.
    O VLC pode usar: http://IP:8765/live/amc
    """
    if slug not in CHANNELS:
        return jsonify({"erro": "Canal não encontrado", "canais_disponíveis": list(CHANNELS.keys())}), 404

    mpd_url = stream_manager.get_url(slug)

    if not mpd_url:
        return (
            jsonify({
                "erro": "URL ainda não disponível. O sistema está inicializando ou renovando o link.",
                "canal": CHANNELS[slug]["name"],
                "dica": "Tente novamente em 30 segundos."
            }),
            503,
        )

    try:
        resp = requests.get(mpd_url, headers=PROXY_HEADERS, timeout=15)

        if resp.status_code == 200:
            # Retorna o MPD diretamente ao VLC
            return Response(
                resp.content,
                status=200,
                content_type=resp.headers.get("content-type", "application/dash+xml"),
                headers={
                    "Cache-Control": "no-cache, no-store, must-revalidate",
                    "X-Channel": CHANNELS[slug]["name"],
                },
            )
        elif resp.status_code in (403, 404):
            # URL expirou — invalida e sinaliza para refresh
            logger.warning(
                f"URL expirada para '{slug}' (HTTP {resp.status_code}). Invalidando..."
            )
            stream_manager.invalidate(slug)
            stream_manager.force_refresh()
            return jsonify({"erro": "Link expirou, renovando... tente novamente em 30s"}), 503
        else:
            logger.error(f"MPD retornou HTTP {resp.status_code} para '{slug}'")
            return jsonify({"erro": f"Erro upstream: {resp.status_code}"}), 502

    except requests.Timeout:
        logger.error(f"Timeout ao buscar MPD de '{slug}'")
        return jsonify({"erro": "Timeout ao buscar stream"}), 504
    except Exception as e:
        logger.error(f"Erro ao buscar MPD de '{slug}': {e}")
        return jsonify({"erro": "Erro interno"}), 500


@app.route("/playlist.m3u")
def playlist():
    """
    Gera uma playlist M3U com todos os canais.
    Útil para carregar todos de uma vez no VLC / Kodi.
    """
    lines = ["#EXTM3U"]
    for slug, info in CHANNELS.items():
        url = request.host_url.rstrip("/") + f"/live/{slug}"
        lines.append(f'#EXTINF:-1 tvg-id="{slug}" tvg-name="{info["name"]}",{info["name"]}')
        lines.append(url)
    content = "\n".join(lines)
    return Response(content, content_type="audio/x-mpegurl; charset=utf-8")


# ------------------------------------------------------------------ #
#  Rotas de gerenciamento                                              #
# ------------------------------------------------------------------ #

@app.route("/status")
def status():
    channels_info = {}
    for slug, info in CHANNELS.items():
        url = stream_manager.get_url(slug)
        channels_info[slug] = {
            "nome": info["name"],
            "disponivel": url is not None,
            "link_fixo": request.host_url.rstrip("/") + f"/live/{slug}",
        }
    return jsonify({
        "status": "online",
        "proximo_refresh_em": stream_manager.next_refresh_str(),
        "canais": channels_info,
        "playlist_m3u": request.host_url.rstrip("/") + "/playlist.m3u",
    })


@app.route("/refresh", methods=["GET", "POST"])
def force_refresh():
    stream_manager.force_refresh()
    return jsonify({"status": "Refresh agendado. Aguarde ~60 segundos."})


@app.route("/")
def index():
    return redirect("/status")


# ------------------------------------------------------------------ #
#  Inicialização                                                       #
# ------------------------------------------------------------------ #

def handle_sigterm(sig, frame):
    logger.info("SIGTERM recebido, encerrando...")
    stream_manager.stop()
    sys.exit(0)


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, handle_sigterm)

    logger.info(f"Iniciando skyMais Proxy na porta {PORT}...")
    stream_manager.start()

    app.run(host=HOST, port=PORT, threaded=True, use_reloader=False)
