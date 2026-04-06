curl -fsSL -o /tmp/sky-pro.sh << 'EOF'
#!/bin/bash
# Sky PRO Anti-CAPTCHA - Versão ARM64 Ubuntu 20.04

set -e
echo "=== SKY PRO Anti-CAPTCHA Installer ==="

# Dependências PRO
apt update && apt install -y \
    libxml2-dev libxslt1-dev python3-dev build-essential \
    chromium-browser xvfb libnss3 libatk-bridge2.0-0 \
    libdrm2 libxkbcommon0 libxcomposite1 libxdamage1 \
    libxrandr2 libgbm1 libasound2 fonts-liberation \
    libu2f-udev libvulkan1 libdrm-amdgpu1 libxss1 \
    libxrandr2 libasound2 libpangocairo-1.0-0 libatk1.0-0 \
    libcairo-gobject2 libgtk-3-0 libgdk-pixbuf2.0-0

INSTALL_DIR="/opt/sky-pro"
mkdir -p "$INSTALL_DIR" "{logs,scripts,config}" "$INSTALL_DIR/logs"

cat > "$INSTALL_DIR/config.json" << 'EOF'
{
    "email": "eliezio2000@hotmail.com",
    "password": "R5n9y5y5@%",
    "channels": [
        {"name": "A&E", "id": "CH0100000000110"},
        {"name": "AMC", "id": "CH0100000000082"},
        {"name": "AMC SERIES", "id": "CH0100000000308"},
        {"name": "ANIMAL PLANET", "id": "CH0100000000116"},
        {"name": "AXN", "id": "CH0100000000086"},
        {"name": "BAND NEWS", "id": "CH0100000000089"},
        {"name": "BAND SPORTS", "id": "CH0100000000124"},
        {"name": "BIS", "id": "CH0100000000073"},
        {"name": "BM&F NEWS", "id": "CH0100000000216"}
    ]
}
EOF

cd "$INSTALL_DIR"
python3 -m venv venv
source venv/bin/activate

pip install --upgrade pip
pip install selenium==4.15.2 undetected-chromedriver requests beautifulsoup4 lxml websocket-client

cat > "$INSTALL_DIR/sky_pro.py" << 'EOF'
#!/usr/bin/env python3
import json, time, random, re, requests, base64, os
import undetected_chromedriver as uc
from selenium.webdriver.common.by import By
from selenium.webdriver.support.ui import WebDriverWait
from selenium.webdriver.support import expected_conditions as EC
import logging

class SkyPro:
    def __init__(self):
        self.config = json.load(open('config.json'))
        logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(message)s')
        self.logger = logging.getLogger(__name__)
    
    def human_delay(self, min_sec=1, max_sec=3):
        time.sleep(random.uniform(min_sec, max_sec))
    
    def get_stealth_driver(self):
        options = uc.ChromeOptions()
        options.add_argument('--no-sandbox')
        options.add_argument('--disable-dev-shm-usage')
        options.add_argument('--disable-gpu')
        options.add_argument('--window-size=1920,1080')
        options.add_argument('--disable-blink-features=AutomationControlled')
        options.add_experimental_option("excludeSwitches", ["enable-automation"])
        options.add_experimental_option('useAutomationExtension', False)
        options.add_argument('--user-agent=Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36')
        
        # Plugins e extensões reais
        options.add_argument('--load-extension=/tmp')
        options.add_argument('--disable-extensions-except=/tmp')
        
        driver = uc.Chrome(options=options, version_main=120)
        driver.execute_script("Object.defineProperty(navigator, 'webdriver', {get: () => undefined})")
        driver.execute_script("Object.defineProperty(navigator, 'plugins', {get: () => [1, 2, 3, 4, 5]})")
        driver.execute_script("Object.defineProperty(navigator, 'languages', {get: () => ['pt-BR', 'pt', 'en-US', 'en']})")
        return driver
    
    def solve_captcha_if_present(self, driver):
        try:
            # Detectar CAPTCHA
            captcha_selectors = [
                '[data-recaptcha], iframe[src*="recaptcha"]',
                '.g-recaptcha', '.captcha', '[id*="captcha"]',
                'iframe[src*="captcha"]', 'div[role="checkbox"]'
            ]
            
            for selector in captcha_selectors:
                if driver.find_elements(By.CSS_SELECTOR, selector):
                    self.logger.warning("CAPTCHA detectado - tentando bypass...")
                    
                    # Scroll humano
                    driver.execute_script("window.scrollTo(0, document.body.scrollHeight/2);")
                    self.human_delay(2, 4)
                    
                    # Simular movimento de mouse
                    driver.execute_script("""
                        var ev = new MouseEvent('mousemove', {
                            view: window,
                            bubbles: true,
                            cancelable: true,
                            clientX: 300,
                            clientY: 300
                        });
                        document.dispatchEvent(ev);
                    """)
                    
                    self.human_delay(3, 5)
                    return True
        except:
            pass
        return False
    
    def login(self):
        driver = self.get_stealth_driver()
        try:
            self.logger.info("🚀 Iniciando login STEALTH...")
            
            # URL de login direta
            login_url = "https://sm-sky-ui.vrioservices.com/logins?failureRedirect=https%3A%2F%2Fwww.skymais.com.br%2Facessar&country=BR&cp_convert=dtvgo&response_type=code&redirect_uri=https%3A%2F%2Fsp.tbxnet.com%2Fv2%2Fauth%2Foauth2%2Fassert&state=63342ad3e5e14f75a0ffc5ef0dcffc737f3ba43a8846be3d9f737f66385d1b99a6c0a72147003da2c600c8b587aa974aff0d8c616e00568d6f6c3782f796a454039692f5d116685e3f867a3449ccf8e709809448bfb46ef35754a07402e48bf07e25d953aa462353d99f342eca641d621d4358b504c7581f8b43165e0c2161890e04bd8c320e8514760c9871c96d2f3797896f13a916b8f889cf82e6bea6b64c82e00940febd1f1ec0f3f95d72589e4aa7b2863b57a26124d553f1ac84e9a44b9430711a277b66b4e0dd9c89286372f&client_id=sky_br"
            
            self.human_delay(2, 4)
            driver.get(login_url)
            self.human_delay(3, 5)
            
            # CAPTCHA check
            self.solve_captcha_if_present(driver)
            
            # Email
            email_field = WebDriverWait(driver, 20).until(
                EC.presence_of_element_located((By.CSS_SELECTOR, 'input[placeholder*="e-mail"], input[placeholder*="E-mail"], input[type="email"], input[autocomplete="email"]'))
            )
            email_field.clear()
            for char in self.config['email']:
                email_field.send_keys(char)
                time.sleep(random.uniform(0.05, 0.15))
            
            self.human_delay(1, 2)
            
            # Senha
            password_field = driver.find_element(By.CSS_SELECTOR, 'input[placeholder*="senha"], input[placeholder*="Senha"], input[type="password"]')
            password_field.clear()
            for char in self.config['password']:
                password_field.send_keys(char)
                time.sleep(random.uniform(0.08, 0.2))
            
            self.human_delay(1, 2)
            
            # Botão continuar
            continue_btn = driver.find_element(By.CSS_SELECTOR, 'button.btn-primary, button.btn-block, button[type="submit"], button:contains("Continuar")')
            driver.execute_script("arguments[0].scrollIntoView();", continue_btn)
            self.human_delay(1, 2)
            driver.execute_script("arguments[0].click();", continue_btn)
            
            self.human_delay(5, 8)
            
            # Verificar se login foi bem-sucedido
            current_url = driver.current_url
            if "skymais.com.br/user/profile" in current_url or "skymais.com.br/home" in current_url:
                self.logger.info("✅ Login realizado!")
                
                # Selecionar perfil se necessário
                try:
                    profile = WebDriverWait(driver, 10).until(
                        EC.element_to_be_clickable((By.CSS_SELECTOR, 'div[class*="P1"], div:contains("Perfil1")'))
                    )
                    driver.execute_script("arguments[0].click();", profile)
                    self.human_delay(3, 5)
                except:
                    pass
                
                return driver
            else:
                self.logger.error(f"❌ Login falhou. URL: {current_url}")
                page_source = driver.page_source[:500]
                if "captcha" in page_source.lower() or "recaptcha" in page_source.lower():
                    self.logger.error("🔒 CAPTCHA detectado!")
                return None
                
        except Exception as e:
            self.logger.error(f"Erro login: {e}")
            return None
    
    def capture_channel(self, driver, channel):
        try:
            self.logger.info(f"📺 Capturando {channel['name']}...")
            url = f"https://www.skymais.com.br/player/live/{channel['id']}"
            
            driver.get(url)
            self.human_delay(8, 12)
            
            # Capturar network logs
            logs = driver.get_log('performance')
            mpd_url = None
            
            for log in logs[-20:]:
                msg = log['message']
                if 'manifest.mpd' in msg:
                    match = re.search(r'"(https?://[^"]*manifest\.mpd[^"]*)"', msg)
                    if match:
                        mpd_url = match.group(1)
                        break
            
            # Fallback: procurar no source
            if not mpd_url:
                source = driver.page_source
                matches = re.findall(r'(https?://[^"\s]*manifest\.mpd[^"\s]*)', source)
                if matches:
                    mpd_url = matches[0]
            
            return mpd_url
            
        except Exception as e:
            self.logger.error(f"Erro {channel['name']}: {e}")
            return None
    
    def run(self):
        driver = self.login()
        if not driver:
            return
        
        m3u = "#EXTM3U\n#EXT-X-VERSION:3\n"
        success = 0
        
        for channel in self.config['channels']:
            mpd = self.capture_channel(driver, channel)
            if mpd:
                m3u += f'#EXTINF:-1 tvg-id="{channel["id"]}" tvg-logo="https://sky.com/logo.png" group-title="Sky HD",{channel["name"]} FHD/HD/SD\n'
                m3u += f"{mpd}|Referer:https://www.skymais.com.br/|User-Agent:Mozilla/5.0\n\n"
                success += 1
                self.logger.info(f"✅ {channel['name']}: {mpd[:80]}...")
            else:
                self.logger.error(f"❌ {channel['name']} falhou")
            
            self.human_delay(2, 4)
        
        # Salvar M3U
        with open('channels.m3u', 'w') as f:
            f.write(m3u)
        
        self.logger.info(f"🎉 FINALIZADO! {success}/{len(self.config['channels'])} canais")
        driver.quit()

if __name__ == "__main__":
    SkyPro().run()
EOF

chmod +x "$INSTALL_DIR/sky_pro.py"

cat > "$INSTALL_DIR/status.sh" << 'EOF'
#!/bin/bash
echo "=== SKY PRO Status ==="
if [ -f channels.m3u ]; then
    echo "📺 CANAIS CAPTURADOS:"
    awk '/^#EXTINF/ {print $NF " (" $(NF-3) ")"}' channels.m3u
    echo ""
    echo "🔗 PRIMEIRO LINK:"
    head -15 channels.m3u
else
    echo "❌ Execute: cd /opt/sky-pro && source venv/bin/activate && python sky_pro.py"
fi
echo ""
echo "📋 LOG:"
tail -10 logs/sky.log 2>/dev/null || echo "Sem logs"
EOF
chmod +x "$INSTALL_DIR/status.sh"

ln -sf "$INSTALL_DIR/status.sh" /usr/local/bin/sky-pro
ln -sf "$INSTALL_DIR/sky_pro.py" /usr/local/bin/sky-pro-run

# Executar
cd "$INSTALL_DIR" && source venv/bin/activate && python sky_pro.py

echo "✅ SKY PRO instalado!"
echo "📺 sky-pro          # Status"
echo "🚀 sky-pro-run     # Capturar agora"
EOF

chmod +x /tmp/sky-pro.sh && bash /tmp/sky-pro.sh
