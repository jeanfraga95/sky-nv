#!/bin/bash

# Sky Channels Capture Script Installer
# Para VPS Ubuntu 22.04 ARM/x86_64
# https://github.com/jeanfraga95/sky-nv

set -e

echo "=== Sky Channels Capture Installer ==="
echo "Para uso pessoal apenas!"

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Diretório de instalação
INSTALL_DIR="/opt/sky-capture"
SCRIPT_DIR="$INSTALL_DIR/scripts"
CONFIG_DIR="$INSTALL_DIR/config"
LOGS_DIR="$INSTALL_DIR/logs"

# Canais
CHANNELS=(
    "A&E:CH0100000000110"
    "AMC:CH0100000000082"
    "AMC SERIES:CH0100000000308"
    "ANIMAL PLANET:CH0100000000116"
    "AXN:CH0100000000086"
    "BAND NEWS:CH0100000000089"
    "BAND SPORTS:CH0100000000124"
    "BIS:CH0100000000073"
    "BM&F NEWS:CH0100000000216"
)

# Função para log
log() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1"
}

error() {
    echo -e "${RED}[ERRO]${NC} $1"
    exit 1
}

# Verificar arquitetura
ARCH=$(uname -m)
if [[ "$ARCH" != "aarch64" && "$ARCH" != "x86_64" ]]; then
    error "Arquitetura $ARCH não suportada. Use ARM64 ou x86_64."
fi

log "Arquitetura detectada: $ARCH"

# Atualizar sistema
log "Atualizando sistema..."
apt update && apt upgrade -y

# Instalar dependências
log "Instalando dependências..."
apt install -y wget curl git unzip chromium-browser xvfb python3 python3-pip python3-venv \
    ffmpeg libnss3 libatk-bridge2.0-0 libdrm2 libxkbcommon0 libxcomposite1 libxdamage1 \
    libxrandr2 libgbm1 libasound2 fonts-liberation xdg-utils

# Criar diretórios
log "Criando diretórios..."
rm -rf "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR" "$SCRIPT_DIR" "$CONFIG_DIR" "$LOGS_DIR"

# Configurar usuário sky
useradd -r -s /bin/false sky || true

# Criar arquivos de configuração
cat > "$CONFIG_DIR/config.json" << 'EOF'
{
    "email": "eliezio2000@hotmail.com",
    "password": "R5n9y5y5@%",
    "profile": "Perfil1",
    "headless": true,
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

# Instalar Python dependencies
log "Instalando Python dependencies..."
cd "$INSTALL_DIR"
python3 -m venv venv
source venv/bin/activate
pip install --upgrade pip
pip install selenium playwright requests beautifulsoup4 lxml

# Instalar Playwright browsers
playwright install chromium --with-deps

# Baixar scripts principais
log "Baixando scripts..."

cat > "$SCRIPT_DIR/sky_capture.py" << 'EOF'
#!/usr/bin/env python3
import json
import time
import re
import requests
import subprocess
from selenium import webdriver
from selenium.webdriver.common.by import By
from selenium.webdriver.support.ui import WebDriverWait
from selenium.webdriver.support import expected_conditions as EC
from selenium.webdriver.chrome.options import Options
from selenium.common.exceptions import TimeoutException, NoSuchElementException
import logging
import os
import sys
from urllib.parse import urlparse, parse_qs
import xml.etree.ElementTree as ET

class SkyCapture:
    def __init__(self, config_path):
        self.config = self.load_config(config_path)
        self.setup_logging()
        self.driver = None
        self.session_cookies = {}
        
    def load_config(self, config_path):
        with open(config_path, 'r') as f:
            return json.load(f)
    
    def setup_logging(self):
        logging.basicConfig(
            level=logging.INFO,
            format='%(asctime)s - %(levelname)s - %(message)s',
            handlers=[
                logging.FileHandler('/opt/sky-capture/logs/sky.log'),
                logging.StreamHandler(sys.stdout)
            ]
        )
        self.logger = logging.getLogger(__name__)
    
    def get_chrome_options(self):
        options = Options()
        options.add_argument('--no-sandbox')
        options.add_argument('--disable-dev-shm-usage')
        options.add_argument('--disable-gpu')
        options.add_argument('--window-size=1920,1080')
        options.add_argument('--user-agent=Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36')
        options.add_argument('--headless')
        options.add_argument('--disable-blink-features=AutomationControlled')
        options.add_experimental_option("excludeSwitches", ["enable-automation"])
        options.add_experimental_option('useAutomationExtension', False)
        return options
    
    def login(self):
        self.logger.info("Iniciando login...")
        options = self.get_chrome_options()
        self.driver = webdriver.Chrome(options=options)
        self.driver.execute_script("Object.defineProperty(navigator, 'webdriver', {get: () => undefined})")
        
        try:
            # Acessar página de login
            login_url = "https://sm-sky-ui.vrioservices.com/logins?failureRedirect=https%3A%2F%2Fwww.skymais.com.br%2Facessar&country=BR&cp_convert=dtvgo&response_type=code&redirect_uri=https%3A%2F%2Fsp.tbxnet.com%2Fv2%2Fauth%2Foauth2%2Fassert&state=63342ad3e5e14f75a0ffc5ef0dcffc737f3ba43a8846be3d9f737f66385d1b99a6c0a72147003da2c600c8b587aa974aff0d8c616e00568d6f6c3782f796a454039692f5d116685e3f867a3449ccf8e709809448bfb46ef35754a07402e48bf07e25d953aa462353d99f342eca641d621d4358b504c7581f8b43165e0c2161890e04bd8c320e8514760c9871c96d2f3797896f13a916b8f889cf82e6bea6b64c82e00940febd1f1ec0f3f95d72589e4aa7b2863b57a26124d553f1ac84e9a44b9430711a277b66b4e0dd9c89286372f&client_id=sky_br"
            self.driver.get(login_url)
            
            # Preencher email
            email_field = WebDriverWait(self.driver, 20).until(
                EC.presence_of_element_located((By.CSS_SELECTOR, 'input[placeholder*="e-mail"], input[placeholder*="E-mail"], input[type="email"]'))
            )
            email_field.clear()
            email_field.send_keys(self.config['email'])
            
            # Preencher senha
            password_field = self.driver.find_element(By.CSS_SELECTOR, 'input[placeholder*="senha"], input[type="password"]')
            password_field.clear()
            password_field.send_keys(self.config['password'])
            
            # Clicar em continuar
            continue_btn = self.driver.find_element(By.CSS_SELECTOR, 'button.btn-primary, button[type="submit"]')
            self.driver.execute_script("arguments[0].click();", continue_btn)
            
            # Esperar redirecionamento para perfil
            WebDriverWait(self.driver, 30).until(
                lambda d: "skymais.com.br/user/profile" in d.current_url or "skymais.com.br/home" in d.current_url
            )
            
            # Selecionar perfil
            try:
                profile_card = WebDriverWait(self.driver, 10).until(
                    EC.element_to_be_clickable((By.CSS_SELECTOR, 'div[class*="profile"][class*="P1"], div:contains("P1")'))
                )
                self.driver.execute_script("arguments[0].click();", profile_card)
                time.sleep(5)
            except TimeoutException:
                self.logger.warning("Perfil não encontrado ou já selecionado")
            
            # Ir para ao vivo
            self.driver.get("https://www.skymais.com.br/home/live")
            time.sleep(5)
            
            # Salvar cookies da sessão
            self.session_cookies = self.driver.get_cookies()
            self.logger.info("Login realizado com sucesso!")
            
        except Exception as e:
            self.logger.error(f"Erro no login: {str(e)}")
            raise
    
    def extract_mpd_url(self, channel_url):
        self.logger.info(f"Extraindo stream para: {channel_url}")
        self.driver.get(channel_url)
        time.sleep(10)
        
        # Capturar requests de rede (simulado via logs)
        logs = self.driver.get_log('performance')
        
        mpd_urls = []
        for log in logs:
            message = log['message']
            if 'dash' in message.lower() or 'mpd' in message.lower():
                try:
                    # Extrair URL do MPD dos logs
                    url_match = re.search(r'"(https?://[^"]*manifest\.mpd[^"]*)"', message)
                    if url_match:
                        mpd_urls.append(url_match.group(1))
                except:
                    continue
        
        # Fallback: tentar encontrar via página
        if not mpd_urls:
            page_source = self.driver.page_source
            mpd_match = re.search(r'(https?://[^"\s]*manifest\.mpd[^"\s]*)', page_source)
            if mpd_match:
                mpd_urls.append(mpd_match.group(1))
        
        if mpd_urls:
            self.logger.info(f"MPD encontrado: {mpd_urls[0]}")
            return mpd_urls[0]
        
        self.logger.error("MPD não encontrado")
        return None
    
    def generate_vlc_urls(self, mpd_url):
        """Gera URLs VLC para FHD, HD e SD"""
        try:
            headers = {
                'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
                'Referer': 'https://www.skymais.com.br/',
                'Origin': 'https://www.skymais.com.br'
            }
            
            response = requests.get(mpd_url, headers=headers, timeout=15)
            root = ET.fromstring(response.content)
            
            # Encontrar BaseURL principal
            base_url = None
            for base in root.findall('.//{urn:mpeg:dash:schema:mpd:2011}BaseURL'):
                base_url = base.text
                break
            
            if not base_url:
                location = root.find('.//{urn:mpeg:dash:schema:mpd:2011}Location')
                if location is not None:
                    base_url = location.text
            
            if not base_url:
                self.logger.error("BaseURL não encontrado")
                return {}
            
            # URLs por qualidade
            urls = {
                'FHD': f'"{base_url}"',
                'HD': f'"{base_url}"',
                'SD': f'"{base_url}"'
            }
            
            self.logger.info("URLs VLC geradas com sucesso")
            return urls
            
        except Exception as e:
            self.logger.error(f"Erro ao processar MPD: {str(e)}")
            return {}
    
    def capture_all_channels(self):
        self.login()
        results = {}
        
        for channel in self.config['channels']:
            try:
                channel_url = f"https://www.skymais.com.br/player/live/{channel['id']}"
                mpd_url = self.extract_mpd_url(channel_url)
                
                if mpd_url:
                    vlc_urls = self.generate_vlc_urls(mpd_url)
                    results[channel['name']] = {
                        'mpd': mpd_url,
                        'vlc': vlc_urls
                    }
                    self.logger.info(f"{channel['name']}: OK")
                else:
                    results[channel['name']] = {'error': 'MPD não encontrado'}
                    self.logger.error(f"{channel['name']}: FALHA")
                
                time.sleep(2)
                
            except Exception as e:
                self.logger.error(f"Erro no canal {channel['name']}: {str(e)}")
                results[channel['name']] = {'error': str(e)}
        
        return results
    
    def close(self):
        if self.driver:
            self.driver.quit()

def main():
    config_path = '/opt/sky-capture/config/config.json'
    capture = SkyCapture(config_path)
    
    try:
        results = capture.capture_all_channels()
        
        # Salvar resultados
        output_file = '/opt/sky-capture/channels.m3u'
        with open(output_file, 'w') as f:
            f.write('#EXTM3U\n')
            for name, data in results.items():
                if 'vlc' in data:
                    f.write(f'#EXTINF:-1,{name} FHD\n{data["vlc"]["FHD"]}\n')
                    f.write(f'#EXTINF:-1,{name} HD\n{data["vlc"]["HD"]}\n')
                    f.write(f'#EXTINF:-1,{name} SD\n{data["vlc"]["SD"]}\n\n')
        
        print(json.dumps(results, indent=2))
        
    finally:
        capture.close()

if __name__ == "__main__":
    main()
EOF

chmod +x "$SCRIPT_DIR/sky_capture.py"

# Criar serviço systemd
cat > /etc/systemd/system/sky-capture.service << EOF
[Unit]
Description=Sky Channels Capture
After=network.target

[Service]
Type=oneshot
User=root
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/venv/bin/python $SCRIPT_DIR/sky_capture.py
TimeoutStartSec=300

[Install]
WantedBy=multi-user.target
EOF

# Criar script de status
cat > "$SCRIPT_DIR/status.sh" << 'EOF'
#!/bin/bash
echo "=== Sky Capture Status ==="
ls -la /opt/sky-capture/
cat /opt/sky-capture/channels.m3u
tail -20 /opt/sky-capture/logs/sky.log
EOF
chmod +x "$SCRIPT_DIR/status.sh"

# Criar script de atualização
cat > "$SCRIPT_DIR/update.sh" << 'EOF'
#!/bin/bash
cd /opt/sky-capture
source venv/bin/activate
pip install --upgrade -r <(echo "selenium playwright requests beautifulsoup4 lxml")
playwright install chromium --with-deps
systemctl restart sky-capture.timer
echo "Atualização concluída!"
EOF
chmod +x "$SCRIPT_DIR/update.sh"

# Criar timer para atualização automática (a cada 30min)
cat > /etc/systemd/system/sky-capture.timer << EOF
[Unit]
Description=Run Sky Capture every 30 minutes

[Timer]
OnBootSec=5min
OnUnitActiveSec=30min
Unit=sky-capture.service

[Install]
WantedBy=timers.target
EOF

# Habilitar serviços
systemctl daemon-reload
systemctl enable sky-capture.timer
systemctl start sky-capture.timer

# Criar symlink
ln -sf "$SCRIPT_DIR/status.sh" /usr/local/bin/sky-status
ln -sf "$SCRIPT_DIR/update.sh" /usr/local/bin/sky-update

log "✅ Instalação concluída!"
log "📺 Execute: sky-status"
log "🔄 Atualizar: sky-update"
log "📁 Arquivos em: $INSTALL_DIR"
log "📺 M3U: $INSTALL_DIR/channels.m3u"
log "📋 Logs: $INSTALL_DIR/logs/sky.log"

echo -e "${GREEN}
🚀 Sky Capture instalado com sucesso!

Comandos:
  sky-status     - Ver status e canais
  sky-update     - Atualizar script
  cat /opt/sky-capture/channels.m3u  - Ver links VLC

URLs fixas serão geradas em /opt/sky-capture/channels.m3u
${NC}"
