"""
auth.py — Autenticação skyMais via Playwright
Faz login, resolve captcha manualmente (headed) e extrai URLs MPD dos canais.
"""

import asyncio
import json
import logging
import os
import time
from pathlib import Path

from playwright.async_api import async_playwright, TimeoutError as PWTimeout

logger = logging.getLogger(__name__)

BASE_DIR = Path(os.environ.get("skyMAIS_DIR", "/opt/skymais"))
COOKIES_FILE = BASE_DIR / "cookies.json"
USER_AGENT = (
    "Mozilla/5.0 (Windows NT 6.1; Win64; x64; rv:109.0) "
    "Gecko/20100101 Firefox/115.0"
)
LOGIN_URL = (
    "https://sm-sky-ui.vrioservices.com/logins"
    "?failureRedirect=https%3A%2F%2Fwww.skymais.com.br%2Facessar"
    "&country=BR&cp_convert=dtvgo&response_type=code"
    "&redirect_uri=https%3A%2F%2Fsp.tbxnet.com%2Fv2%2Fauth%2Foauth2%2Fassert"
    "&client_id=sky_br"
)

# ------------------------------------------------------------------ #
#  Helpers de cookie                                                   #
# ------------------------------------------------------------------ #

def save_cookies(cookies: list) -> None:
    COOKIES_FILE.parent.mkdir(parents=True, exist_ok=True)
    with open(COOKIES_FILE, "w") as f:
        json.dump(cookies, f, indent=2)
    logger.info(f"Cookies salvos em {COOKIES_FILE}")


def load_cookies() -> list:
    if COOKIES_FILE.exists():
        with open(COOKIES_FILE) as f:
            return json.load(f)
    return []


def cookies_valid(cookies: list) -> bool:
    """Verifica se algum cookie de sessão ainda está no prazo."""
    now = time.time()
    session_keys = {"access_token", "id_token", "refresh_token", "tbx_session"}
    for c in cookies:
        if c.get("name", "").lower() in session_keys:
            expires = c.get("expires", -1)
            if expires == -1 or expires > now:
                return True
    # Se não encontrou cookie de sessão específico, assume válido (cookies de sessão
    # sem expires são válidos enquanto o browser estiver aberto — nós os mantemos)
    return len(cookies) > 0


# ------------------------------------------------------------------ #
#  Login interativo (headed)                                           #
# ------------------------------------------------------------------ #

async def do_login_headed(email: str, password: str) -> list:
    """
    Abre browser visível para o usuário resolver o captcha manualmente.
    Requer Xvfb no VPS: DISPLAY=:99 deve estar exportado.
    Retorna lista de cookies após login bem-sucedido.
    """
    logger.info("Iniciando login com browser visível (captcha manual)...")

    async with async_playwright() as p:
        browser = await p.chromium.launch(
            headless=False,
            args=[
                "--no-sandbox",
                "--disable-setuid-sandbox",
                "--disable-dev-shm-usage",
                "--window-size=1280,800",
            ],
        )
        ctx = await browser.new_context(
            user_agent=USER_AGENT,
            viewport={"width": 1280, "height": 800},
        )
        page = await ctx.new_page()

        logger.info(f"Abrindo: {LOGIN_URL}")
        await page.goto(LOGIN_URL, wait_until="domcontentloaded", timeout=30000)

        # Preenche credenciais
        await page.wait_for_selector('input[type="text"]', timeout=15000)
        await page.fill('input[type="text"]', email)
        await page.fill('input[type="password"]', password)
        await page.click("button.btn-primary")

        # Aguarda captcha + redirecionamento (até 5 min para o usuário resolver)
        logger.info("Aguardando usuário resolver o captcha (até 5 min)...")
        try:
            await page.wait_for_url("**/user/profile**", timeout=300_000)
        except PWTimeout:
            await browser.close()
            raise RuntimeError("Timeout aguardando resolução do captcha.")

        logger.info("Login bem-sucedido! Selecionando perfil P1...")

        # Seleciona perfil (primeiro disponível = P1)
        try:
            await page.wait_for_selector(
                ".dtv-web-user-profile__card-logo", timeout=10000
            )
            await page.click(".dtv-web-user-profile__card-logo")
        except PWTimeout:
            logger.warning("Seletor de perfil não encontrado, tentando clique genérico...")
            await page.click(".dtv-common-c-card-profile__logo", timeout=5000)

        try:
            await page.wait_for_url("**/home/main**", timeout=15000)
        except PWTimeout:
            logger.warning("Redirecionamento para /home/main demorou mais que o esperado.")

        cookies = await ctx.cookies()
        await browser.close()

        save_cookies(cookies)
        logger.info(f"{len(cookies)} cookies salvos.")
        return cookies


# ------------------------------------------------------------------ #
#  Extração de URL MPD (headless)                                      #
# ------------------------------------------------------------------ #

async def get_stream_url(page_url: str, cookies: list, timeout_s: int = 45) -> str | None:
    """
    Navega até a página do canal em modo headless com cookies existentes
    e intercepta a URL do manifest MPD gerado pelo MediaTailor.
    Retorna a URL do MPD ou None se não encontrado.
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
                "Origin": "https://www.skymais.com.br",
                "Referer": "https://www.skymais.com.br/",
            },
        )

        if cookies:
            await ctx.add_cookies(cookies)

        page = await ctx.new_page()

        # Intercepta todas as requests procurando pelo manifest
        def on_request(req):
            nonlocal mpd_url
            url = req.url
            if mpd_url:
                return
            # Padrões que indicam o manifest MPD do MediaTailor
            if ".mpd" in url and ("mediatailor" in url or "amazonaws.com" in url):
                logger.info(f"[MPD] Capturado: {url[:120]}...")
                mpd_url = url
            elif "/v1/manifest/" in url:
                logger.info(f"[MPD via manifest path] Capturado: {url[:120]}...")
                mpd_url = url

        page.on("request", on_request)

        logger.info(f"Acessando canal: {page_url}")
        try:
            await page.goto(page_url, wait_until="domcontentloaded", timeout=30000)
        except PWTimeout:
            logger.warning(f"Timeout carregando {page_url}, continuando...")

        # Aguarda até o MPD ser capturado
        deadline = time.time() + timeout_s
        while time.time() < deadline:
            if mpd_url:
                break
            await asyncio.sleep(1)

        await browser.close()

    if not mpd_url:
        logger.warning(f"MPD não encontrado para {page_url} após {timeout_s}s")
    return mpd_url


# ------------------------------------------------------------------ #
#  Função de alto nível usada pelo StreamManager                       #
# ------------------------------------------------------------------ #

async def refresh_all_urls(channels: dict, cookies: list) -> dict:
    """
    Para cada canal, tenta extrair a URL MPD.
    Retorna dict {slug: mpd_url}.
    """
    results = {}
    for slug, info in channels.items():
        logger.info(f"Extraindo URL para {info['name']}...")
        try:
            url = await get_stream_url(info["page_url"], cookies)
            if url:
                results[slug] = url
                logger.info(f"[{info['name']}] OK")
            else:
                logger.warning(f"[{info['name']}] Não foi possível obter URL")
        except Exception as e:
            logger.error(f"[{info['name']}] Erro: {e}")
        # Pequena pausa entre canais para não sobrecarregar
        await asyncio.sleep(3)
    return results
