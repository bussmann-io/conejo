FROM data.forgejo.org/forgejo/runner:13.2.2 AS runner

FROM node:24-slim AS node

FROM ubuntu:24.04

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl dumb-init git jq openssh-client sudo unzip xz-utils zip \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /work
COPY --from=node /usr/local/bin/node /usr/local/bin/node
COPY --from=node /usr/local/lib/node_modules /usr/local/lib/node_modules
RUN ln -s ../lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm \
    && ln -s ../lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx \
    && ln -s ../lib/node_modules/corepack/dist/corepack.js /usr/local/bin/corepack
COPY --from=runner /bin/forgejo-runner /bin/forgejo-runner
COPY --chmod=755 conejo-runner.sh /usr/local/bin/conejo-runner

ENV GOMAXPROCS=2

ENTRYPOINT ["/usr/bin/dumb-init", "--"]
CMD ["/usr/local/bin/conejo-runner"]
