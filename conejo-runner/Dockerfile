FROM data.forgejo.org/forgejo/runner:13.2.2

USER root
RUN apk add --no-cache ca-certificates curl jq nodejs npm openssh-client \
    && mkdir -p /work
COPY --chmod=755 conejo-runner.sh /usr/local/bin/conejo-runner

ENV GOMAXPROCS=2

CMD ["/usr/local/bin/conejo-runner"]
