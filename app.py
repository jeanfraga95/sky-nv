"""
app.py — skyMais Proxy
"""

import logging
import os
import signal
import sys
from pathlib import Path

import requests
from flask import Flask, Response, jsonify, redirect, request

from auth import load_cookies, get_cookies_status
from channels import CHANNELS
from stream_manager import StreamManager

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

PORT = int(os.environ.get("skyMAIS_PORT", "8765"))
HOST = os.environ.get("skyMAIS_HOST", "0.0.0.0")

PROXY_HEADERS = {
    "User-Agent": (
        "Mozilla/5.0 (Windows NT 6.1; Win64; x64; rv:109.0) "
        "Gecko/20100101 Firefox/115.0"
    ),
    "Origin":  "https://www.skymais.com.br",
    "Referer": "https://www.skymais.com.br/",
    "Accept":  "*/*",
}

app            = Flask(__name__)
stream_manager = StreamManager()


# ─── Stream / IPTV ────────────────────────────────────────────────────────────

@app.route("/live/<slug>")
@app.route("/live/<slug>.mpd")
def live_channel(slug: str):
    if slug not in CHANNELS:
        return jsonify({"erro": "Canal não encontrado",
                        "canais": list(CHANNELS.keys())}), 404

    mpd_url = stream_manager.get_url(slug)
    if not mpd_url:
        return jsonify({
            "erro": (
                "Cookies necessários. Acesse /cookies-info para instruções."
                if stream_manager.login_needed else
                "Inicializando... tente em 30s."
            ),
            "canal": CHANNELS[slug]["name"],
        }), 503

    try:
        resp = requests.get(mpd_url, headers=PROXY_HEADERS, timeout=15)
        if resp.status_code == 200:
            return Response(
                resp.content, status=200,
                content_type=resp.headers.get("content-type",
                                              "application/dash+xml"),
                headers={"Cache-Control": "no-cache, no-store"},
            )
        if resp.status_code in (403, 404):
            stream_manager.invalidate(slug)
            stream_manager.force_refresh()
            return jsonify({"erro": "Link expirou, renovando..."}), 503
        return jsonify({"erro": f"Erro upstream: {resp.status_code}"}), 502
    except requests.Timeout:
        return jsonify({"erro": "Timeout"}), 504
    except Exception as e:
        logger.error(f"MPD '{slug}': {e}")
        return jsonify({"erro": "Erro interno"}), 500


@app.route("/playlist.m3u")
def playlist():
    lines = ["#EXTM3U"]
    for slug, info in CHANNELS.items():
        url = request.host_url.rstrip("/") + f"/live/{slug}"
        lines.append(
            f'#EXTINF:-1 tvg-id="{slug}" tvg-name="{info["name"]}",{info["name"]}'
        )
        lines.append(url)
    return Response("\n".join(lines),
                    content_type="audio/x-mpegurl; charset=utf-8")


@app.route("/status")
def status():
    sm  = stream_manager.get_status()
    ck  = get_cookies_status()
    channels_info = {
        slug: {
            "nome":      info["name"],
            "disponivel": stream_manager.get_url(slug) is not None,
            "link_fixo": request.host_url.rstrip("/") + f"/live/{slug}",
        }
        for slug, info in CHANNELS.items()
    }
    host = request.host_url.rstrip("/")
    return jsonify({
        "status":            "online",
        "cookies_validos":   ck["cookies_validos"],
        "cookies_qtd":       ck["cookies_carregados"],
        "cookies_atualizados_em": ck["ultima_atualizacao"],
        "login_necessario":  sm["login_needed"],
        "ultimo_refresh":    sm["last_refresh"],
        "proximo_refresh_em": sm["next_refresh_in"],
        "canais":            channels_info,
        "playlist_m3u":      host + "/playlist.m3u",
        "como_atualizar_cookies": host + "/cookies-info",
    })


@app.route("/refresh", methods=["GET", "POST"])
def force_refresh():
    stream_manager.force_refresh()
    return jsonify({"status": "Refresh agendado."})


@app.route("/")
def index():
    return redirect("/status")


# ─── Instruções de cookies ────────────────────────────────────────────────────

@app.route("/cookies-info")
def cookies_info():
    ck   = get_cookies_status()
    host = request.host_url.rstrip("/")
    html = f"""<!DOCTYPE html>
<html lang="pt-BR">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>skyMais — Atualizar Cookies</title>
<style>
  body{{font-family:sans-serif;background:#0d1117;color:#c9d1d9;max-width:860px;
       margin:0 auto;padding:24px}}
  h1{{color:#58a6ff;border-bottom:1px solid #30363d;padding-bottom:12px}}
  h2{{color:#79c0ff;margin-top:28px}}
  .card{{background:#161b22;border:1px solid #30363d;border-radius:8px;
         padding:16px;margin:12px 0}}
  .ok  {{color:#3fb950}} .warn{{color:#f0883e}} .bad{{color:#f85149}}
  code{{background:#21262d;padding:2px 6px;border-radius:4px;font-size:.9rem}}
  pre {{background:#21262d;padding:14px;border-radius:8px;overflow-x:auto;
        font-size:.85rem;line-height:1.5}}
  .step{{background:#21262d;border-left:3px solid #58a6ff;padding:10px 14px;
         margin:8px 0;border-radius:0 6px 6px 0}}
  a{{color:#58a6ff}}
  .badge{{display:inline-block;padding:3px 10px;border-radius:12px;
          font-size:.8rem;font-weight:bold}}
  .badge-ok  {{background:#1a3a1a;color:#3fb950;border:1px solid #3fb950}}
  .badge-bad {{background:#3a1a1a;color:#f85149;border:1px solid #f85149}}
</style>
</head>
<body>
<h1>🍪 skyMais — Gerenciar Cookies de Sessão</h1>

<div class="card">
  <strong>Status atual:</strong>
  {"<span class='badge badge-ok'>✔ Cookies válidos</span>" if ck['cookies_validos']
   else "<span class='badge badge-bad'>✘ Cookies ausentes ou inválidos</span>"}
  &nbsp;
  <strong>{ck['cookies_carregados']}</strong> cookies carregados
  &nbsp;|&nbsp;
  Última atualização: <strong>{ck['ultima_atualizacao']}</strong>
</div>

<h2>Como capturar os cookies</h2>

<div class="card">
<p><strong>Método rápido — Console do browser (recomendado):</strong></p>
<div class="step">1. No seu PC, acesse
  <a href="https://www.skymais.com.br" target="_blank">
    https://www.skymais.com.br
  </a> e faça login normalmente</div>
<div class="step">2. Pressione <code>F12</code> para abrir o DevTools</div>
<div class="step">3. Clique na aba <strong>Console</strong></div>
<div class="step">4. Cole o comando abaixo e pressione <strong>Enter</strong>:
<pre>copy(document.cookie)</pre>
O texto será copiado automaticamente para o clipboard.</div>
<div class="step">5. Abra o arquivo de cookies na VPS e cole o conteúdo:<br><br>
<pre>nano /opt/skymais/cookies.txt</pre>
Apague tudo que não é comentário (linhas sem #) e cole o conteúdo copiado.<br>
Salve com <code>Ctrl+O</code> → <code>Enter</code> → <code>Ctrl+X</code></div>
<div class="step">6. Aplique os novos cookies:
<pre>skymais reload-cookies</pre></div>
</div>

<div class="card">
<p><strong>Método alternativo — Aba Rede (Network):</strong></p>
<div class="step">1. Faça login em
  <a href="https://www.skymais.com.br" target="_blank">skymais.com.br</a></div>
<div class="step">2. <code>F12</code> → aba <strong>Rede</strong> (Network)</div>
<div class="step">3. Recarregue a página (<code>F5</code>)</div>
<div class="step">4. Clique em qualquer requisição para <code>skymais.com.br</code></div>
<div class="step">5. Em <strong>Cabeçalhos da solicitação</strong>,
  copie o valor do campo <code>cookie:</code></div>
<div class="step">6. Cole no arquivo e rode <code>skymais reload-cookies</code></div>
</div>

<h2>Quando preciso renovar?</h2>
<div class="card">
  <p>O sistema avisa automaticamente em <a href="{host}/status">/status</a>
  quando os cookies expirarem.</p>
  <p>Normalmente os cookies duram <strong>7 a 30 dias</strong>.</p>
  <p>Sinais de expiração:</p>
  <ul style="margin:8px 0 0 20px;line-height:1.8">
    <li>Links VLC parando de funcionar</li>
    <li><code>"login_necessario": true</code> no /status</li>
    <li>Log mostrando: <code>Aguardando login</code></li>
  </ul>
</div>

<h2>Verificar se funcionou</h2>
<div class="card">
<pre>skymais reload-cookies  # aplica os cookies
skymais status          # vê se está online</pre>
<p>Ou acesse: <a href="{host}/status">{host}/status</a></p>
</div>

<p style="margin-top:24px;color:#6e7681;font-size:.85rem">
  skyMais Proxy — <a href="{host}/playlist.m3u">Playlist M3U</a>
  | <a href="{host}/status">Status JSON</a>
</p>
</body>
</html>"""
    return Response(html, content_type="text/html; charset=utf-8")


# ─── Init ─────────────────────────────────────────────────────────────────────

def handle_sigterm(sig, frame):
    logger.info("SIGTERM — encerrando...")
    stream_manager.stop()
    sys.exit(0)


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, handle_sigterm)
    logger.info(f"Iniciando skyMais Proxy na porta {PORT}...")
    stream_manager.start()
    app.run(host=HOST, port=PORT, threaded=True, use_reloader=False)
