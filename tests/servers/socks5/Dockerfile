# Dante, the SOCKS5 proxy with_socks5.sh puts between Tacky and the server.
FROM alpine:3.22
RUN apk add --no-cache dante-server \
 && adduser -D -H proxyuser \
 && echo proxyuser:proxypass | chpasswd
COPY sockd.conf /etc/sockd.conf
ENTRYPOINT ["sockd", "-f", "/etc/sockd.conf", "-N", "1"]
