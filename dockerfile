FROM ubuntu/bind9:9.18-22.04_beta

COPY entrypoint.sh /usr/local/bin/docker-entrypoint.sh
