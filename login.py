#!/usr/bin/env python3
"""
login.py — Executa login interativo para resolver o captcha manualmente.
Deve ser rodado UMA VEZ (ou quando a sessão expirar).

Uso: python3 /opt/skymais/login.py
"""

import asyncio
import logging
import os
import sys

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    stream=sys.stdout,
)

# Ajusta path para importar módulos do projeto
sys.path.insert(0, "/opt/skymais")
os.environ.setdefault("skyMAIS_DIR", "/opt/skymais")

from auth import do_login_headed

EMAIL = os.environ.get("skyMAIS_EMAIL", "eliezio2000@hotmail.com")
PASSWORD = os.environ.get("skyMAIS_PASSWORD", "R5n9y5y5@$")


async def main():
    print("=" * 60)
    print("  skyMais — Login Interativo")
    print("=" * 60)
    print()
    print("Uma janela do browser será aberta.")
    print("1. O sistema preencherá email e senha automaticamente.")
    print("2. VOCÊ precisa resolver o captcha manualmente.")
    print("3. Após resolver, o browser fechará sozinho.")
    print()

    try:
        cookies = await do_login_headed(EMAIL, PASSWORD)
        print()
        print(f"✅ Login bem-sucedido! {len(cookies)} cookies salvos.")
        print("   Reinicie o serviço: sudo systemctl restart skymais")
    except Exception as e:
        print(f"❌ Erro no login: {e}")
        sys.exit(1)


if __name__ == "__main__":
    asyncio.run(main())
