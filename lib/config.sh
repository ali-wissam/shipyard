#!/usr/bin/env bash

SHIPYARD_ROOT="${SHIPYARD_ROOT:-/opt/shipyard}"
CONFIG_DIR="${SHIPYARD_CONFIG_DIR:-/etc/deploy-sites}"
SITES_ROOT="${SHIPYARD_SITES_ROOT:-/var/www/sites}"
NGINX_SITES_AVAILABLE="${SHIPYARD_NGINX_AVAILABLE:-/etc/nginx/sites-available}"
NGINX_SITES_ENABLED="${SHIPYARD_NGINX_ENABLED:-/etc/nginx/sites-enabled}"
LOG_DIR="${SHIPYARD_LOG_DIR:-/var/log/shipyard}"

load_project_config() {
  local project="$1"
  local config_file="$CONFIG_DIR/$project.conf"

  if [ ! -f "$config_file" ]; then
    echo "Config not found: $config_file"
    exit 1
  fi

  # shellcheck source=/dev/null
  source "$config_file"

  if [ -z "${PROJECT_NAME:-}" ] || [ -z "${PROJECT_DIR:-}" ]; then
    echo "Invalid config: PROJECT_NAME and PROJECT_DIR are required"
    exit 1
  fi
}

validate_tcp_port() {
  local port="$1"

  if [[ ! "$port" =~ ^[0-9]+$ ]]; then
    echo "Invalid port: must be numeric"
    return 1
  fi

  if [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
    echo "Invalid port: must be between 1 and 65535"
    return 1
  fi

  return 0
}

docker_compose_project_name() {
  local project="$1"
  echo "shipyard-$project"
}
