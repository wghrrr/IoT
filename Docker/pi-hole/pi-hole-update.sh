docker rm -f pihole
docker-compose pull
docker-compose up -d
docker image prune -f
docker exec -it pihole pihole -v
