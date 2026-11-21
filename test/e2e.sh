#!/bin/bash
set -Eeuo pipefail

usage="usage: test/e2e.sh <conejo image> <conejo-runner image>"
conejo=${1:?$usage}
runner=${2:?$usage}
s3_image=docker.io/versity/versitygw:v1.11.0
run=conejo-e2e-$$
forgejo=$run-forgejo
s3=http://$run-s3:7070
access_key=e2e-access
secret_key=e2e-secret-key
password=e2e-admin-password
forgejo_secret=$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')
runner_secret=$(od -An -N20 -tx1 /dev/urandom | tr -d ' \n')
containers=("$run-s3" "$forgejo" "$run-runner" "$run-restored" "$run-empty" "$run-keyless")
volumes=("$run-data" "$run-restored" "$run-empty")

forgejo_env=(
  -e "FORGEJO__security__SECRET_KEY=$forgejo_secret"
  -e "FORGEJO__server__ROOT_URL=http://$forgejo:3000/"
)
backup_env=(
  -e "CONEJO_BACKUP_URL=$s3/backups/e2e"
  -e CONEJO_BACKUP_REGION=us-east-1
  -e "CONEJO_BACKUP_ACCESS_KEY_ID=$access_key"
  -e "CONEJO_BACKUP_SECRET_ACCESS_KEY=$secret_key"
  -e CONEJO_BACKUP_PASSPHRASE=e2e-passphrase
)

cleanup() {
  docker rm -f "${containers[@]}" >/dev/null 2>&1 || true
  docker volume rm "${volumes[@]}" >/dev/null 2>&1 || true
  docker network rm "$run" >/dev/null 2>&1 || true
}
trap cleanup EXIT

step() { printf '\n== %s\n' "$*"; }

fail() {
  local container
  printf '\nFAIL: %s\n' "$*" >&2
  for container in "${containers[@]}"; do
    docker inspect "$container" >/dev/null 2>&1 || continue
    printf '\n-- logs of %s\n' "$container" >&2
    docker logs "$container" 2>&1 | tail -n 30 >&2
  done
  exit 1
}

wait_until() {
  local seconds=$1 what=$2
  shift 2
  local deadline=$((SECONDS + seconds))
  until "$@" >/dev/null 2>&1; do
    [ "$SECONDS" -lt "$deadline" ] || fail "timed out after ${seconds}s waiting for $what"
    sleep 2
  done
}

logs_contain() { grep -qF -- "$2" <<<"$(docker logs "$1" 2>&1)"; }
healthy() { docker exec "$1" curl -fsS -o /dev/null http://127.0.0.1:3000/api/healthz; }
exited() { [ "$(docker inspect -f '{{.State.Status}}' "$1")" = exited ]; }

wait_healthy() {
  local name=$1 deadline=$((SECONDS + 180))
  until healthy "$name" >/dev/null 2>&1; do
    ! exited "$name" || fail "$name stopped before it became healthy"
    [ "$SECONDS" -lt "$deadline" ] || fail "timed out after 180s waiting for $name to become healthy"
    sleep 2
  done
}

api() {
  local container=$1
  shift
  docker exec "$container" curl -fsS -u "tester:$password" -H 'Content-Type: application/json' "$@"
}

s3_request() {
  docker run --rm --network "$run" --entrypoint curl "$conejo" -fsS \
    --aws-sigv4 aws:amz:us-east-1:s3 -u "$access_key:$secret_key" \
    -H 'x-amz-content-sha256: e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855' "$@"
}

start_forgejo() {
  local name=$1 volume=$2
  shift 2
  docker rm -f "$name" >/dev/null 2>&1 || true
  docker run -d --name "$name" --network "$run" -v "$volume:/var/lib/gitea" "${forgejo_env[@]}" "$@" "$conejo" >/dev/null
}

expect_refusal() {
  local name=$1 message=$2
  wait_until 60 "$name to stop" exited "$name"
  [ "$(docker inspect -f '{{.State.ExitCode}}' "$name")" != 0 ] || fail "$name exited with code 0"
  logs_contain "$name" "$message" || fail "$name did not log: $message"
}

on_volume() {
  docker run --rm -v "$1:/var/lib/gitea" --entrypoint sh "$conejo" -c "$2"
}

repository_exists() { api "$1" "http://127.0.0.1:3000/api/v1/repos/tester/$2" >/dev/null; }

jobs_succeeded() {
  api "$forgejo" http://127.0.0.1:3000/api/v1/repos/tester/probe/actions/tasks |
    jq -e --argjson count "$1" '.workflow_runs | length >= $count and all(.status == "success")' >/dev/null
}

step "start an S3 server"
docker network create "$run" >/dev/null
docker run -d --name "$run-s3" --network "$run" -e "ROOT_ACCESS_KEY=$access_key" -e "ROOT_SECRET_KEY=$secret_key" \
  "$s3_image" --port :7070 posix /tmp >/dev/null
wait_until 30 "the S3 server" s3_request -o /dev/null "$s3/"
s3_request -X PUT -o /dev/null "$s3/backups" || fail "creating the bucket failed"

step "refuse to start without a secret key"
docker run -d --name "$run-keyless" "$conejo" >/dev/null
expect_refusal "$run-keyless" "FATAL: FORGEJO__security__SECRET_KEY is not set"

step "refuse to start on an empty volume"
start_forgejo "$run-empty" "$run-empty"
expect_refusal "$run-empty" "FATAL: no database at"

step "start a new instance with an admin and a runner secret"
start_forgejo "$forgejo" "$run-data" -e CONEJO_EXPECT_DATA=false -e CONEJO_ADMIN_USERNAME=tester \
  -e CONEJO_ADMIN_EMAIL=tester@example.com -e "CONEJO_ADMIN_PASSWORD=$password" -e "CONEJO_RUNNER_SECRET=$runner_secret"
wait_healthy "$forgejo"
logs_contain "$forgejo" "runner: registered for every repository" || fail "the runner was not registered"
api "$forgejo" -X POST -d '{"name":"probe","auto_init":true}' http://127.0.0.1:3000/api/v1/user/repos >/dev/null ||
  fail "creating a repository failed"

step "run a job on the runner"
docker run -d --name "$run-runner" --network "$run" -e "CONEJO_FORGEJO_URL=http://$forgejo:3000/" \
  -e "CONEJO_RUNNER_SECRET=$runner_secret" -e CONEJO_RUNNER_LABELS=e2e "$runner" >/dev/null
workflow=$(printf '%s\n' 'on: push' 'jobs:' '  e2e:' '    runs-on: e2e' '    steps:' \
  '      - run: node --version && npm --version && git --version && jq --version' | base64 | tr -d '\n')
api "$forgejo" -X POST -d "{\"content\":\"$workflow\",\"message\":\"add workflow\"}" \
  http://127.0.0.1:3000/api/v1/repos/tester/probe/contents/.forgejo/workflows/e2e.yml >/dev/null ||
  fail "adding the workflow failed"
wait_until 180 "the job to succeed" jobs_succeeded 1

step "keep an existing admin and back up to S3"
start_forgejo "$forgejo" "$run-data" "${backup_env[@]}" -e CONEJO_ADMIN_USERNAME=tester -e "CONEJO_ADMIN_PASSWORD=$password" \
  -e "CONEJO_RUNNER_SECRET=$runner_secret"
wait_until 180 "the first backup" logs_contain "$forgejo" "backup: uploaded monthly/"
logs_contain "$forgejo" "admin: set the password of tester" || fail "the existing admin was not found"
for slot in hourly daily monthly; do
  logs_contain "$forgejo" "backup: uploaded $slot/forgejo-" || fail "no $slot backup was uploaded"
done
backup=$(docker logs "$forgejo" 2>&1 | grep -o 'hourly/forgejo-[0-9]*\.tar\.gz\.gpg' | tail -n 1)

step "run a job on the same runner after Forgejo restarted"
api "$forgejo" -X POST -d "{\"content\":\"$(printf 'restarted\n' | base64)\",\"message\":\"run the workflow again\"}" \
  http://127.0.0.1:3000/api/v1/repos/tester/probe/contents/restarted.txt >/dev/null ||
  fail "adding a file failed"
wait_until 180 "the second job to succeed" jobs_succeeded 2

step "restore $backup into an empty volume"
start_forgejo "$run-restored" "$run-restored" "${backup_env[@]}" -e "CONEJO_RESTORE_FROM=$backup" \
  -e "CONEJO_RESTORE_ACCESS_KEY_ID=$access_key" -e "CONEJO_RESTORE_SECRET_ACCESS_KEY=$secret_key"
wait_healthy "$run-restored"
api "$run-restored" http://127.0.0.1:3000/api/v1/repos/tester/probe/contents/README.md >/dev/null ||
  fail "the restored instance lacks tester/probe/README.md"

step "copy the database before a version change"
docker rm -f "$forgejo" >/dev/null
on_volume "$run-data" 'echo 15.0.0 >/var/lib/gitea/conejo/version'
start_forgejo "$forgejo" "$run-data"
wait_healthy "$forgejo"
logs_contain "$forgejo" "version change 15.0.0 ->" || fail "no database copy before the version change"
wait_until 30 "the upgrade to be confirmed" logs_contain "$forgejo" "upgrade confirmed"

step "put the database copy back when the new version never became healthy"
docker rm -f "$forgejo" >/dev/null
on_volume "$run-data" 'mkdir -p /var/lib/gitea/conejo/pre-upgrade && cp -p /var/lib/gitea/data/gitea.db /var/lib/gitea/conejo/pre-upgrade/'
start_forgejo "$forgejo" "$run-data"
wait_healthy "$forgejo"
api "$forgejo" -X POST -d '{"name":"after-upgrade"}' http://127.0.0.1:3000/api/v1/user/repos >/dev/null ||
  fail "creating a repository failed"
docker rm -f "$forgejo" >/dev/null
version=$(docker run --rm --entrypoint /app/gitea/gitea "$conejo" --version | sed -n 's/.*(release name \([^)]*\)).*/\1/p')
on_volume "$run-data" "echo '$version 99.0.0' >/var/lib/gitea/conejo/pending"
start_forgejo "$forgejo" "$run-data"
wait_healthy "$forgejo"
logs_contain "$forgejo" "Forgejo 99.0.0 never became healthy" || fail "the database copy was not put back"
repository_exists "$forgejo" probe || fail "tester/probe is missing after putting the copy back"
if repository_exists "$forgejo" after-upgrade; then fail "tester/after-upgrade survived putting the copy back"; fi

printf '\nPASS\n'
