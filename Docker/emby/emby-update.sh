docker stop embyserver
docker rm -f embyserver
docker-compose pull
docker-compose up -d

