docker rm -f openwebrx
docker-compose pull
docker-compose up -d
docker image prune -f
