docker stop homeassistant
docker rm -f homeassistant
docker-compose pull
docker-compose up -d

