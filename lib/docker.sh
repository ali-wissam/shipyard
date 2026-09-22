#!/usr/bin/env bash

source "${SHIPYARD_ROOT:-/opt/shipyard}/lib/config.sh"

DOCKER_HEALTH_RETRIES="${DOCKER_HEALTH_RETRIES:-10}"
DOCKER_HEALTH_DELAY="${DOCKER_HEALTH_DELAY:-2}"

docker_compose_file_path() {
  local release_dir="$1"
  local compose_file="$2"
  echo "$release_dir/$compose_file"
}

docker_normalize_health_path() {
  local health_path="${1:-/}"
  if [ -z "$health_path" ]; then
    health_path="/"
  elif [[ "$health_path" != /* ]]; then
    health_path="/$health_path"
  fi
  echo "$health_path"
}

docker_health_url() {
  local port="$1"
  local health_path="$2"
  echo "http://127.0.0.1:${port}$(docker_normalize_health_path "$health_path")"
}

docker_link_shared_env() {
  local project_dir="$1"
  local release_dir="$2"
  local shared_env="$project_dir/shared/.env"
  local release_env="$release_dir/.env"

  if [ ! -f "$shared_env" ]; then
    return 0
  fi

  if [ -e "$release_env" ] && [ ! -L "$release_env" ]; then
    echo "Keeping existing release .env (not overwriting with shared/.env)"
    return 0
  fi

  ln -sf "$shared_env" "$release_env"
}

docker_compose_run() {
  local project="$1"
  local release_dir="$2"
  local compose_file="$3"
  shift 3

  local compose_path
  compose_path="$(docker_compose_file_path "$release_dir" "$compose_file")"
  local project_name
  project_name="$(docker_compose_project_name "$project")"

  (
    cd "$release_dir"
    docker compose -p "$project_name" -f "$compose_path" "$@"
  )
}

docker_validate_release() {
  local release_dir="$1"
  local compose_file="$2"

  if [ ! -f "$release_dir/$compose_file" ]; then
    echo "Compose file not found: $release_dir/$compose_file"
    return 1
  fi

  return 0
}

docker_containers_running() {
  local project="$1"
  local release_dir="$2"
  local compose_file="$3"

  local running
  running="$(docker_compose_run "$project" "$release_dir" "$compose_file" ps --status running -q 2>/dev/null || true)"

  [ -n "$running" ]
}

docker_http_responds() {
  local port="$1"
  local health_path="${2:-/}"
  local retries="${3:-$DOCKER_HEALTH_RETRIES}"
  local delay="${4:-$DOCKER_HEALTH_DELAY}"
  local url
  url="$(docker_health_url "$port" "$health_path")"

  local attempt=0
  while [ "$attempt" -lt "$retries" ]; do
    if command -v curl >/dev/null 2>&1; then
      if curl -sf --max-time 3 "$url" >/dev/null 2>&1; then
        return 0
      fi
    elif (echo >/dev/tcp/127.0.0.1/"$port") 2>/dev/null; then
      return 0
    fi

    attempt=$((attempt + 1))
    if [ "$attempt" -lt "$retries" ] && [ "$delay" -gt 0 ]; then
      sleep "$delay"
    fi
  done

  return 1
}

docker_health_check() {
  local project="$1"
  local release_dir="$2"
  local compose_file="$3"
  local port="$4"
  local health_path="${5:-/}"

  if ! docker_containers_running "$project" "$release_dir" "$compose_file"; then
    echo "Health check failed: no running containers"
    return 1
  fi

  if ! docker_http_responds "$port" "$health_path"; then
    echo "Health check failed: $(docker_health_url "$port" "$health_path") did not return a successful HTTP response"
    return 1
  fi

  return 0
}

docker_log_failure() {
  local log_file="$1"
  local reason="$2"
  local project="$3"
  local release_dir="$4"
  local compose_file="$5"

  {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Docker failure: $reason"
    echo "--- docker compose ps ---"
    docker_compose_run "$project" "$release_dir" "$compose_file" ps -a 2>&1 || true
    echo "--- docker compose logs (last 30 lines) ---"
    docker_compose_run "$project" "$release_dir" "$compose_file" logs --no-color --tail=30 2>&1 || true
  } >> "$log_file"
}

docker_deploy_release() {
  local project="$1"
  local project_dir="$2"
  local release_dir="$3"
  local compose_file="$4"
  local port="$5"
  local health_path="$6"
  local log_file="$7"

  if ! docker_validate_release "$release_dir" "$compose_file"; then
    docker_log_failure "$log_file" "compose file validation failed" "$project" "$release_dir" "$compose_file"
    return 1
  fi

  docker_link_shared_env "$project_dir" "$release_dir"

  if ! docker_compose_run "$project" "$release_dir" "$compose_file" up -d --build >>"$log_file" 2>&1; then
    docker_log_failure "$log_file" "docker compose up failed" "$project" "$release_dir" "$compose_file"
    return 1
  fi

  if ! docker_health_check "$project" "$release_dir" "$compose_file" "$port" "$health_path"; then
    docker_log_failure "$log_file" "health check failed" "$project" "$release_dir" "$compose_file"
    return 1
  fi

  return 0
}

docker_restore_release() {
  local project="$1"
  local project_dir="$2"
  local release_dir="$3"
  local compose_file="$4"
  local port="$5"
  local health_path="$6"
  local log_file="${7:-}"

  docker_link_shared_env "$project_dir" "$release_dir"

  if ! docker_compose_run "$project" "$release_dir" "$compose_file" up -d --build; then
    if [ -n "$log_file" ]; then
      docker_log_failure "$log_file" "failed to restore previous deployment" "$project" "$release_dir" "$compose_file"
    fi
    return 1
  fi

  if ! docker_health_check "$project" "$release_dir" "$compose_file" "$port" "$health_path"; then
    if [ -n "$log_file" ]; then
      docker_log_failure "$log_file" "restored deployment failed health check" "$project" "$release_dir" "$compose_file"
    fi
    return 1
  fi

  return 0
}

docker_status_summary() {
  local project="$1"
  local release_dir="$2"
  local compose_file="$3"
  local port="$4"
  local health_path="${5:-/}"

  local project_name
  project_name="$(docker_compose_project_name "$project")"
  local status="stopped"
  local health="unhealthy"
  local normalized_path
  normalized_path="$(docker_normalize_health_path "$health_path")"

  if docker_containers_running "$project" "$release_dir" "$compose_file"; then
    if docker_http_responds "$port" "$normalized_path" 1 0; then
      status="running"
      health="healthy"
    else
      status="unhealthy"
    fi
  fi

  echo "  Compose project : $project_name"
  echo "  Status          : $status"
  echo "  Port            : $port"
  echo "  Health path     : $normalized_path"
  echo "  Health          : $health"
}
