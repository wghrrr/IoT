docker stop monitoring-cadvisor
docker stop monitoring-pihole-exporter
docker stop monitoring-grafana
docker stop monitoring-node-exporter
docker stop monitoring-prometheus
docker rm -f monitoring-cadvisor
docker rm -f monitoring-pihole-exporter
docker rm -f monitoring-grafana
docker rm -f monitoring-node-exporter
docker rm -f monitoring-prometheus 
docker-compose pull
docker-compose up -d

