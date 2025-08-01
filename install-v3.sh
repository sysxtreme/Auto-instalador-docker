#!/bin/bash

# Script para instalação do Traefik v3.4.1 no Docker Swarm com suporte a Let's Encrypt e Portainer

# Opções de depuração
# set -e  # Interrompe a execução em caso de erro
# set -x  # Mostra cada comando antes de ser executado

# Solicitação de informações do ambiente
read -p "Digite o nome da rede a ser utilizada no Traefik [padrão: traefik_public]: " NETWORK_NAME ; : ${NETWORK_NAME:="traefik_public"}
read -p "Digite hostname completo para acesso ao Portainer, nome e dominio [padrão: portainer.my.lan]: " PORTAINER_HOSTNAME ; : ${PORTAINER_HOSTNAME:="portainer.my.lan"}
read -p "Digite hostname completo para acesso ao Traefik Dashboard, nome e dominio [padrão: dashboard.my.lan]: " DASHBOARD_HOSTNAME ; : ${DASHBOARD_HOSTNAME:="dashboard.my.lan"}
read -p "Digite o nome do usuário para acesso ao Traefik Dashboard [padrão: admin]: " USERNAME ; : ${USERNAME:="admin"}
read -s -p "Digite a senha para o usuário ${USERNAME}: " PASSWORD
echo ""  # Para nova linha após a senha
BASIC_AUTH=$(htpasswd -nb "${USERNAME}" "${PASSWORD}" | sed 's/\$/\$\$/g')
read -p "Digite a quantidade de replicas para o Traefik [padrão: 1]: " TRAEFIK_REPLICAS ; : ${TRAEFIK_REPLICAS:=1}
read -p "Digite o e-mail para uso no Letsencrypt [padrão: user@example.com]: " LETSENCRYPT_EMAIL ; : ${LETSENCRYPT_EMAIL:="user@example.com"}

# Atualizando pacotes e instalando dependências
echo "⚙️ Atualizando pacotes e instalando dependências no sistema..."
sudo apt-get update && sudo apt-get install -y apparmor-utils curl && echo "✅ Pacotes atualizados e dependências instaladas." || { echo "❌ Erro ao atualizar pacotes ou instalar dependências"; exit 1; }

# Verificando se o Docker já está instalado antes de tentar instalar
if ! command -v docker &> /dev/null; then
    echo "⚙️ Instalando Docker..."
    curl -fsSL https://get.docker.com | bash
else
    echo "ℹ️ Docker já está instalado. Pulando esta etapa..."
fi

# Adicionando usuário ao grupo docker
echo "⚙️ Adicionando usuário ao grupo docker..."
sudo usermod -aG docker root
echo "ℹ️ Para aplicar as mudanças de grupo, reinicie a sessão ou execute 'exec su - root'."

# Verificando se o Swarm já está inicializado
if docker info | grep -q "Swarm: active"; then
    echo "ℹ️ Docker Swarm já está ativo. Pulando esta etapa..."
else
    echo "⚙️ Inicializando Docker Swarm..."
    docker swarm init --advertise-addr $(ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}') || { echo "❌ Erro ao inicializar Docker Swarm"; exit 1; }
    echo "✅ Docker Swarm inicializado com sucesso."
fi

# Criando a rede overlay
echo "⚙️ Criando rede overlay..."
docker network create --driver=overlay "${NETWORK_NAME}" || { echo "❌Erro ao criar a rede"; exit 1; }
echo "✅ Rede overlay '${NETWORK_NAME}' criada com sucesso."

# Criando traefik.yaml com todas as configurações corretas
echo "⚙️ Criando arquivo traefik.yaml..."
cat <<EOF > traefik.yaml
version: "3.9"
services:
  traefik:
    image: traefik:v3.4.1
    command:
      # Configure Swarm provider
      - "--providers.swarm.endpoint=unix:///var/run/docker.sock"
      - "--providers.swarm.exposedByDefault=false"
      - "--providers.swarm.network=${NETWORK_NAME}"
      # Enable HTTP and HTTPS entrypoints
      - "--entrypoints.web.address=:80"
      - "--entrypoints.websecure.address=:443"
      # HTTP to HTTPS redirection (optional, kept for other services)
      - "--entrypoints.web.http.redirections.entrypoint.to=websecure"
      - "--entrypoints.web.http.redirections.entrypoint.scheme=https"
      - "--entrypoints.web.http.redirections.entrypoint.permanent=true"
      # Let's Encrypt configuration (staging for testing)
      - "--certificatesresolvers.letsencrypt.acme.httpchallenge=true"
      - "--certificatesresolvers.letsencrypt.acme.httpchallenge.entrypoint=web"
      - "--certificatesresolvers.letsencrypt.acme.email=${LETSENCRYPT_EMAIL}"
      - "--certificatesresolvers.letsencrypt.acme.storage=/etc/traefik/letsencrypt/acme.json"
      - "--certificatesresolvers.letsencrypt.acme.caserver=https://acme-staging-v02.api.letsencrypt.org/directory"
      # Enable API and Dashboard
      - "--api=true"
      - "--api.dashboard=true"
      # Logging configuration
      - "--log.level=DEBUG"
      - "--log.format=json"
      - "--accesslog=true"
    deploy:
      mode: replicated
      replicas: ${TRAEFIK_REPLICAS}
      placement:
        constraints:
          - node.role == manager
      labels:
        # Enable Traefik for this service
        - "traefik.enable=true"
        # Dashboard router for HTTP (port 80)
        - "traefik.http.routers.dashboard-http.rule=Host(\`${DASHBOARD_HOSTNAME}\`)"
        - "traefik.http.routers.dashboard-http.entrypoints=web"
        - "traefik.http.routers.dashboard-http.service=api@internal"
        - "traefik.http.routers.dashboard-http.middlewares=dashboard-auth"
        # Dashboard router for HTTPS (port 443)
        - "traefik.http.routers.dashboard-https.rule=Host(\`${DASHBOARD_HOSTNAME}\`)"
        - "traefik.http.routers.dashboard-https.entrypoints=websecure"
        - "traefik.http.routers.dashboard-https.service=api@internal"
        - "traefik.http.routers.dashboard-https.tls=true"
        - "traefik.http.routers.dashboard-html-https.tls.certresolver=letsencrypt"
        - "traefik.http.routers.dashboard-https.middlewares=dashboard-auth"
        # Basic auth middleware
        - "traefik.http.middlewares.dashboard-auth.basicauth.users=${BASIC_AUTH}"
        # Required dummy-svc label
        - "traefik.http.services.dummy-svc.loadbalancer.server.port=9999"
    volumes:
      - "/var/run/docker.sock:/var/run/docker.sock:ro"
      - "vol_certificates:/etc/traefik/letsencrypt"
    ports:
      - target: 80
        published: 80
        protocol: tcp
        mode: host
      - target: 443
        published: 443
        protocol: tcp
        mode: host
    networks:
      - ${NETWORK_NAME}

volumes:
  vol_shared:
    external: false
    name: volume_swarm_shared
  vol_certificates:
    external: false
    name: volume_swarm_certificates

networks:
  ${NETWORK_NAME}:
    external: true
    name: ${NETWORK_NAME}
EOF
echo "✅ Arquivo traefik.yaml criado com sucesso!"


# Deploy do Traefik
echo "⚙️ Fazendo deploy do Traefik..."
docker stack deploy --prune --resolve-image always -c traefik.yaml traefik || { echo "❌ Erro ao fazer deploy do Traefik"; exit 1; }
echo "✅ Deploy do Traefik concluído!"

echo "⏳ Aguardando 20s para Traefik iniciar completamente..."
sleep 20

# Criando portainer.yaml com todas as configurações corretas
echo "⚙️ Criando arquivo portainer.yaml..."
cat <<EOF > portainer.yaml
version: "3.9"

services:
  agent:
    image: portainer/agent:2.27.6
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - /var/lib/docker/volumes:/var/lib/docker/volumes
    networks:
      - ${NETWORK_NAME}
    deploy:
      mode: global
      placement:
        constraints:
          - node.platform.os == linux

  portainer:
    image: portainer/portainer-ce:2.27.6
    command: -H tcp://tasks.agent:9001 --tlsskipverify
    volumes:
      - portainer_data:/data
    networks:
      - ${NETWORK_NAME}
    deploy:
      mode: replicated
      replicas: 1
      placement:
        constraints:
          - node.role == manager
      labels:
        - "traefik.enable=true"
        - "traefik.docker.network=${NETWORK_NAME}"
        - "traefik.http.routers.portainer.rule=Host(\`${PORTAINER_HOSTNAME}\`)"
        - "traefik.http.routers.portainer.entrypoints=websecure"
        - "traefik.http.routers.portainer.tls.certresolver=letsencrypt"
        - "traefik.http.services.portainer.loadbalancer.server.port=9000"
        - "traefik.http.routers.portainer.service=portainer"
        - "traefik.http.routers.portainer.priority=10"

networks:
  ${NETWORK_NAME}:
    external: true
    attachable: true
    name: ${NETWORK_NAME}

volumes:
  portainer_data:
    external: false
    name: portainer_data
EOF
echo "✅ Arquivo portainer.yaml criado com sucesso!"

# Verificando se o Traefik está rodando antes de iniciar o deploy do Portainer
if docker service ls | grep -q "traefik_traefik"; then
    echo "✅ Traefik está rodando. Continuando com o deploy do Portainer..."
else
    echo "❌ Erro: O Traefik ainda não está rodando! Aguarde e tente novamente."
    exit 1
fi

# Deploy do Portainer
echo "⚙️ Fazendo deploy do Portainer..."
docker stack deploy --prune --resolve-image always -c portainer.yaml portainer || { echo "❌ Erro ao fazer deploy do Portainer"; exit 1; }
echo "✅ Deploy do Portainer concluído!"
echo "⏳ Aguardando 20s para Portainer iniciar completamente..."
sleep 20
echo "⭐ Instalação concluída! Você pode acessar o Portainer e o Traefik Dashboard agora."
echo "🔗 Acesse o Portainer em: https://${PORTAINER_HOSTNAME}"
echo "🔗 Acesse o Traefik Dashboard em: https://${DASHBOARD_HOSTNAME}"
