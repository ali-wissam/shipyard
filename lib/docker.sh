#!/usr/bin/env bash

source "${SHIPYARD_ROOT:-/opt/shipyard}/lib/config.sh"

docker_compose_file_path() {
  local release_dir="$1"
  local compose_file="$2"
  echo "$release_dir/$compose_file"
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

docker_containers_running() {
  local project="$1"
  local release_dir="$2"
  local compose_file="$3"

  local running
  running="$(docker_compose_run "$project" "$release_dir" "$compose_file" ps --status running -q 2>/dev/null || true)"

  [ -n "$running" ]
}

docker_port_responds() {
  local port="$1"
  local retries="${2:-10}"
  local delay="${3:-2}"

  local attempt=0
  while [ "$attempt" -lt "$retries" ]; do
    if command -v curl >/dev/null 2>&1; then
      if curl -sf --max-time 3 "http://127.0.0.1:${port}/" >/dev/null 2>&1; then
        return 0
      fi
    elif (echo >/dev/tcp/127.0.0.1/"$port") 2>/dev/null; then
      return 0
    fi

    attempt=$((attempt + 1))
    sleep "$delay"
  done

  return 1
}

docker_health_check() {
  local project="$1"
  local release_dir="$2"
  local compose_file="$3"
  local port="$4"

  if ! docker_containers_running "$project" "$release_dir" "$compose_file"; then
    echo "Health check failed: no running containers"
    return 1
  fi

  if ! docker_port_responds "$port"; then
    echo "Health check failed: port $port is not responding"
    return 1
  fi

  return 0
}

docker_status_summary() {
  local project="$1"
  local release_dir="$2"
  local compose_file="$3"
  local port="$4"

  local project_name
  project_name="$(docker_compose_project_name "$project")"
  local status="stopped"

  if docker_containers_running "$project" "$release_dir" "$compose_file"; then
    if docker_port_responds "$port" 1 0; then
      status="running"
    else
      status="unhealthy"
    fi
  fi

  echo "  Compose project : $project_name"
  echo "  Status          : $status"
  echo "  Port            : $port"
}

docker_restore_release() {
  local project="$1"
  local project_dir="$2"
  local release_dir="$3"
  local compose_file="$4"

  docker_link_shared_env "$project_dir" "$release_dir"
  docker_compose_run "$project" "$release_dir" "$compose_file" up -d --build
  docker_health_check "$project" "$release_dir" "$compose_file" "${DOCKER_PORT:-8080}"
}
