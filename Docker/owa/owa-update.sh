docker rm -f open-web-analytics
docker rm -f owa_db
docker-compose pull
docker-compose up -d
docker image prune -f
