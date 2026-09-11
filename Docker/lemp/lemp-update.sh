docker rm -f lemp_php
docker-compose pull
docker-compose up -d --build
docker image prune -f
