docker rm -f jellyfin
docker rm -f radarr
docker rm -f sonarr
docker rm -f prowlarr
docker rm -f transmission
docker-compose pull
docker-compose up -d
docker image prune -f
