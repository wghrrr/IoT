docker rm -f embyserver
docker-compose pull
docker-compose up -d
docker image prune -f
