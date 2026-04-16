"""
auth.py — Autenticação via cookies/headers manuais + captura MPD via Playwright
"""

import asyncio
import json
import logging
import os
import time
from pathlib import Path

from playwright.async_api import async_playwright

logger = logging.getLogger(__name__)

BASE_DIR     = Path(os.environ.get("skyMAIS_DIR", "/opt/skymais"))
COOKIES_FILE = BASE_DIR / "cookies.json"   # cookies convertidos (interno)
COOKIES_TXT  = BASE_DIR / "cookies.txt"    # editado pelo usuário
HEADERS_FILE = BASE_DIR / "headers.json"   # headers extras (Authorization, etc)

USER_AGENT = (
    "Mozilla/5.0 (Windows NT 6.1; Win64; x64; rv:109.0) "
    "Gecko/20100101 Firefox/115.0"
)


# ─── Parse de string de cookies ──────────────────────────────────────────────

def _parse_cookie_string(raw: str) -> list[dict]:
    """
    Converte "key=val; key2=val2" em lista de dicts para o Playwright.
    Tenta múltiplos domínios para garantir que os cookies sejam enviados.
    """
    cookies = []
    for part in raw.split(";"):
        part = part.strip()
        if "=" not in part:
            continue
        name, _, value = part.partition("=")
        name  = name.strip()
        value = value.strip()
        if not name:
            continue
        # Adiciona para os dois domínios relevantes
        for domain in [".skymais.com.br", "www.skymais.com.br"]:
            cookies.append({
                "name":     name,
                "value":    value,
                "domain":   domain,
                "path":     "/",
                "secure":   False,
                "httpOnly": False,
                "sameSite": "Lax",
            })
    return cookies


# ─── Carregar/salvar cookies ─────────────────────────────────────────────────

def load_cookies() -> list[dict]:
    """
    Prioridade:
    1. cookies.txt mais novo que cookies.json → reimporta
    2. cookies.json existente
    """
    txt_mtime  = COOKIES_TXT.stat().st_mtime  if COOKIES_TXT.exists()  else 0
    json_mtime = COOKIES_FILE.stat().st_mtime if COOKIES_FILE.exists() else 0

    if txt_mtime > json_mtime:
        cookies = _import_from_txt()
        if cookies:
            return cookies

    if COOKIES_FILE.exists():
        try:
            with open(COOKIES_FILE) as f:
                return json.load(f)
        except Exception as e:
            logger.error(f"Erro ao ler cookies.json: {e}")
    return []


def save_cookies(cookies: list[dict]) -> None:
    COOKIES_FILE.parent.mkdir(parents=True, exist_ok=True)
    with open(COOKIES_FILE, "w") as f:
        json.dump(cookies, f, indent=2)
    logger.info(f"Cookies salvos: {len(cookies)} entradas")


def _import_from_txt() -> list[dict]:
    if not COOKIES_TXT.exists():
        return []
    try:
        raw_line = ""
        with open(COOKIES_TXT) as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#"):
                    raw_line += line + " "
        raw_line = raw_line.strip()
        if not raw_line:
            return []
        cookies = _parse_cookie_string(raw_line)
        if cookies:
            save_cookies(cookies)
            logger.info(f"cookies.txt importado: {len(cookies)//2} cookies")
        return cookies
    except Exception as e:
        logger.error(f"Erro ao importar cookies.txt: {e}")
        return []


def cookies_valid(cookies: list[dict]) -> bool:
    """
    Retorna True se há cookies suficientes para tentar uma sessão.
    Aceita qualquer conjunto com 10+ cookies únicos (indica sessão ativa).
    """
    if not cookies:
        return False

    # Nomes únicos (sem duplicatas de domínio)
    unique_names = {c.get("name", "") for c in cookies}
    if len(unique_names) < 5:
        return False

    # Aceita se tiver qualquer um desses (sessão Liferay/Vrio/DTV)
    session_patterns = [
        "LFR_SESSION_STATE",   # Liferay session (skyMais usa)
        "access_token",
        "id_token",
        "tbxsid",
        "tbx_session",
        "refresh_token",
        "dtv_session",
        "authorization",
        "JSESSIONID",
        "_dd_s",               # presente no cookie colado
        "gbuuid",              # presente no cookie colado
        "tfpsi",               # presente no cookie colado
    ]
    names_lower = {n.lower() for n in unique_names}
    for pat in session_patterns:
        if pat.lower() in names_lower:
            return True
        # Checa prefixo (ex: LFR_SESSION_STATE_20105)
        for n in names_lower:
            if n.startswith(pat.lower()):
                return True

    # Fallback: se tiver 15+ cookies únicos, provavelmente está logado
    return len(unique_names) >= 15


def get_cookies_status() -> dict:
    cookies = load_cookies()
    txt_exists = COOKIES_TXT.exists()
    txt_mtime  = (
        time.strftime("%d/%m/%Y %H:%M",
                      time.localtime(COOKIES_TXT.stat().st_mtime))
        if txt_exists else "—"
    )
    unique = len({c.get("name") for c in cookies})
    return {
        "cookies_carregados": unique,
        "cookies_validos":    cookies_valid(cookies),
        "ultima_atualizacao": txt_mtime,
        "arquivo":            str(COOKIES_TXT),
    }


# ─── Captura de URL MPD ───────────────────────────────────────────────────────

async def get_stream_url(page_url: str, cookies: list[dict],
                          timeout_s: int = 60) -> str | None:
    """
    Navega até a página do canal com os cookies da sessão e
    intercepta a URL do manifest MPD do MediaTailor/AWS.
    """
    mpd_url = None

    async with async_playwright() as p:
        browser = await p.chromium.launch(
            headless=True,
            args=[
                "--no-sandbox",
                "--disable-setuid-sandbox",
                "--disable-dev-shm-usage",
                "--mute-audio",
                "--disable-blink-features=AutomationControlled",
            ],
        )
        ctx = await browser.new_context(
            user_agent=USER_AGENT,
            extra_http_headers={
                "Origin":           "https://www.skymais.com.br",
                "Referer":          "https://www.skymais.com.br/",
                "Accept-Language":  "pt-BR,pt;q=0.9",
            },
        )

        if cookies:
            try:
                await ctx.add_cookies(cookies)
            except Exception as e:
                logger.warning(f"Erro ao adicionar cookies: {e}")

        page = await ctx.new_page()

        def on_request(req):
            nonlocal mpd_url
            if mpd_url:
                return
            url = req.url
            if ".mpd" in url and (
                "mediatailor" in url or "amazonaws.com" in url
            ):
                logger.info(f"[MPD] {url[:100]}...")
                mpd_url = url
            elif "/v1/manifest/" in url:
                logger.info(f"[MPD manifest] {url[:100]}...")
                mpd_url = url

        page.on("request", on_request)

        try:
            await page.goto(page_url, wait_until="domcontentloaded",
                            timeout=30000)
        except Exception as e:
            logger.warning(f"Goto ({page_url}): {e}")

        deadline = time.time() + timeout_s
        while time.time() < deadline:
            if mpd_url:
                break
            await asyncio.sleep(1)

        await browser.close()

    if not mpd_url:
        logger.warning(f"MPD não encontrado: {page_url}")
    return mpd_url


async def refresh_all_urls(channels: dict, cookies: list[dict]) -> dict:
    results = {}
    for slug, info in channels.items():
        logger.info(f"Capturando {info['name']}...")
        try:
            url = await get_stream_url(info["page_url"], cookies)
            if url:
                results[slug] = url
                logger.info(f"[{info['name']}] OK")
            else:
                logger.warning(f"[{info['name']}] sem MPD")
        except Exception as e:
            logger.error(f"[{info['name']}] {e}")
        await asyncio.sleep(2)
    return results
