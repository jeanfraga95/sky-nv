"""
auth.py — Autenticação via cookies manuais + captura de URL MPD via Playwright
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
COOKIES_TXT  = BASE_DIR / "cookies.txt"    # arquivo editado pelo usuário

USER_AGENT = (
    "Mozilla/5.0 (Windows NT 6.1; Win64; x64; rv:109.0) "
    "Gecko/20100101 Firefox/115.0"
)

# ─── Leitura/escrita de cookies ──────────────────────────────────────────────

def _parse_cookie_string(raw: str) -> list[dict]:
    """
    Converte string "key=val; key2=val2" para lista de dicts do Playwright.
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
        cookies.append({
            "name":   name,
            "value":  value,
            "domain": ".skymais.com.br",
            "path":   "/",
            "secure": True,
            "httpOnly": False,
            "sameSite": "None",
        })
    return cookies


def load_cookies() -> list[dict]:
    """
    Carrega cookies. Prioridade:
    1. cookies.json (já processado anteriormente)
    2. cookies.txt (editado pelo usuário) → converte e salva em cookies.json
    """
    # Verifica se cookies.txt foi atualizado depois do cookies.json
    txt_mtime  = COOKIES_TXT.stat().st_mtime  if COOKIES_TXT.exists()  else 0
    json_mtime = COOKIES_FILE.stat().st_mtime if COOKIES_FILE.exists() else 0

    if txt_mtime > json_mtime:
        # cookies.txt mais novo → reimporta
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
    """
    Lê cookies.txt, extrai a linha de cookies e converte para lista de dicts.
    """
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
            logger.info(f"cookies.txt importado: {len(cookies)} cookies carregados")
        return cookies
    except Exception as e:
        logger.error(f"Erro ao importar cookies.txt: {e}")
        return []


def cookies_valid(cookies: list[dict]) -> bool:
    """
    Verifica se há cookies suficientes para tentar uma sessão.
    Retorna False se a lista for vazia ou só tiver cookies irrelevantes.
    """
    if not cookies:
        return False
    # Precisa ter pelo menos um cookie de sessão
    session_keys = {
        "access_token", "id_token", "tbxsid", "tbx_session",
        "refresh_token", "dtv_session", "authorization"
    }
    names = {c.get("name", "").lower() for c in cookies}
    return bool(names & session_keys)


def get_cookies_status() -> dict:
    """Retorna status dos cookies para exibir no /status."""
    cookies = load_cookies()
    txt_exists  = COOKIES_TXT.exists()
    json_exists = COOKIES_FILE.exists()

    txt_mtime = (
        time.strftime("%d/%m/%Y %H:%M", time.localtime(COOKIES_TXT.stat().st_mtime))
        if txt_exists else "—"
    )

    return {
        "cookies_carregados": len(cookies),
        "cookies_validos":    cookies_valid(cookies),
        "ultima_atualizacao": txt_mtime,
        "arquivo":            str(COOKIES_TXT),
        "instrucoes":         "Edite o arquivo acima e execute: skymais reload-cookies",
    }


# ─── Captura de URL MPD via Playwright ──────────────────────────────────────

async def get_stream_url(page_url: str, cookies: list[dict],
                          timeout_s: int = 45) -> str | None:
    """
    Navega até a página do canal com os cookies da sessão e
    intercepta a URL do manifest MPD do MediaTailor.
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
            ],
        )
        ctx = await browser.new_context(
            user_agent=USER_AGENT,
            extra_http_headers={
                "Origin":  "https://www.skymais.com.br",
                "Referer": "https://www.skymais.com.br/",
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
            if (".mpd" in url and
                    ("mediatailor" in url or "amazonaws.com" in url)):
                logger.info(f"[MPD] {url[:100]}...")
                mpd_url = url
            elif "/v1/manifest/" in url:
                logger.info(f"[MPD manifest] {url[:100]}...")
                mpd_url = url

        page.on("request", on_request)

        try:
            await page.goto(page_url, wait_until="domcontentloaded", timeout=30000)
        except Exception as e:
            logger.warning(f"Goto timeout ({page_url}): {e}")

        deadline = time.time() + timeout_s
        while time.time() < deadline:
            if mpd_url:
                break
            await asyncio.sleep(1)

        await browser.close()

    if not mpd_url:
        logger.warning(f"MPD não encontrado para {page_url}")
    return mpd_url


async def refresh_all_urls(channels: dict, cookies: list[dict]) -> dict:
    """Captura URLs MPD para todos os canais."""
    results = {}
    for slug, info in channels.items():
        logger.info(f"Capturando {info['name']}...")
        try:
            url = await get_stream_url(info["page_url"], cookies)
            if url:
                results[slug] = url
                logger.info(f"[{info['name']}] OK")
            else:
                logger.warning(f"[{info['name']}] sem URL")
        except Exception as e:
            logger.error(f"[{info['name']}] erro: {e}")
        await asyncio.sleep(2)
    return results
