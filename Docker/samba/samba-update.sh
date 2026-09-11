docker rm -f samba
docker-compose pull
docker-compose up -d
docker image prune -f
