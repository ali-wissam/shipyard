#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

TEST_ROOT="$(mktemp -d)"
export SHIPYARD_ROOT="$ROOT_DIR"
export SHIPYARD_CONFIG_DIR="$TEST_ROOT/config"
export SHIPYARD_SITES_ROOT="$TEST_ROOT/sites"
export SHIPYARD_NGINX_AVAILABLE="$TEST_ROOT/nginx/sites-available"
export SHIPYARD_NGINX_ENABLED="$TEST_ROOT/nginx/sites-enabled"
export SHIPYARD_LOG_DIR="$TEST_ROOT/log"
export SHIPYARD_SKIP_NGINX_RELOAD=1
export SHIPYARD_MOCK_DOCKER_LOG="$TEST_ROOT/mock-docker.log"
export SHIPYARD_TEST_DOCKER_PID_FILE="$TEST_ROOT/mock-docker.pid"
export SHIPYARD_TEST_DOCKER_PORT=18080
DOCKER_TEST_PORT=18080
export PATH="$ROOT_DIR/tests/bin:$ROOT_DIR:$PATH"

PASS=0
FAIL=0

say() {
  echo ""
  echo "==> $1"
}

ok() {
  echo "✓ $1"
  PASS=$((PASS + 1))
}

fail() {
  echo "✗ $1"
  FAIL=$((FAIL + 1))
}

assert_success() {
  local name="$1"
  shift

  if "$@" >/tmp/shipyard-test.out 2>/tmp/shipyard-test.err; then
    ok "$name"
  else
    fail "$name"
    cat /tmp/shipyard-test.err
  fi
}

assert_failure() {
  local name="$1"
  shift

  if "$@" >/tmp/shipyard-test.out 2>/tmp/shipyard-test.err; then
    fail "$name"
  else
    ok "$name"
  fi
}

assert_file_contains() {
  local name="$1"
  local file="$2"
  local pattern="$3"

  if grep -q "$pattern" "$file"; then
    ok "$name"
  else
    fail "$name (expected '$pattern' in $file)"
  fi
}

cleanup() {
  if [ -f "$SHIPYARD_TEST_DOCKER_PID_FILE" ]; then
    kill "$(cat "$SHIPYARD_TEST_DOCKER_PID_FILE")" 2>/dev/null || true
  fi
  rm -rf "$TEST_ROOT"
}

trap cleanup EXIT

mkdir -p "$SHIPYARD_CONFIG_DIR" "$SHIPYARD_SITES_ROOT" "$SHIPYARD_NGINX_AVAILABLE" \
  "$SHIPYARD_NGINX_ENABLED" "$SHIPYARD_LOG_DIR"

say "Syntax checks"

for file in "$ROOT_DIR"/shipyard "$ROOT_DIR"/bin/* "$ROOT_DIR"/lib/*.sh; do
  assert_success "syntax: $(basename "$file")" bash -n "$file"
done

say "Static template checks"

assert_success "static nginx template exists" test -f "$ROOT_DIR/templates/nginx/static.conf"
assert_success "laravel nginx template exists" test -f "$ROOT_DIR/templates/nginx/laravel.conf"
assert_success "node nginx template exists" test -f "$ROOT_DIR/templates/nginx/node.conf"
assert_success "docker nginx template exists" test -f "$ROOT_DIR/templates/nginx/docker.conf"

say "Required files"

assert_success "README exists" test -f "$ROOT_DIR/README.md"
assert_success "VERSION exists" test -f "$ROOT_DIR/VERSION"
assert_success "installer exists" test -f "$ROOT_DIR/install.sh"

say "Create docker project"

assert_success "create docker project" \
  shipyard create test-docker --type docker --domain test.example.com --port "$DOCKER_TEST_PORT"

assert_success "project directory exists" test -d "$SHIPYARD_SITES_ROOT/test-docker"
assert_success "project config exists" test -f "$SHIPYARD_CONFIG_DIR/test-docker.conf"
assert_file_contains "config has TYPE=docker" "$SHIPYARD_CONFIG_DIR/test-docker.conf" 'TYPE="docker"'
assert_file_contains "config has DOCKER_PORT" "$SHIPYARD_CONFIG_DIR/test-docker.conf" "DOCKER_PORT=\"$DOCKER_TEST_PORT\""
assert_file_contains "config has compose file" "$SHIPYARD_CONFIG_DIR/test-docker.conf" 'DOCKER_COMPOSE_FILE="docker-compose.prod.yml"'
assert_file_contains "nginx proxies to docker port" "$SHIPYARD_NGINX_AVAILABLE/test-docker" "proxy_pass http://127.0.0.1:$DOCKER_TEST_PORT;"

say "Create validation"

assert_failure "invalid project type" shipyard create bad-type --type something
assert_failure "invalid port abc" shipyard create bad-port --type docker --port abc
assert_failure "invalid port 0" shipyard create bad-port-zero --type docker --port 0
assert_failure "invalid port 70000" shipyard create bad-port-high --type docker --port 70000

say "Docker deployment"

ARTIFACT_DIR="$TEST_ROOT/artifact"
mkdir -p "$ARTIFACT_DIR"
cp "$ROOT_DIR/tests/fixtures/docker-app/docker-compose.prod.yml" "$ARTIFACT_DIR/"
tar -czf "$TEST_ROOT/release1.tar.gz" -C "$ARTIFACT_DIR" .

rm -f "$SHIPYARD_MOCK_DOCKER_LOG"
assert_success "deploy docker release" \
  shipyard deploy test-docker "$TEST_ROOT/release1.tar.gz" release1

assert_file_contains "compose up was executed" "$SHIPYARD_MOCK_DOCKER_LOG" 'up -d --build'
assert_success "current release points to release1" \
  test "$(readlink -f "$SHIPYARD_SITES_ROOT/test-docker/current")" = "$(readlink -f "$SHIPYARD_SITES_ROOT/test-docker/releases/release1")"

ARTIFACT_DIR2="$TEST_ROOT/artifact2"
mkdir -p "$ARTIFACT_DIR2"
cp "$ROOT_DIR/tests/fixtures/docker-app/docker-compose.prod.yml" "$ARTIFACT_DIR2/"
tar -czf "$TEST_ROOT/release2.tar.gz" -C "$ARTIFACT_DIR2" .

assert_success "deploy second docker release" \
  shipyard deploy test-docker "$TEST_ROOT/release2.tar.gz" release2

say "Docker status"

shipyard status test-docker >/tmp/shipyard-test.out 2>/tmp/shipyard-test.err
assert_file_contains "status shows docker type" /tmp/shipyard-test.out 'Type    : docker'
assert_file_contains "status shows compose project" /tmp/shipyard-test.out 'Compose project : shipyard-test-docker'
assert_file_contains "status shows running" /tmp/shipyard-test.out 'Status          : running'
assert_file_contains "status shows port" /tmp/shipyard-test.out "Port            : $DOCKER_TEST_PORT"

say "Docker deploy failure safety"

FAIL_PROJECT="test-docker-fail"
assert_success "create failure test project" \
  shipyard create "$FAIL_PROJECT" --type docker --domain fail.example.com --port "$DOCKER_TEST_PORT"

GOOD_ARTIFACT="$TEST_ROOT/good-artifact"
mkdir -p "$GOOD_ARTIFACT"
cp "$ROOT_DIR/tests/fixtures/docker-app/docker-compose.prod.yml" "$GOOD_ARTIFACT/"
tar -czf "$TEST_ROOT/good-release.tar.gz" -C "$GOOD_ARTIFACT" .
assert_success "deploy good release for failure test" \
  shipyard deploy "$FAIL_PROJECT" "$TEST_ROOT/good-release.tar.gz" good-release

BAD_ARTIFACT="$TEST_ROOT/bad-artifact"
mkdir -p "$BAD_ARTIFACT"
echo "no compose here" > "$BAD_ARTIFACT/README"
tar -czf "$TEST_ROOT/bad-release.tar.gz" -C "$BAD_ARTIFACT" .

assert_failure "deploy without compose file fails" \
  shipyard deploy "$FAIL_PROJECT" "$TEST_ROOT/bad-release.tar.gz" bad-release

assert_success "current restored to good release after failed deploy" \
  test "$(readlink -f "$SHIPYARD_SITES_ROOT/$FAIL_PROJECT/current")" = \
    "$(readlink -f "$SHIPYARD_SITES_ROOT/$FAIL_PROJECT/releases/good-release")"

say "Docker rollback"

assert_success "rollback docker project" shipyard rollback test-docker
assert_success "current release points to release1 after rollback" \
  test "$(readlink -f "$SHIPYARD_SITES_ROOT/test-docker/current")" = "$(readlink -f "$SHIPYARD_SITES_ROOT/test-docker/releases/release1")"
assert_file_contains "rollback ran compose up" "$SHIPYARD_MOCK_DOCKER_LOG" 'up -d --build'

say "Shared env handling"

SHARED_PROJECT="test-shared-env"
assert_success "create shared env project" \
  shipyard create "$SHARED_PROJECT" --type docker --domain shared.example.com --port 9090

echo "SECRET=value" > "$SHIPYARD_SITES_ROOT/$SHARED_PROJECT/shared/.env"
mkdir -p "$SHIPYARD_SITES_ROOT/$SHARED_PROJECT/releases/envtest"
cp "$ROOT_DIR/tests/fixtures/docker-app/docker-compose.prod.yml" \
  "$SHIPYARD_SITES_ROOT/$SHARED_PROJECT/releases/envtest/"

SHIPYARD_ROOT="$ROOT_DIR" bash -c "
  source '$ROOT_DIR/lib/docker.sh'
  docker_link_shared_env '$SHIPYARD_SITES_ROOT/$SHARED_PROJECT' \
    '$SHIPYARD_SITES_ROOT/$SHARED_PROJECT/releases/envtest'
"

assert_success "shared env symlink created" \
  test -L "$SHIPYARD_SITES_ROOT/$SHARED_PROJECT/releases/envtest/.env"
assert_success "shared env points to shared/.env" \
  test "$(readlink -f "$SHIPYARD_SITES_ROOT/$SHARED_PROJECT/releases/envtest/.env")" = \
    "$(readlink -f "$SHIPYARD_SITES_ROOT/$SHARED_PROJECT/shared/.env")"

say "Help mentions docker"

shipyard help >/tmp/shipyard-test.out
assert_file_contains "help lists docker type" /tmp/shipyard-test.out "docker"
assert_file_contains "help shows docker create example" /tmp/shipyard-test.out "create blog --type docker"

echo ""
echo "Passed: $PASS"
echo "Failed: $FAIL"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
