docker rm -f immich_server
docker rm -f immich_redis
docker rm -f immich_postgres
docker-compose pull
docker-compose up -d
docker image prune -f
