"""
stream_manager.py — Gerencia URLs MPD dos canais.
Thread background faz refresh automático periódico.
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
from auth import (
    do_login_headed, refresh_all_urls,
    load_cookies, save_cookies, cookies_valid
)

logger = logging.getLogger(__name__)

BASE_DIR = Path(os.environ.get("skyMAIS_DIR", "/opt/skymais"))
URLS_FILE = BASE_DIR / "stream_urls.json"

EMAIL = os.environ.get("skyMAIS_EMAIL", "eliezio2000@hotmail.com")
PASSWORD = os.environ.get("skyMAIS_PASSWORD", "R5n9y5y5@$")

REFRESH_INTERVAL = 20 * 60   # 20 minutos
RETRY_INTERVAL  = 5  * 60   # 5 minutos em caso de falha


class StreamManager:
    def __init__(self):
        self._lock = threading.RLock()
        self._urls: dict[str, str] = {}          # slug -> mpd_url
        self._last_refresh: float = 0
        self._next_refresh: float = 0
        self._thread: threading.Thread | None = None
        self._stop_event = threading.Event()
        self._needs_login = False

        # Tenta carregar URLs salvas no disco
        self._load_urls_from_disk()

    # ------------------------------------------------------------------ #
    #  API pública                                                         #
    # ------------------------------------------------------------------ #

    def get_url(self, slug: str) -> str | None:
        with self._lock:
            return self._urls.get(slug)

    def invalidate(self, slug: str) -> None:
        with self._lock:
            self._urls.pop(slug, None)

    def force_refresh(self) -> None:
        """Dispara refresh imediato (não bloqueante)."""
        self._next_refresh = 0
        logger.info("Refresh forçado agendado.")

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
        # Primeira execução: refresh imediato
        self._next_refresh = time.time()
        while not self._stop_event.is_set():
            now = time.time()
            if now >= self._next_refresh:
                try:
                    self._do_refresh()
                    self._next_refresh = time.time() + REFRESH_INTERVAL
                except LoginRequired:
                    logger.warning("Login necessário! Tentando autenticação...")
                    try:
                        self._do_login()
                        self._next_refresh = time.time()   # retry imediato
                    except Exception as e:
                        logger.error(f"Falha no login: {e}")
                        self._next_refresh = time.time() + RETRY_INTERVAL
                except Exception as e:
                    logger.error(f"Erro no refresh: {e}")
                    self._next_refresh = time.time() + RETRY_INTERVAL
            time.sleep(5)

    def _do_refresh(self):
        logger.info("Iniciando refresh de URLs de stream...")
        cookies = load_cookies()

        if not cookies_valid(cookies):
            raise LoginRequired("Cookies expirados ou ausentes.")

        loop = asyncio.new_event_loop()
        try:
            new_urls = loop.run_until_complete(
                refresh_all_urls(CHANNELS, cookies)
            )
        finally:
            loop.close()

        if not new_urls:
            raise LoginRequired("Nenhuma URL obtida — provável expiração de sessão.")

        with self._lock:
            self._urls.update(new_urls)
            self._last_refresh = time.time()

        self._save_urls_to_disk()
        logger.info(f"Refresh concluído: {len(new_urls)}/{len(CHANNELS)} canais OK.")

    def _do_login(self):
        """
        Roda o login interativo em modo headed (Xvfb deve estar ativo).
        """
        loop = asyncio.new_event_loop()
        try:
            cookies = loop.run_until_complete(
                do_login_headed(EMAIL, PASSWORD)
            )
            save_cookies(cookies)
        finally:
            loop.close()

    # ------------------------------------------------------------------ #
    #  Persistência de URLs                                                #
    # ------------------------------------------------------------------ #

    def _save_urls_to_disk(self):
        try:
            URLS_FILE.parent.mkdir(parents=True, exist_ok=True)
            data = {
                "updated_at": datetime.now().isoformat(),
                "urls": dict(self._urls),
            }
            with open(URLS_FILE, "w") as f:
                json.dump(data, f, indent=2)
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
            # Só usa URLs salvas se tiverem sido gravadas há menos de 4 horas
            if updated_str:
                age = (datetime.now() - datetime.fromisoformat(updated_str)).total_seconds()
                if age < 4 * 3600:
                    with self._lock:
                        self._urls = saved
                    logger.info(f"URLs carregadas do disco ({len(saved)} canais, {age/60:.0f} min atrás).")
                    return
            logger.info("URLs no disco muito antigas, serão renovadas.")
        except Exception as e:
            logger.error(f"Erro ao carregar URLs: {e}")


class LoginRequired(Exception):
    pass
