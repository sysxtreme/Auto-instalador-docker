#!/bin/bash

docker-nuke() {
  local confirmation
  echo "Are you sure you want to remove all Docker containers, images, networks, and volumes? It is very destructive!!! (yes/no): "
  read confirmation
  if [[ "$confirmation" != "yes" ]]; then
    echo "Exiting script. No changes made."
    return
  fi
  echo "Leaving swarm cluster"
  docker swarm leave --force
  echo "Stopping all containers..."
  docker stop $(docker ps -aq) 2>/dev/null
  echo "Removing all containers..."
  docker rm $(docker ps -aq) 2>/dev/null
  echo "Removing unused networks..."
  docker network prune -f 2>/dev/null
  echo "Removing dangling images..."
  docker rmi -f $(docker images --filter dangling=true -qa) 2>/dev/null
  echo "Removing unused volumes..."
  docker volume rm $(docker volume ls --filter dangling=true -q) 2>/dev/null
  echo "Removing all images..."
  docker rmi -f $(docker images -qa) 2>/dev/null
  echo "Docker cleanup completed!"
}

docker-nuke
