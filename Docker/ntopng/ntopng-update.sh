docker rm -f ntop
docker rm -f clickhouse
docker-compose pull
docker-compose up -d
docker image prune -f
