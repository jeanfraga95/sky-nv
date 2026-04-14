"""
app.py — skyMais Proxy + noVNC embutido na porta 8765
Tudo pela mesma porta: streams, status, login via browser (noVNC).
"""

import logging
import os
import signal
import socket
import sys
import threading
from pathlib import Path

import requests
from flask import Flask, Response, abort, jsonify, redirect, request
from flask_sock import Sock

from channels import CHANNELS
from stream_manager import StreamManager

# ─── Logging ──────────────────────────────────────────────────────────────────
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

# ─── Config ───────────────────────────────────────────────────────────────────
PORT     = int(os.environ.get("skyMAIS_PORT", "8765"))
HOST     = os.environ.get("skyMAIS_HOST", "0.0.0.0")
VNC_PORT = 5901   # x11vnc local (localhost only)

PROXY_HEADERS = {
    "User-Agent": (
        "Mozilla/5.0 (Windows NT 6.1; Win64; x64; rv:109.0) "
        "Gecko/20100101 Firefox/115.0"
    ),
    "Origin": "https://www.skymais.com.br",
    "Referer": "https://www.skymais.com.br/",
    "Accept": "*/*",
}

# ─── Flask ────────────────────────────────────────────────────────────────────
app  = Flask(__name__)
sock = Sock(app)
stream_manager = StreamManager()


# ══════════════════════════════════════════════════════════════════════════════
#  ROTAS DE STREAM
# ══════════════════════════════════════════════════════════════════════════════

@app.route("/live/<slug>")
@app.route("/live/<slug>.mpd")
def live_channel(slug: str):
    if slug not in CHANNELS:
        return jsonify({
            "erro": "Canal não encontrado",
            "canais": list(CHANNELS.keys())
        }), 404

    mpd_url = stream_manager.get_url(slug)

    if not mpd_url:
        msg = (
            "Login necessário. Acesse http://IP:8765/vnc para fazer login."
            if stream_manager.login_needed
            else "Inicializando... tente em 30 segundos."
        )
        return jsonify({"erro": msg, "canal": CHANNELS[slug]["name"]}), 503

    try:
        resp = requests.get(mpd_url, headers=PROXY_HEADERS, timeout=15)
        if resp.status_code == 200:
            return Response(
                resp.content,
                status=200,
                content_type=resp.headers.get("content-type", "application/dash+xml"),
                headers={"Cache-Control": "no-cache, no-store"},
            )
        elif resp.status_code in (403, 404):
            stream_manager.invalidate(slug)
            stream_manager.force_refresh()
            return jsonify({"erro": "Link expirou, renovando... tente em 30s"}), 503
        else:
            return jsonify({"erro": f"Erro upstream: {resp.status_code}"}), 502
    except requests.Timeout:
        return jsonify({"erro": "Timeout ao buscar stream"}), 504
    except Exception as e:
        logger.error(f"Erro ao buscar MPD de '{slug}': {e}")
        return jsonify({"erro": "Erro interno"}), 500


@app.route("/playlist.m3u")
def playlist():
    lines = ["#EXTM3U"]
    for slug, info in CHANNELS.items():
        url = request.host_url.rstrip("/") + f"/live/{slug}"
        lines.append(f'#EXTINF:-1 tvg-id="{slug}" tvg-name="{info["name"]}",{info["name"]}')
        lines.append(url)
    return Response("\n".join(lines), content_type="audio/x-mpegurl; charset=utf-8")


# ══════════════════════════════════════════════════════════════════════════════
#  ROTAS DE GERENCIAMENTO
# ══════════════════════════════════════════════════════════════════════════════

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
    sm = stream_manager.get_status()
    return jsonify({
        "status": "online",
        "login_necessario": sm["login_needed"],
        "ultimo_refresh": sm["last_refresh"],
        "proximo_refresh_em": sm["next_refresh_in"],
        "canais": channels_info,
        "playlist_m3u": request.host_url.rstrip("/") + "/playlist.m3u",
        "login_vnc": request.host_url.rstrip("/") + "/vnc",
    })


@app.route("/refresh", methods=["GET", "POST"])
def force_refresh():
    stream_manager.force_refresh()
    return jsonify({"status": "Refresh agendado."})


@app.route("/")
def index():
    return redirect("/status")


# ══════════════════════════════════════════════════════════════════════════════
#  noVNC EMBUTIDO — acesso ao desktop da VPS pelo browser
#  Tudo pela porta 8765, sem portas extras.
# ══════════════════════════════════════════════════════════════════════════════

@app.route("/vnc")
@app.route("/vnc/")
def vnc_page():
    """Serve a página noVNC inline — sem arquivos externos."""
    host = request.host.split(":")[0]
    port = PORT
    html = f"""<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>skyMais — Login VNC</title>
<style>
  * {{ margin:0; padding:0; box-sizing:border-box; }}
  body {{ background:#1a1a2e; font-family:sans-serif; color:#eee; }}
  #header {{
    background:#16213e; padding:12px 20px; display:flex;
    align-items:center; gap:12px; border-bottom:2px solid #0f3460;
  }}
  #header h1 {{ font-size:1.1rem; color:#e94560; }}
  #header span {{ font-size:.85rem; color:#aaa; }}
  #controls {{
    background:#16213e; padding:10px 20px; display:flex;
    gap:10px; align-items:center; border-bottom:1px solid #0f3460;
  }}
  button {{
    padding:7px 18px; border:none; border-radius:4px; cursor:pointer;
    font-size:.9rem; font-weight:bold;
  }}
  #btn-connect  {{ background:#0f3460; color:#fff; }}
  #btn-connect:hover {{ background:#e94560; }}
  #btn-disconnect {{ background:#555; color:#fff; display:none; }}
  #status-bar {{
    padding:6px 20px; font-size:.8rem;
    background:#0d0d1a; color:#4fc3f7; border-bottom:1px solid #0f3460;
  }}
  #vnc-canvas {{ width:100%; height:calc(100vh - 100px); background:#000; display:block; }}
  canvas {{ display:block; }}
  #msg {{
    position:absolute; top:50%; left:50%; transform:translate(-50%,-50%);
    background:rgba(0,0,0,.8); padding:20px 30px; border-radius:8px;
    text-align:center; font-size:1rem;
  }}
</style>
</head>
<body>
<div id="header">
  <h1>skyMais — Login via Browser</h1>
  <span>Conecte ao desktop da VPS para resolver o captcha</span>
</div>
<div id="controls">
  <button id="btn-connect" onclick="connect()">Conectar</button>
  <button id="btn-disconnect" onclick="disconnect()">Desconectar</button>
  <span style="font-size:.85rem;color:#aaa;">
    Após conectar: resolva o captcha → clique no perfil P1 → pronto
  </span>
</div>
<div id="status-bar">Aguardando conexão...</div>
<div style="position:relative;">
  <canvas id="vnc-canvas"></canvas>
  <div id="msg">Clique em <b>Conectar</b> para ver o desktop da VPS</div>
</div>

<script>
// ── noVNC embutido (versão mínima funcional) ──────────────────────────────
// Usamos a lib noVNC via CDN jsDelivr
const NOVNC_CDN = "https://cdn.jsdelivr.net/npm/@novnc/novnc@1.4.0/core/rfb.js";

let rfb = null;

async function loadRFB() {{
  return new Promise((resolve, reject) => {{
    if (window.RFB) {{ resolve(window.RFB); return; }}
    const s = document.createElement("script");
    s.type = "module";
    s.innerHTML = `
      import RFB from "${{NOVNC_CDN}}";
      window.RFB = RFB;
      document.dispatchEvent(new Event("rfb-ready"));
    `;
    document.head.appendChild(s);
    document.addEventListener("rfb-ready", () => resolve(window.RFB), {{once:true}});
    setTimeout(() => reject(new Error("Timeout carregando noVNC")), 15000);
  }});
}}

function setStatus(msg, color) {{
  const el = document.getElementById("status-bar");
  el.textContent = msg;
  el.style.color = color || "#4fc3f7";
}}

async function connect() {{
  document.getElementById("msg").style.display = "none";
  setStatus("Carregando noVNC...");

  let RFB;
  try {{
    RFB = await loadRFB();
  }} catch(e) {{
    setStatus("Erro ao carregar noVNC: " + e.message, "#e94560");
    document.getElementById("msg").innerHTML =
      "<b style='color:#e94560'>Erro ao carregar noVNC</b><br><small>" + e.message + "</small>";
    document.getElementById("msg").style.display = "block";
    return;
  }}

  const wsUrl = `ws://{host}:{port}/vnc/ws`;
  setStatus("Conectando a " + wsUrl + " ...");

  try {{
    rfb = new RFB(document.getElementById("vnc-canvas"), wsUrl, {{
      credentials: {{ password: "" }},
    }});

    rfb.addEventListener("connect", () => {{
      setStatus("Conectado ao desktop da VPS!", "#66bb6a");
      document.getElementById("btn-connect").style.display = "none";
      document.getElementById("btn-disconnect").style.display = "inline-block";
      rfb.scaleViewport = true;
      rfb.resizeSession = false;
    }});

    rfb.addEventListener("disconnect", (e) => {{
      setStatus("Desconectado: " + (e.detail.reason || "conexão encerrada"), "#ffa726");
      document.getElementById("btn-connect").style.display = "inline-block";
      document.getElementById("btn-disconnect").style.display = "none";
      rfb = null;
    }});

    rfb.addEventListener("credentialsrequired", () => {{
      rfb.sendCredentials({{ password: "" }});
    }});

  }} catch(e) {{
    setStatus("Erro: " + e.message, "#e94560");
  }}
}}

function disconnect() {{
  if (rfb) {{ rfb.disconnect(); rfb = null; }}
}}

// Auto-conecta ao abrir
window.addEventListener("load", () => setTimeout(connect, 500));
</script>
</body>
</html>"""
    return Response(html, content_type="text/html; charset=utf-8")


@sock.route("/vnc/ws")
def vnc_ws_proxy(ws):
    """
    Faz proxy WebSocket ↔ TCP entre o browser (noVNC) e o x11vnc local.
    Tudo pela porta 8765, sem portas extras.
    """
    try:
        vnc_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        vnc_sock.settimeout(5)
        vnc_sock.connect(("127.0.0.1", VNC_PORT))
        vnc_sock.settimeout(None)
    except Exception as e:
        logger.error(f"[VNC WS] Não conseguiu conectar ao x11vnc:{VNC_PORT} — {e}")
        logger.error("Execute 'skymais login' para iniciar o x11vnc.")
        ws.close(message=b"VNC nao disponivel")
        return

    logger.info("[VNC WS] Conexão estabelecida com x11vnc")
    stop = threading.Event()

    def vnc_to_ws():
        try:
            while not stop.is_set():
                data = vnc_sock.recv(65536)
                if not data:
                    break
                ws.send(data)
        except Exception:
            pass
        finally:
            stop.set()

    t = threading.Thread(target=vnc_to_ws, daemon=True)
    t.start()

    try:
        while not stop.is_set():
            data = ws.receive(timeout=30)
            if data is None:
                break
            if isinstance(data, str):
                data = data.encode()
            vnc_sock.sendall(data)
    except Exception:
        pass
    finally:
        stop.set()
        vnc_sock.close()
        logger.info("[VNC WS] Conexão encerrada")


# ══════════════════════════════════════════════════════════════════════════════
#  INICIALIZAÇÃO
# ══════════════════════════════════════════════════════════════════════════════

def handle_sigterm(sig, frame):
    logger.info("SIGTERM recebido, encerrando...")
    stream_manager.stop()
    sys.exit(0)


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, handle_sigterm)
    logger.info(f"Iniciando skyMais Proxy na porta {PORT}...")
    stream_manager.start()
    app.run(host=HOST, port=PORT, threaded=True, use_reloader=False)
