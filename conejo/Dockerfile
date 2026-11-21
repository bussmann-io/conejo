FROM data.forgejo.org/forgejo/forgejo:15.0.12-rootless

USER root
RUN apk add --no-cache sqlite
COPY --chmod=755 conejo.sh /usr/local/bin/conejo
USER 1000:1000

ENV GITEA_APP_INI=/tmp/forgejo/app.ini \
    GOMAXPROCS=4 \
    FORGEJO__database__DB_TYPE=sqlite3 \
    FORGEJO__database__SQLITE_JOURNAL_MODE=WAL \
    FORGEJO__security__INSTALL_LOCK=true \
    FORGEJO__server__APP_DATA_PATH=/var/lib/gitea/data \
    FORGEJO__lfs__PATH=/var/lib/gitea/data/lfs \
    FORGEJO__server__SSH_PORT=22 \
    FORGEJO__server__SSH_LISTEN_PORT=2222

CMD ["/usr/local/bin/conejo"]
