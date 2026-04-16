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


# ─── Stream ───────────────────────────────────────────────────────────────────

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
                "Cookies necessários. Acesse /cookies-info"
                if stream_manager.login_needed else
                "Inicializando... tente em 30s."
            ),
            "canal": CHANNELS[slug]["name"],
        }), 503

    try:
        resp = requests.get(mpd_url, headers=PROXY_HEADERS, timeout=15)
        if resp.status_code == 200:
            return Response(resp.content, status=200,
                            content_type=resp.headers.get(
                                "content-type", "application/dash+xml"),
                            headers={"Cache-Control": "no-cache, no-store"})
        if resp.status_code in (403, 404):
            stream_manager.invalidate(slug)
            stream_manager.force_refresh()
            return jsonify({"erro": "Link expirou, renovando..."}), 503
        return jsonify({"erro": f"Upstream: {resp.status_code}"}), 502
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
    host = request.host_url.rstrip("/")
    channels_info = {
        slug: {
            "nome":      info["name"],
            "disponivel": stream_manager.get_url(slug) is not None,
            "link_fixo": host + f"/live/{slug}",
        }
        for slug, info in CHANNELS.items()
    }
    return jsonify({
        "status":               "online",
        "cookies_validos":      ck["cookies_validos"],
        "cookies_unicos":       ck["cookies_carregados"],
        "cookies_atualizados_em": ck["ultima_atualizacao"],
        "login_necessario":     sm["login_needed"],
        "ultimo_refresh":       sm["last_refresh"],
        "proximo_refresh_em":   sm["next_refresh_in"],
        "canais":               channels_info,
        "playlist_m3u":         host + "/playlist.m3u",
        "como_atualizar_cookies": host + "/cookies-info",
    })


@app.route("/refresh", methods=["GET", "POST"])
def force_refresh():
    stream_manager.force_refresh()
    return jsonify({"status": "Refresh agendado."})


@app.route("/")
def index():
    return redirect("/status")


# ─── Página de instruções de cookies ─────────────────────────────────────────

@app.route("/cookies-info")
def cookies_info():
    ck   = get_cookies_status()
    host = request.host_url.rstrip("/")

    status_badge = (
        "<span class='badge ok'>✔ Válidos ({} cookies)</span>".format(
            ck["cookies_carregados"])
        if ck["cookies_validos"] else
        "<span class='badge bad'>✘ Inválidos ou ausentes — siga as instruções abaixo</span>"
    )

    html = f"""<!DOCTYPE html>
<html lang="pt-BR">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>skyMais — Atualizar Cookies</title>
<style>
  body{{font-family:sans-serif;background:#0d1117;color:#c9d1d9;
       max-width:900px;margin:0 auto;padding:24px 16px}}
  h1{{color:#58a6ff;border-bottom:1px solid #30363d;padding-bottom:12px;font-size:1.4rem}}
  h2{{color:#79c0ff;margin-top:32px;font-size:1.1rem}}
  .card{{background:#161b22;border:1px solid #30363d;border-radius:8px;
         padding:16px;margin:12px 0}}
  .step{{background:#21262d;border-left:3px solid #58a6ff;padding:10px 14px;
         margin:8px 0;border-radius:0 6px 6px 0;line-height:1.7}}
  code{{background:#21262d;padding:2px 6px;border-radius:4px;
        font-size:.9rem;color:#79c0ff}}
  pre{{background:#21262d;padding:14px;border-radius:8px;overflow-x:auto;
       font-size:.85rem;line-height:1.5;color:#c9d1d9}}
  .badge{{display:inline-block;padding:4px 12px;border-radius:12px;
          font-size:.85rem;font-weight:bold}}
  .ok {{background:#1a3a1a;color:#3fb950;border:1px solid #3fb950}}
  .bad{{background:#3a1a1a;color:#f85149;border:1px solid #f85149}}
  img{{max-width:100%;border:1px solid #30363d;border-radius:6px;margin:8px 0}}
  a{{color:#58a6ff}}
  .warn{{background:#2d2008;border:1px solid #9e6a03;border-radius:8px;
         padding:12px;color:#e3b341;margin:12px 0}}
</style>
</head>
<body>
<h1>🍪 skyMais — Gerenciar Cookies de Sessão</h1>

<div class="card">
  <strong>Status atual:</strong> {status_badge}<br>
  <small>Última atualização: <strong>{ck['ultima_atualizacao']}</strong> |
  Arquivo: <code>{ck['arquivo']}</code></small>
</div>

<div class="warn">
  ⚠️ <strong>Importante:</strong> O <code>document.cookie</code> no Console
  <strong>não retorna cookies HttpOnly</strong> (os tokens de autenticação reais).
  Use o método da <strong>Aba Rede</strong> abaixo para capturar TODOS os cookies,
  incluindo os HttpOnly.
</div>

<h2>Método correto — Aba Rede (Network)</h2>

<div class="card">
<div class="step">
  <strong>1.</strong> No seu PC, acesse
  <a href="https://www.skymais.com.br" target="_blank">https://www.skymais.com.br</a>
  e faça login (resolva o captcha, clique no perfil P1)
</div>
<div class="step">
  <strong>2.</strong> Com a página carregada, pressione <code>F12</code>
  para abrir o DevTools
</div>
<div class="step">
  <strong>3.</strong> Clique na aba <strong>Rede</strong> (Network)
</div>
<div class="step">
  <strong>4.</strong> Recarregue a página com <code>F5</code>
</div>
<div class="step">
  <strong>5.</strong> No filtro da aba Rede, digite <code>skymais</code>
  para filtrar as requisições
</div>
<div class="step">
  <strong>6.</strong> Clique em qualquer requisição GET para
  <code>www.skymais.com.br</code> (ex: a requisição do documento HTML)
</div>
<div class="step">
  <strong>7.</strong> No painel lateral, clique em
  <strong>Cabeçalhos</strong> (Headers) → role até
  <strong>Cabeçalhos de solicitação</strong> (Request Headers)
</div>
<div class="step">
  <strong>8.</strong> Encontre o campo <code>cookie:</code> —
  clique com o botão direito sobre o valor → <strong>Copiar valor</strong>
  (ou selecione tudo e Ctrl+C)
</div>
<div class="step">
  <strong>9.</strong> Na VPS, edite o arquivo:
  <pre>nano /opt/skymais/cookies.txt</pre>
  Apague tudo que <strong>não</strong> começa com <code>#</code>
  e cole o conteúdo copiado em uma linha só. Salve com
  <code>Ctrl+O</code> → <code>Enter</code> → <code>Ctrl+X</code>
</div>
<div class="step">
  <strong>10.</strong> Aplique os cookies:
  <pre>skymais reload-cookies</pre>
</div>
</div>

<h2>Como confirmar que funcionou</h2>
<div class="card">
<pre>skymais reload-cookies
# Deve mostrar: Cookies validos: True</pre>
<p>Ou acesse: <a href="{host}/status">{host}/status</a><br>
Verifique: <code>"cookies_validos": true</code></p>
</div>

<h2>Quando renovar os cookies?</h2>
<div class="card">
  <p>Os cookies duram normalmente <strong>7 a 30 dias</strong>.</p>
  <p>Você precisa renovar quando:</p>
  <ul style="margin:8px 0 0 20px;line-height:2">
    <li>Links VLC pararem de funcionar</li>
    <li><code>"cookies_validos": false</code> aparecer no /status</li>
    <li>Log mostrar: <code>Aguardando login</code></li>
  </ul>
  <p style="margin-top:12px">
    Basta repetir os passos acima e rodar <code>skymais reload-cookies</code>
  </p>
</div>

<h2>Verificar logs em tempo real</h2>
<div class="card">
<pre>skymais logs
# ou
tail -f /var/log/skymais/app.log</pre>
</div>

<p style="margin-top:24px;color:#6e7681;font-size:.8rem">
  <a href="{host}/status">Status JSON</a> |
  <a href="{host}/playlist.m3u">Playlist M3U</a>
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
