#!/bin/bash
set -Eeuo pipefail
umask 0077

log() { printf '%s [conejo-runner] %s\n' "$(date -u +%FT%TZ)" "$*"; }
die() {
  log "FATAL: $*"
  exit 1
}

[ -n "${CONEJO_FORGEJO_URL:-}" ] ||
  die "CONEJO_FORGEJO_URL is not set: give the address of your Forgejo, for example https://git.example.com/"
[[ ${CONEJO_RUNNER_SECRET:-} =~ ^[0-9a-f]{40}$ ]] ||
  die "CONEJO_RUNNER_SECRET must be 40 lowercase hex characters, the same value as on the conejo app"
[ -n "${CONEJO_RUNNER_LABELS:-}" ] ||
  die "CONEJO_RUNNER_LABELS is not set: name the labels your workflows use in runs-on, for example bunny"

labels=""
IFS=, read -ra names <<<"$CONEJO_RUNNER_LABELS"
for name in "${names[@]}"; do
  name=${name// /}
  [[ $name =~ ^[A-Za-z0-9._-]+$ ]] || die "CONEJO_RUNNER_LABELS: '$name' is not a valid label"
  labels+=$'\n'"        - $name:host"
done

hex=$(printf '%s' "${CONEJO_RUNNER_SECRET:0:16}" | od -An -tx1 | tr -d ' \n')
uuid=${hex:0:8}-${hex:8:4}-${hex:12:4}-${hex:16:4}-${hex:20:12}

mkdir -p /etc/conejo-runner /run/conejo-runner
printf '%s' "$CONEJO_RUNNER_SECRET" >/run/conejo-runner/token
cat >/etc/conejo-runner/config.yml <<EOF
log:
  level: info
  job_level: info
runner:
  file: /run/conejo-runner/.runner
  capacity: ${CONEJO_RUNNER_CAPACITY:-1}
  envs: {}
  env_file: /run/conejo-runner/no-env-file
  timeout: ${CONEJO_RUNNER_TIMEOUT:-1h}
  shutdown_timeout: 25s
  insecure: false
  fetch_timeout: 30s
  fetch_interval: 5s
  report_interval: 1s
  report_retry:
    max_retries: 30
    initial_delay: 1s
    max_delay: 30s
  labels: []
cache:
  enabled: false
container:
  docker_host: "-"
host:
  workdir_parent: /work
server:
  connections:
    forgejo:
      url: $CONEJO_FORGEJO_URL
      uuid: $uuid
      token_url: file:/run/conejo-runner/token
      labels:$labels
EOF

unset CONEJO_RUNNER_SECRET
cd /work
log "starting $(forgejo-runner --version) for $CONEJO_FORGEJO_URL, labels $CONEJO_RUNNER_LABELS"
exec forgejo-runner daemon --config /etc/conejo-runner/config.yml
