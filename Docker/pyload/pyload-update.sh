docker rm -f pyload-ng
docker-compose pull
docker-compose up -d
docker image prune -f
