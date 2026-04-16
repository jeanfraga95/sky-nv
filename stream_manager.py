"""
stream_manager.py — Gerencia URLs MPD dos canais.
Thread background faz refresh periódico SOMENTE se cookies válidos existirem.
NAO tenta fazer login headed automaticamente — isso é feito via:
  skymais login   (abre noVNC no browser para resolver captcha) 
"""

import asyncio
import json
import logging
import os
import threading
import time
from datetime import datetime
from pathlib import Path

from channels import CHANNELS
from auth import refresh_all_urls, load_cookies, cookies_valid

logger = logging.getLogger(__name__)

BASE_DIR = Path(os.environ.get("skyMAIS_DIR", "/opt/skymais"))
URLS_FILE = BASE_DIR / "stream_urls.json"

REFRESH_INTERVAL    = 20 * 60   # refresh normal (20 min)
RETRY_INTERVAL      = 5  * 60   # retry após falha técnica (5 min)
LOGIN_WAIT_INTERVAL = 2  * 60   # espera enquanto sem cookies (2 min)
LOGIN_WARN_EVERY    = 10 * 60   # loga aviso a cada 10 min


class StreamManager:
    def __init__(self):
        self._lock = threading.RLock()
        self._urls: dict = {}
        self._last_refresh: float = 0
        self._next_refresh: float = 0
        self.login_needed: bool = False
        self._last_login_warn: float = 0
        self._thread = None
        self._stop_event = threading.Event()
        self._load_urls_from_disk()

    # ------------------------------------------------------------------ #
    #  API pública                                                         #
    # ------------------------------------------------------------------ #

    def get_url(self, slug: str):
        with self._lock:
            return self._urls.get(slug)

    def get_status(self) -> dict:
        with self._lock:
            return {
                "login_needed": self.login_needed,
                "urls_count": len(self._urls),
                "last_refresh": (
                    datetime.fromtimestamp(self._last_refresh).isoformat()
                    if self._last_refresh else None
                ),
                "next_refresh_in": self.next_refresh_str(),
            }

    def invalidate(self, slug: str) -> None:
        with self._lock:
            self._urls.pop(slug, None)

    def force_refresh(self) -> None:
        self._next_refresh = 0
        logger.info("Refresh forcado agendado.")

    def next_refresh_str(self) -> str:
        remaining = max(0, int(self._next_refresh - time.time()))
        mins, secs = divmod(remaining, 60)
        return f"{mins:02d}:{secs:02d}"

    def start(self) -> None:
        if self._thread and self._thread.is_alive():
            return
        self._stop_event.clear()
        self._thread = threading.Thread(
            target=self._background_loop, daemon=True, name="stream-refresh"
        )
        self._thread.start()
        logger.info("StreamManager iniciado.")

    def stop(self) -> None:
        self._stop_event.set()
        if self._thread:
            self._thread.join(timeout=10)

    # ------------------------------------------------------------------ #
    #  Loop de background                                                  #
    # ------------------------------------------------------------------ #

    def _background_loop(self):
        self._next_refresh = time.time() + 5
        while not self._stop_event.is_set():
            if time.time() >= self._next_refresh:
                self._ciclo()
            time.sleep(5)

    def _ciclo(self):
        cookies = load_cookies()

        if not cookies_valid(cookies):
            # Sem login — avisa e espera, NAO tenta login automatico
            self.login_needed = True
            now = time.time()
            if now - self._last_login_warn >= LOGIN_WARN_EVERY:
                logger.warning(
                    "Aguardando login. Execute: skymais login"
                )
                self._last_login_warn = now
            self._next_refresh = time.time() + LOGIN_WAIT_INTERVAL
            return

        self.login_needed = False
        try:
            self._do_refresh(cookies)
            self._next_refresh = time.time() + REFRESH_INTERVAL
        except Exception as e:
            logger.error(f"Erro no refresh: {e}")
            self._next_refresh = time.time() + RETRY_INTERVAL

    def _do_refresh(self, cookies: list):
        logger.info("Iniciando refresh de URLs...")

        loop = asyncio.new_event_loop()
        try:
            new_urls = loop.run_until_complete(
                refresh_all_urls(CHANNELS, cookies)
            )
        finally:
            loop.close()

        if not new_urls:
            logger.warning(
                "Refresh retornou vazio — cookies podem ter expirado. "
                "Execute: skymais login"
            )
            self.login_needed = True
            self._next_refresh = time.time() + RETRY_INTERVAL
            return

        with self._lock:
            self._urls.update(new_urls)
            self._last_refresh = time.time()

        self._save_urls_to_disk()
        logger.info(f"Refresh OK: {len(new_urls)}/{len(CHANNELS)} canais.")

    # ------------------------------------------------------------------ #
    #  Persistência                                                        #
    # ------------------------------------------------------------------ #

    def _save_urls_to_disk(self):
        try:
            URLS_FILE.parent.mkdir(parents=True, exist_ok=True)
            with open(URLS_FILE, "w") as f:
                json.dump(
                    {"updated_at": datetime.now().isoformat(), "urls": dict(self._urls)},
                    f, indent=2
                )
        except Exception as e:
            logger.error(f"Erro ao salvar URLs: {e}")

    def _load_urls_from_disk(self):
        if not URLS_FILE.exists():
            return
        try:
            with open(URLS_FILE) as f:
                data = json.load(f)
            saved = data.get("urls", {})
            updated_str = data.get("updated_at", "")
            if updated_str:
                age = (datetime.now() - datetime.fromisoformat(updated_str)).total_seconds()
                if age < 4 * 3600:
                    with self._lock:
                        self._urls = saved
                    logger.info(f"URLs do disco: {len(saved)} canais ({age/60:.0f} min atrás).")
                    return
            logger.info("URLs no disco muito antigas, renovando...")
        except Exception as e:
            logger.error(f"Erro ao carregar URLs: {e}")
