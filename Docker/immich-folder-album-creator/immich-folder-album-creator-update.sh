docker rm -f immich_folder_album_creator
docker-compose pull
docker-compose up -d
docker image prune -f
