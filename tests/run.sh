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
export SHIPYARD_MOCK_DOCKER_STATE="$TEST_ROOT/mock-docker.state"
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

reset_mock_docker() {
  unset SHIPYARD_MOCK_DOCKER_FAIL_UP
  unset SHIPYARD_MOCK_DOCKER_FAIL_BUILD
  unset SHIPYARD_MOCK_DOCKER_SKIP_SERVER
  unset SHIPYARD_MOCK_DOCKER_UNHEALTHY_HTTP
  if [ -f "$SHIPYARD_TEST_DOCKER_PID_FILE" ]; then
    kill "$(cat "$SHIPYARD_TEST_DOCKER_PID_FILE")" 2>/dev/null || true
    rm -f "$SHIPYARD_TEST_DOCKER_PID_FILE"
  fi
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

assert_file_not_contains() {
  local name="$1"
  local file="$2"
  local pattern="$3"

  if grep -q "$pattern" "$file" 2>/dev/null; then
    fail "$name (unexpected '$pattern' in $file)"
  else
    ok "$name"
  fi
}

make_docker_artifact() {
  local output="$1"
  local dir="$TEST_ROOT/$(basename "$output")-dir"
  mkdir -p "$dir"
  cp "$ROOT_DIR/tests/fixtures/docker-app/docker-compose.prod.yml" "$dir/"
  tar -czf "$output" -C "$dir" .
}

cleanup() {
  reset_mock_docker
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

reset_mock_docker
assert_success "create docker project" \
  shipyard create test-docker --type docker --domain test.example.com --port "$DOCKER_TEST_PORT"

assert_success "project directory exists" test -d "$SHIPYARD_SITES_ROOT/test-docker"
assert_success "project config exists" test -f "$SHIPYARD_CONFIG_DIR/test-docker.conf"
assert_file_contains "config has TYPE=docker" "$SHIPYARD_CONFIG_DIR/test-docker.conf" 'TYPE="docker"'
assert_file_contains "config has DOCKER_PORT" "$SHIPYARD_CONFIG_DIR/test-docker.conf" "DOCKER_PORT=\"$DOCKER_TEST_PORT\""
assert_file_contains "config has compose file" "$SHIPYARD_CONFIG_DIR/test-docker.conf" 'DOCKER_COMPOSE_FILE="docker-compose.prod.yml"'
assert_file_contains "config has health path" "$SHIPYARD_CONFIG_DIR/test-docker.conf" 'DOCKER_HEALTH_PATH="/"'
assert_file_contains "nginx proxies to docker port" "$SHIPYARD_NGINX_AVAILABLE/test-docker" "proxy_pass http://127.0.0.1:$DOCKER_TEST_PORT;"

say "Create validation"

assert_failure "invalid project type" shipyard create bad-type --type something
assert_failure "invalid port abc" shipyard create bad-port --type docker --port abc
assert_failure "invalid port 0" shipyard create bad-port-zero --type docker --port 0
assert_failure "invalid port 70000" shipyard create bad-port-high --type docker --port 70000

say "Docker deployment"

rm -f "$SHIPYARD_MOCK_DOCKER_LOG"
make_docker_artifact "$TEST_ROOT/release1.tar.gz"
assert_success "deploy docker release" \
  shipyard deploy test-docker "$TEST_ROOT/release1.tar.gz" release1

assert_file_contains "compose up was executed" "$SHIPYARD_MOCK_DOCKER_LOG" 'up -d --build'
assert_success "current points to release1 only after health check" \
  test "$(readlink -f "$SHIPYARD_SITES_ROOT/test-docker/current")" = "$(readlink -f "$SHIPYARD_SITES_ROOT/test-docker/releases/release1")"

make_docker_artifact "$TEST_ROOT/release2.tar.gz"
assert_success "deploy second docker release" \
  shipyard deploy test-docker "$TEST_ROOT/release2.tar.gz" release2

say "Docker status"

shipyard status test-docker >/tmp/shipyard-test.out 2>/tmp/shipyard-test.err
assert_file_contains "status shows docker type" /tmp/shipyard-test.out 'Type    : docker'
assert_file_contains "status shows compose project" /tmp/shipyard-test.out 'Compose project : shipyard-test-docker'
assert_file_contains "status shows running" /tmp/shipyard-test.out 'Status          : running'
assert_file_contains "status shows port" /tmp/shipyard-test.out "Port            : $DOCKER_TEST_PORT"
assert_file_contains "status shows health path" /tmp/shipyard-test.out 'Health path     : /'
assert_file_contains "status shows healthy" /tmp/shipyard-test.out 'Health          : healthy'

say "Docker health checks"

HEALTH_PROJECT="test-docker-health"
reset_mock_docker
assert_success "create health path project" \
  shipyard create "$HEALTH_PROJECT" --type docker --domain health.example.com --port "$DOCKER_TEST_PORT"

sed -i '' 's|^DOCKER_HEALTH_PATH=.*|DOCKER_HEALTH_PATH="/health"|' \
  "$SHIPYARD_CONFIG_DIR/$HEALTH_PROJECT.conf" 2>/dev/null \
  || sed -i 's|^DOCKER_HEALTH_PATH=.*|DOCKER_HEALTH_PATH="/health"|' \
    "$SHIPYARD_CONFIG_DIR/$HEALTH_PROJECT.conf"
make_docker_artifact "$TEST_ROOT/health-release.tar.gz"
assert_success "deploy with custom health path" \
  shipyard deploy "$HEALTH_PROJECT" "$TEST_ROOT/health-release.tar.gz" health-release

shipyard status "$HEALTH_PROJECT" >/tmp/shipyard-test.out
assert_file_contains "status shows custom health path" /tmp/shipyard-test.out 'Health path     : /health'

UNHEALTHY_PROJECT="test-docker-unhealthy"
reset_mock_docker
assert_success "create unhealthy test project" \
  shipyard create "$UNHEALTHY_PROJECT" --type docker --domain unhealthy.example.com --port "$DOCKER_TEST_PORT"

export SHIPYARD_MOCK_DOCKER_UNHEALTHY_HTTP=1
make_docker_artifact "$TEST_ROOT/unhealthy-release.tar.gz"
assert_failure "unhealthy HTTP endpoint rejected" \
  shipyard deploy "$UNHEALTHY_PROJECT" "$TEST_ROOT/unhealthy-release.tar.gz" unhealthy-release
unset SHIPYARD_MOCK_DOCKER_UNHEALTHY_HTTP

assert_success "unhealthy deploy leaves no current release" \
  test ! -L "$SHIPYARD_SITES_ROOT/$UNHEALTHY_PROJECT/current"

say "Docker deploy failure safety"

FAIL_PROJECT="test-docker-fail"
reset_mock_docker
assert_success "create failure test project" \
  shipyard create "$FAIL_PROJECT" --type docker --domain fail.example.com --port "$DOCKER_TEST_PORT"

make_docker_artifact "$TEST_ROOT/good-release.tar.gz"
assert_success "deploy good release for failure test" \
  shipyard deploy "$FAIL_PROJECT" "$TEST_ROOT/good-release.tar.gz" good-release

BAD_ARTIFACT="$TEST_ROOT/bad-artifact"
mkdir -p "$BAD_ARTIFACT"
echo "no compose here" > "$BAD_ARTIFACT/README"
tar -czf "$TEST_ROOT/bad-release.tar.gz" -C "$BAD_ARTIFACT" .

assert_failure "deploy without compose file fails" \
  shipyard deploy "$FAIL_PROJECT" "$TEST_ROOT/bad-release.tar.gz" bad-release

assert_success "current restored to good release after missing compose" \
  test "$(readlink -f "$SHIPYARD_SITES_ROOT/$FAIL_PROJECT/current")" = \
    "$(readlink -f "$SHIPYARD_SITES_ROOT/$FAIL_PROJECT/releases/good-release")"
assert_success "failed release directory removed" \
  test ! -d "$SHIPYARD_SITES_ROOT/$FAIL_PROJECT/releases/bad-release"

export SHIPYARD_MOCK_DOCKER_FAIL_BUILD=1
make_docker_artifact "$TEST_ROOT/build-fail.tar.gz"
assert_failure "failed compose build does not switch current" \
  shipyard deploy "$FAIL_PROJECT" "$TEST_ROOT/build-fail.tar.gz" build-fail
unset SHIPYARD_MOCK_DOCKER_FAIL_BUILD

assert_success "current remains good release after build failure" \
  test "$(readlink -f "$SHIPYARD_SITES_ROOT/$FAIL_PROJECT/current")" = \
    "$(readlink -f "$SHIPYARD_SITES_ROOT/$FAIL_PROJECT/releases/good-release")"
assert_success "build-fail release removed" \
  test ! -d "$SHIPYARD_SITES_ROOT/$FAIL_PROJECT/releases/build-fail"
assert_file_contains "build failure logged" "$SHIPYARD_LOG_DIR/$FAIL_PROJECT.log" "docker compose up failed"

reset_mock_docker
make_docker_artifact "$TEST_ROOT/good-release-2.tar.gz"
shipyard deploy "$FAIL_PROJECT" "$TEST_ROOT/good-release-2.tar.gz" good-release-2 >/dev/null

export SHIPYARD_MOCK_DOCKER_FAIL_UP=1
make_docker_artifact "$TEST_ROOT/up-fail.tar.gz"
assert_failure "failed compose up restores previous deployment" \
  shipyard deploy "$FAIL_PROJECT" "$TEST_ROOT/up-fail.tar.gz" up-fail
unset SHIPYARD_MOCK_DOCKER_FAIL_UP

reset_mock_docker
make_docker_artifact "$TEST_ROOT/good-release-3.tar.gz"
shipyard deploy "$FAIL_PROJECT" "$TEST_ROOT/good-release-3.tar.gz" good-release-3 >/dev/null

export SHIPYARD_MOCK_DOCKER_SKIP_SERVER=1
make_docker_artifact "$TEST_ROOT/health-fail.tar.gz"
assert_failure "failed health check restores previous deployment" \
  shipyard deploy "$FAIL_PROJECT" "$TEST_ROOT/health-fail.tar.gz" health-fail
unset SHIPYARD_MOCK_DOCKER_SKIP_SERVER

assert_success "previous release still available after health failure" \
  test -d "$SHIPYARD_SITES_ROOT/$FAIL_PROJECT/releases/good-release-3"

assert_file_not_contains "never runs docker compose down -v" "$SHIPYARD_MOCK_DOCKER_LOG" "down -v"

say "Docker rollback"

reset_mock_docker
make_docker_artifact "$TEST_ROOT/rollback-r1.tar.gz"
shipyard deploy test-docker "$TEST_ROOT/rollback-r1.tar.gz" rollback-r1 >/dev/null
make_docker_artifact "$TEST_ROOT/rollback-r2.tar.gz"
shipyard deploy test-docker "$TEST_ROOT/rollback-r2.tar.gz" rollback-r2 >/dev/null

assert_success "successful docker rollback" shipyard rollback test-docker
assert_success "current release points to rollback-r1 after rollback" \
  test "$(readlink -f "$SHIPYARD_SITES_ROOT/test-docker/current")" = \
    "$(readlink -f "$SHIPYARD_SITES_ROOT/test-docker/releases/rollback-r1")"

ROLLBACK_FAIL_PROJECT="test-docker-rollback-fail"
reset_mock_docker
assert_success "create rollback failure project" \
  shipyard create "$ROLLBACK_FAIL_PROJECT" --type docker --domain rb-fail.example.com --port "$DOCKER_TEST_PORT"

make_docker_artifact "$TEST_ROOT/rb-good1.tar.gz"
shipyard deploy "$ROLLBACK_FAIL_PROJECT" "$TEST_ROOT/rb-good1.tar.gz" rb-good1 >/dev/null
make_docker_artifact "$TEST_ROOT/rb-good2.tar.gz"
shipyard deploy "$ROLLBACK_FAIL_PROJECT" "$TEST_ROOT/rb-good2.tar.gz" rb-good2 >/dev/null

export SHIPYARD_MOCK_DOCKER_FAIL_UP=1
assert_failure "failed docker rollback does not corrupt current" \
  shipyard rollback "$ROLLBACK_FAIL_PROJECT"
unset SHIPYARD_MOCK_DOCKER_FAIL_UP

assert_success "current remains on working release after failed rollback" \
  test "$(readlink -f "$SHIPYARD_SITES_ROOT/$ROLLBACK_FAIL_PROJECT/current")" = \
    "$(readlink -f "$SHIPYARD_SITES_ROOT/$ROLLBACK_FAIL_PROJECT/releases/rb-good2")"

say "Shared env handling"

SHARED_PROJECT="test-shared-env"
reset_mock_docker
assert_success "create shared env project" \
  shipyard create "$SHARED_PROJECT" --type docker --domain shared.example.com --port 9090

echo "SECRET=value" > "$SHIPYARD_SITES_ROOT/$SHARED_PROJECT/shared/.env"
mkdir -p "$SHIPYARD_SITES_ROOT/$SHARED_PROJECT/releases/envtest"
cp "$ROOT_DIR/tests/fixtures/docker-app/docker-compose.prod.yml" \
  "$SHIPYARD_SITES_ROOT/$SHARED_PROJECT/releases/envtest/"
echo "ARTIFACT_SECRET=leak" > "$SHIPYARD_SITES_ROOT/$SHARED_PROJECT/releases/envtest/.env"

SHIPYARD_ROOT="$ROOT_DIR" bash -c "
  source '$ROOT_DIR/lib/docker.sh'
  docker_link_shared_env '$SHIPYARD_SITES_ROOT/$SHARED_PROJECT' \
    '$SHIPYARD_SITES_ROOT/$SHARED_PROJECT/releases/envtest'
"

assert_success "production .env not overwritten" \
  grep -q "ARTIFACT_SECRET=leak" "$SHIPYARD_SITES_ROOT/$SHARED_PROJECT/releases/envtest/.env"

RELEASE_ENV_PROJECT="test-release-env"
reset_mock_docker
assert_success "create release env project" \
  shipyard create "$RELEASE_ENV_PROJECT" --type docker --domain release-env.example.com --port "$DOCKER_TEST_PORT"

echo "SECRET=from-shared" > "$SHIPYARD_SITES_ROOT/$RELEASE_ENV_PROJECT/shared/.env"
make_docker_artifact "$TEST_ROOT/release-env.tar.gz"
shipyard deploy "$RELEASE_ENV_PROJECT" "$TEST_ROOT/release-env.tar.gz" release-env >/dev/null

assert_success "release links to shared .env" \
  test "$(readlink -f "$SHIPYARD_SITES_ROOT/$RELEASE_ENV_PROJECT/releases/release-env/.env")" = \
    "$(readlink -f "$SHIPYARD_SITES_ROOT/$RELEASE_ENV_PROJECT/shared/.env")"

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
