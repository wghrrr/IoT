docker rm -f homebridge
docker-compose pull
docker-compose up -d
docker image prune -f
