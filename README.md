# Na VPS, basta rodar:
bash <(curl -s https://raw.githubusercontent.com/jeanfraga95/sky-nv/main/install.sh)


1. No seu PC (não na VPS), acesse https://www.skymais.com.br e faça login normalmente com captcha.

2. Depois de logado, abra o DevTools (F12) → aba Console → execute: copy(document.cookie) Isso copia todos os cookies para o clipboard automaticamente.
3.  Na VPS, edite o arquivo: nano /opt/skymais/cookies.txt Apague as linhas sem # e cole o conteúdo copiado. Salve com Ctrl+O → Ctrl+X.
  
   4.  Aplique: skymais reload-cookies
     
      5. O serviço reinicia e começa a funcionar imediatamente.
     
   6. Quando precisar renovar (o sistema avisa no /status):
  
   7. # Repetir passo 2 no PC, depois na VPS:
nano /opt/skymais/cookies.txt   # cola os novos cookies
skymais reload-cookies           # aplica



Instruções visuais sempre disponíveis em: http://ip-vps:8765/cookies-info

