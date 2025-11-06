docker stop pihole
docker rm -f pihole
docker-compose pull
docker-compose up -d
docker exec -it pihole pihole -v
