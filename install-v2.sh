#!/bin/bash

set -e  # Interrompe a execução em caso de erro
set -x  # Mostra cada comando antes de ser executado

# Atualizando pacotes e instalando dependências
echo "Atualizando pacotes..."
sudo apt-get update ; apt-get install -y apparmor-utils

# Verificando se o Docker já está instalado antes de tentar instalar
if ! command -v docker &> /dev/null; then
    echo "Instalando Docker..."
    curl -fsSL https://get.docker.com | bash
else
    echo "Docker já está instalado. Pulando esta etapa..."
fi

# Adicionando usuário ao grupo docker
echo "Adicionando usuário ao grupo docker..."
sudo usermod -aG docker root

# Informar ao usuário que ele deve reiniciar a sessão manualmente
echo "Para aplicar as mudanças de grupo, reinicie a sessão ou execute 'exec su - root'."

# Verificando se o Swarm já está inicializado
if docker info | grep -q "Swarm: active"; then
    echo "Docker Swarm já está ativo. Pulando a inicialização..."
else
    echo "Inicializando Docker Swarm..."
    docker swarm init || { echo "Erro ao inicializar Docker Swarm"; exit 1; }
fi

# Solicita o nome da rede ao usuário
read -p "Digite o nome da rede pública: " NETWORK_NAME

# Criando a rede overlay
echo "Criando rede overlay..."
docker network create --driver=overlay "$NETWORK_NAME" || { echo "Erro ao criar a rede"; exit 1; }

# Criando traefik.yaml com todas as configurações corretas
echo "Criando arquivo traefik.yaml..."
cat <<EOF > traefik.yaml
version: "3.7"

services:
  traefik:
    image: traefik:2.11.2
    command:
      - "--api.dashboard=true"
      - "--providers.docker.swarmMode=true"
      - "--providers.docker.endpoint=unix:///var/run/docker.sock"
      - "--providers.docker.exposedbydefault=false"
      - "--providers.docker.network=$NETWORK_NAME"
      - "--entrypoints.web.address=:80"
      - "--entrypoints.web.http.redirections.entryPoint.to=websecure"
      - "--entrypoints.web.http.redirections.entryPoint.scheme=https"
      - "--entrypoints.web.http.redirections.entrypoint.permanent=true"
      - "--entrypoints.websecure.address=:443"
      - "--certificatesresolvers.letsencryptresolver.acme.httpchallenge=true"
      - "--certificatesresolvers.letsencryptresolver.acme.httpchallenge.entrypoint=web"
      - "--certificatesresolvers.letsencryptresolver.acme.email=(EMAIL_DO_USUARIO)"
      - "--certificatesresolvers.letsencryptresolver.acme.storage=/etc/traefik/letsencrypt/acme.json"
      - "--log.level=DEBUG"
      - "--log.format=common"
      - "--log.filePath=/var/log/traefik/traefik.log"
      - "--accesslog=true"
      - "--accesslog.filepath=/var/log/traefik/access-log"
    deploy:
      placement:
        constraints:
          - node.role == manager
      labels:
        - "traefik.enable=true"
        - "traefik.http.middlewares.redirect-https.redirectscheme.scheme=https"
        - "traefik.http.middlewares.redirect-https.redirectscheme.permanent=true"
        - "traefik.http.routers.http-catchall.rule=hostregexp(\`{host:.+}\`)"
        - "traefik.http.routers.http-catchall.entrypoints=web"
        - "traefik.http.routers.http-catchall.middlewares=redirect-https@docker"
        - "traefik.http.routers.http-catchall.priority=1"
    volumes:
      - "/var/run/docker.sock:/var/run/docker.sock:ro"
      - "vol_certificates:/etc/traefik/letsencrypt"
    ports:
      - target: 80
        published: 80
        mode: host
      - target: 443
        published: 443
        mode: host
    networks:
      - "$NETWORK_NAME"

volumes:
  vol_shared:
    external: false
    name: volume_swarm_shared
  vol_certificates:
    external: false
    name: volume_swarm_certificates

networks:
  $NETWORK_NAME:
    external: true
    name: $NETWORK_NAME
EOF

# Solicita o e-mail do usuário para certificados SSL
read -p "Digite seu e-mail para SSL (Let's Encrypt): " USER_EMAIL
sed -i "s|(EMAIL_DO_USUARIO)|$USER_EMAIL|g" traefik.yaml

# Deploy do Traefik
echo "Fazendo deploy do Traefik..."
docker stack deploy --prune --resolve-image always -c traefik.yaml traefik || { echo "Erro ao fazer deploy do Traefik"; exit 1; }

echo "Aguardando Traefik iniciar completamente..."
sleep 20

# Criando portainer.yaml com todas as configurações corretas
echo "Criando arquivo portainer.yaml..."
cat <<EOF > portainer.yaml
version: "3.7"

services:
  agent:
    image: portainer/agent:2.20.1
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - /var/lib/docker/volumes:/var/lib/docker/volumes
    networks:
      - $NETWORK_NAME
    deploy:
      mode: global
      placement:
        constraints: [node.platform.os == linux]

  portainer:
    image: portainer/portainer-ce:2.20.1
    command: -H tcp://tasks.agent:9001 --tlsskipverify
    volumes:
      - portainer_data:/data
    networks:
      - $NETWORK_NAME
    deploy:
      mode: replicated
      replicas: 1
      placement:
        constraints: [node.role == manager]
      labels:
        - "traefik.enable=true"
        - "traefik.docker.network=$NETWORK_NAME"
        - "traefik.http.routers.portainer.rule=Host(\`DOMINIO_DO_USUARIO\`)"
        - "traefik.http.routers.portainer.entrypoints=websecure"
        - "traefik.http.routers.portainer.priority=1"
        - "traefik.http.routers.portainer.tls.certresolver=letsencryptresolver"
        - "traefik.http.routers.portainer.service=portainer"
        - "traefik.http.services.portainer.loadbalancer.server.port=9000"

networks:
  $NETWORK_NAME:
    external: true
    attachable: true
    name: $NETWORK_NAME

volumes:
  portainer_data:
    external: false
    name: portainer_data
EOF

# Solicita domínio ao usuário
read -p "Digite seu domínio para acesso ao Portainer: " USER_DOMAIN
sed -i "s|DOMINIO_DO_USUARIO|$USER_DOMAIN|g" portainer.yaml

# Verificando se o Traefik está rodando antes de iniciar o deploy do Portainer
if docker service ls | grep -q "traefik_traefik"; then
    echo "Traefik está rodando. Continuando com o deploy do Portainer..."
else
    echo "Erro: O Traefik ainda não está rodando! Aguarde e tente novamente."
    exit 1
fi

# Deploy do Portainer
echo "Fazendo deploy do Portainer..."
docker stack deploy --prune --resolve-image always -c portainer.yaml portainer || { echo "Erro ao fazer deploy do Portainer"; exit 1; }

echo "✅ Instalação concluída! Aguarde 30 segundos antes de acessar o Portainer."
echo "🔗 Acesse: https://$USER_DOMAIN"
