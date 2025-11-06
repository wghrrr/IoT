docker stop radarr
docker stop sonarr
docker stop prowlarr
docker stop transmission
docker rm -f radarr
docker rm -f sonarr
docker rm -f prowlarr
docker rm -f transmission
docker-compose pull
docker-compose up -d

