"""
app.py — skyMais Proxy
Interface de controle remoto via screenshot (scrot + xdotool).
Sem noVNC, sem CDN, sem WebSocket. Funciona em qualquer browser.
"""

import io
import logging
import os
import signal
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

import requests
from flask import Flask, Response, jsonify, redirect, request

from channels import CHANNELS
from stream_manager import StreamManager

# ─── Logging ──────────────────────────────────────────────────────────────────
BASE_DIR = Path(os.environ.get("skyMAIS_DIR", "/opt/skymais"))
LOG_FILE  = BASE_DIR / "logs" / "app.log"
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

PORT    = int(os.environ.get("skyMAIS_PORT", "8765"))
HOST    = os.environ.get("skyMAIS_HOST", "0.0.0.0")
DISPLAY = os.environ.get("DISPLAY", ":99")

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

# ══════════════════════════════════════════════════════════════════════════════
#  STREAM / IPTV
# ══════════════════════════════════════════════════════════════════════════════

@app.route("/live/<slug>")
@app.route("/live/<slug>.mpd")
def live_channel(slug: str):
    if slug not in CHANNELS:
        return jsonify({"erro": "Canal não encontrado", "canais": list(CHANNELS.keys())}), 404

    mpd_url = stream_manager.get_url(slug)
    if not mpd_url:
        msg = ("Login necessário. Acesse /vnc para fazer login."
               if stream_manager.login_needed else
               "Inicializando... tente em 30s.")
        return jsonify({"erro": msg, "canal": CHANNELS[slug]["name"]}), 503

    try:
        resp = requests.get(mpd_url, headers=PROXY_HEADERS, timeout=15)
        if resp.status_code == 200:
            return Response(resp.content, status=200,
                            content_type=resp.headers.get("content-type",
                                                          "application/dash+xml"),
                            headers={"Cache-Control": "no-cache, no-store"})
        if resp.status_code in (403, 404):
            stream_manager.invalidate(slug)
            stream_manager.force_refresh()
            return jsonify({"erro": "Link expirou, renovando..."}), 503
        return jsonify({"erro": f"Erro upstream: {resp.status_code}"}), 502
    except requests.Timeout:
        return jsonify({"erro": "Timeout"}), 504
    except Exception as e:
        logger.error(f"MPD error '{slug}': {e}")
        return jsonify({"erro": "Erro interno"}), 500


@app.route("/playlist.m3u")
def playlist():
    lines = ["#EXTM3U"]
    for slug, info in CHANNELS.items():
        url = request.host_url.rstrip("/") + f"/live/{slug}"
        lines.append(f'#EXTINF:-1 tvg-id="{slug}" tvg-name="{info["name"]}",{info["name"]}')
        lines.append(url)
    return Response("\n".join(lines), content_type="audio/x-mpegurl; charset=utf-8")


@app.route("/status")
def status():
    sm = stream_manager.get_status()
    channels_info = {
        slug: {
            "nome": info["name"],
            "disponivel": stream_manager.get_url(slug) is not None,
            "link_fixo": request.host_url.rstrip("/") + f"/live/{slug}",
        }
        for slug, info in CHANNELS.items()
    }
    return jsonify({
        "status": "online",
        "login_necessario": sm["login_needed"],
        "ultimo_refresh": sm["last_refresh"],
        "proximo_refresh_em": sm["next_refresh_in"],
        "canais": channels_info,
        "playlist_m3u": request.host_url.rstrip("/") + "/playlist.m3u",
        "vnc_login": request.host_url.rstrip("/") + "/vnc",
    })


@app.route("/refresh", methods=["GET", "POST"])
def force_refresh():
    stream_manager.force_refresh()
    return jsonify({"status": "Refresh agendado."})


@app.route("/")
def index():
    return redirect("/status")


# ══════════════════════════════════════════════════════════════════════════════
#  INTERFACE REMOTA — screenshot + xdotool (sem noVNC, sem WebSocket)
# ══════════════════════════════════════════════════════════════════════════════

def _run(cmd: list) -> bool:
    """Executa comando e retorna True se OK."""
    env = {**os.environ, "DISPLAY": DISPLAY}
    try:
        subprocess.run(cmd, env=env, capture_output=True, timeout=5)
        return True
    except Exception as e:
        logger.debug(f"cmd {cmd}: {e}")
        return False


def _screenshot_jpeg(quality: int = 70) -> bytes | None:
    """Captura screenshot do Xvfb como JPEG."""
    env = {**os.environ, "DISPLAY": DISPLAY}
    with tempfile.NamedTemporaryFile(suffix=".png", delete=False) as tf:
        path = tf.name
    try:
        # tenta scrot, fallback para import (ImageMagick)
        for cmd in [
            ["scrot", "-q", str(quality), path],
            ["import", "-window", "root", "-quality", str(quality), path],
        ]:
            r = subprocess.run(cmd, env=env, capture_output=True, timeout=5)
            if r.returncode == 0 and os.path.exists(path):
                # converte para JPEG se necessário
                conv = subprocess.run(
                    ["convert", path, "-quality", str(quality), "jpeg:-"],
                    env=env, capture_output=True, timeout=5
                )
                if conv.returncode == 0:
                    return conv.stdout
                # fallback: retorna PNG bruto
                with open(path, "rb") as f:
                    return f.read()
        return None
    finally:
        try:
            os.unlink(path)
        except Exception:
            pass


@app.route("/vnc")
@app.route("/vnc/")
def vnc_page():
    host = request.host
    html = f"""<!DOCTYPE html>
<html lang="pt-BR">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>skyMais — Login Remoto</title>
<style>
  *{{margin:0;padding:0;box-sizing:border-box}}
  body{{background:#111;color:#eee;font-family:sans-serif;user-select:none}}
  #top{{background:#1a1a2e;padding:10px 16px;display:flex;align-items:center;
        gap:12px;border-bottom:2px solid #e94560}}
  #top h1{{font-size:1rem;color:#e94560}}
  #top span{{font-size:.8rem;color:#aaa}}
  #bar{{background:#16213e;padding:8px 16px;font-size:.8rem;color:#4fc3f7;
        display:flex;align-items:center;gap:16px;border-bottom:1px solid #0f3460}}
  #btn-refresh{{padding:4px 12px;background:#0f3460;color:#fff;border:none;
                border-radius:3px;cursor:pointer;font-size:.8rem}}
  #btn-refresh:hover{{background:#e94560}}
  #quality{{padding:3px;background:#111;color:#eee;border:1px solid #333;
            border-radius:3px;font-size:.8rem}}
  #screen-wrap{{position:relative;overflow:auto;background:#000;
                height:calc(100vh - 80px);text-align:center}}
  #screen{{max-width:100%;cursor:crosshair;display:block;margin:auto}}
  #overlay{{position:absolute;top:50%;left:50%;transform:translate(-50%,-50%);
            background:rgba(0,0,0,.75);padding:16px 24px;border-radius:8px;
            font-size:.9rem;text-align:center;pointer-events:none}}
  kbd{{background:#333;padding:2px 6px;border-radius:3px;font-size:.85rem}}
</style>
</head>
<body>
<div id="top">
  <h1>skyMais — Login Remoto</h1>
  <span>Screenshot ao vivo da VPS • Clique na imagem para interagir</span>
</div>
<div id="bar">
  <span id="status-txt">Carregando...</span>
  <button id="btn-refresh" onclick="fetchNow()">↻ Atualizar</button>
  <label>Qualidade:
    <select id="quality" onchange="q=this.value">
      <option value="60">Rápida (60%)</option>
      <option value="80" selected>Normal (80%)</option>
      <option value="95">Alta (95%)</option>
    </select>
  </label>
  <span style="color:#aaa">Auto: <span id="fps">—</span></span>
</div>
<div id="screen-wrap">
  <img id="screen" src="/vnc/screenshot?q=80" alt="carregando...">
  <div id="overlay">Carregando screenshot...</div>
</div>

<script>
let q = "80";
let running = true;
let lastTs = 0;

const img     = document.getElementById("screen");
const overlay = document.getElementById("overlay");
const statusT = document.getElementById("status-txt");
const fpsEl   = document.getElementById("fps");

// ── Screenshot polling ──────────────────────────────────────────────────────
async function fetchNow() {{
  const t0 = Date.now();
  try {{
    const url = `/vnc/screenshot?q=${{q}}&t=${{t0}}`;
    const res = await fetch(url);
    if (!res.ok) throw new Error("HTTP " + res.status);
    const blob = await res.blob();
    const objUrl = URL.createObjectURL(blob);
    img.onload = () => {{ URL.revokeObjectURL(objUrl); }};
    img.src = objUrl;
    overlay.style.display = "none";
    const ms = Date.now() - t0;
    fpsEl.textContent = ms + "ms";
    statusT.textContent = "Ao vivo — " + new Date().toLocaleTimeString();
  }} catch(e) {{
    statusT.textContent = "Erro: " + e.message;
  }}
}}

function loop() {{
  if (!running) return;
  fetchNow().finally(() => setTimeout(loop, 1500));
}}
loop();

// ── Mapeamento de coordenadas ────────────────────────────────────────────────
function imgCoords(e) {{
  const r = img.getBoundingClientRect();
  const sx = img.naturalWidth  / r.width;
  const sy = img.naturalHeight / r.height;
  return {{
    x: Math.round((e.clientX - r.left) * sx),
    y: Math.round((e.clientY - r.top)  * sy),
  }};
}}

// ── Mouse ────────────────────────────────────────────────────────────────────
img.addEventListener("click", async (e) => {{
  const c = imgCoords(e);
  await fetch(`/vnc/click?x=${{c.x}}&y=${{c.y}}&btn=1`);
  setTimeout(fetchNow, 300);
}});

img.addEventListener("contextmenu", async (e) => {{
  e.preventDefault();
  const c = imgCoords(e);
  await fetch(`/vnc/click?x=${{c.x}}&y=${{c.y}}&btn=3`);
  setTimeout(fetchNow, 300);
}});

// ── Teclado ──────────────────────────────────────────────────────────────────
document.addEventListener("keydown", async (e) => {{
  // Não interfere com atalhos do browser (F5, Ctrl+T, etc.)
  if (e.ctrlKey && ["t","w","r","l","n"].includes(e.key.toLowerCase())) return;
  e.preventDefault();
  let key = e.key;
  // Mapeamentos especiais para xdotool
  const map = {{
    " ": "space", "Enter": "Return", "Backspace": "BackSpace",
    "Tab": "Tab", "Escape": "Escape", "Delete": "Delete",
    "ArrowLeft": "Left", "ArrowRight": "Right",
    "ArrowUp": "Up", "ArrowDown": "Down",
    "Home": "Home", "End": "End",
    "PageUp": "Prior", "PageDown": "Next",
  }};
  key = map[key] || (key.length === 1 ? key : null);
  if (!key) return;
  await fetch(`/vnc/key?k=${{encodeURIComponent(key)}}`);
  setTimeout(fetchNow, 200);
}});

// ── Pasta de texto ───────────────────────────────────────────────────────────
document.addEventListener("paste", async (e) => {{
  const txt = e.clipboardData?.getData("text") || "";
  if (!txt) return;
  await fetch("/vnc/type", {{
    method: "POST",
    headers: {{"Content-Type": "application/json"}},
    body: JSON.stringify({{text: txt}}),
  }});
  setTimeout(fetchNow, 400);
}});
</script>
</body>
</html>"""
    return Response(html, content_type="text/html; charset=utf-8")


@app.route("/vnc/screenshot")
def vnc_screenshot():
    """Retorna screenshot JPEG do Xvfb."""
    q = request.args.get("q", "80")
    data = _screenshot_jpeg(int(q))
    if data is None:
        # Retorna imagem preta 1x1 se não conseguiu capturar
        return Response(
            b'\xff\xd8\xff\xe0\x00\x10JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00'
            b'\xff\xdb\x00C\x00\x08\x06\x06\x07\x06\x05\x08\x07\x07\x07\t\t'
            b'\x08\n\x0c\x14\r\x0c\x0b\x0b\x0c\x19\x12\x13\x0f\x14\x1d\x1a'
            b'\x1f\x1e\x1d\x1a\x1c\x1c $.\' ",#\x1c\x1c(7),01444\x1f\'9=82<.342\x1e'
            b'CE 2+#*:B9ZP\x1b\x00\x00\x00\x01\x01\x00\x00\x00\x00\x00\x00\x00'
            b'\xff\xc0\x00\x0b\x08\x00\x01\x00\x01\x01\x01\x11\x00\xff\xc4\x00'
            b'\x1f\x00\x00\x01\x05\x01\x01\x01\x01\x01\x01\x00\x00\x00\x00\x00'
            b'\x00\x00\x00\x01\x02\x03\x04\x05\x06\x07\x08\t\n\x0b\xff\xda\x00'
            b'\x08\x01\x01\x00\x00?\x00\xf5\x00\x00\xff\xd9',
            content_type="image/jpeg",
            headers={"Cache-Control": "no-cache, no-store"}
        )
    return Response(data,
                    content_type="image/jpeg",
                    headers={"Cache-Control": "no-cache, no-store"})


@app.route("/vnc/click")
def vnc_click():
    """Clique do mouse na posição x,y do display virtual."""
    try:
        x   = int(request.args.get("x", 0))
        y   = int(request.args.get("y", 0))
        btn = int(request.args.get("btn", 1))
        _run(["xdotool", "mousemove", "--sync", str(x), str(y)])
        _run(["xdotool", "click", str(btn)])
        return jsonify({"ok": True, "x": x, "y": y})
    except Exception as e:
        return jsonify({"erro": str(e)}), 400


@app.route("/vnc/key")
def vnc_key():
    """Envia tecla para o display virtual."""
    try:
        k = request.args.get("k", "")
        if k:
            _run(["xdotool", "key", k])
        return jsonify({"ok": True, "key": k})
    except Exception as e:
        return jsonify({"erro": str(e)}), 400


@app.route("/vnc/type", methods=["POST"])
def vnc_type():
    """Digita texto no display virtual."""
    try:
        data = request.get_json(force=True)
        text = data.get("text", "")
        if text:
            _run(["xdotool", "type", "--clearmodifiers", "--", text])
        return jsonify({"ok": True})
    except Exception as e:
        return jsonify({"erro": str(e)}), 400


# ══════════════════════════════════════════════════════════════════════════════
#  INIT
# ══════════════════════════════════════════════════════════════════════════════

def handle_sigterm(sig, frame):
    logger.info("SIGTERM — encerrando...")
    stream_manager.stop()
    sys.exit(0)


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, handle_sigterm)
    logger.info(f"Iniciando skyMais Proxy na porta {PORT}...")
    stream_manager.start()
    app.run(host=HOST, port=PORT, threaded=True, use_reloader=False)
