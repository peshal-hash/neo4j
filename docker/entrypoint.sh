#!/usr/bin/env bash
set -euo pipefail

NEO4J_HOME="${NEO4J_HOME:-/opt/neo4j}"
CONF_FILE="${NEO4J_HOME}/conf/neo4j.conf"
NEO4J_USER="${NEO4J_USER:-neo4j}"

ensure_runtime_permissions() {
  local paths=("/data" "/logs" "/import" "/plugins")
  local path
  local expected_owner
  local current_owner

  for path in "${paths[@]}"; do
    mkdir -p "${path}"
  done

  if [[ "$(id -u)" -eq 0 ]]; then
    expected_owner="$(id -u "${NEO4J_USER}"):$(id -g "${NEO4J_USER}")"
    for path in "${paths[@]}"; do
      current_owner="$(stat -c '%u:%g' "${path}")"
      if [[ "${current_owner}" != "${expected_owner}" ]]; then
        chown -R "${NEO4J_USER}:${NEO4J_USER}" "${path}"
      fi
    done
    exec gosu "${NEO4J_USER}" "$0" "$@"
  fi

  for path in "${paths[@]}"; do
    if [[ ! -w "${path}" ]]; then
      echo "Path '${path}' is not writable by uid $(id -u). Check volume ownership." >&2
      exit 70
    fi
  done
}

set_config() {
  local key="$1"
  local value="$2"
  local key_regex
  local value_escaped

  key_regex="$(printf '%s' "${key}" | sed -e 's/[.[\*^$()+?{}|]/\\&/g')"
  value_escaped="$(printf '%s' "${value}" | sed -e 's/[&|]/\\&/g')"

  if grep -Eq "^[#[:space:]]*${key_regex}=" "${CONF_FILE}"; then
    sed -i -E "s|^[#[:space:]]*${key_regex}=.*|${key}=${value_escaped}|" "${CONF_FILE}"
  else
    printf '%s=%s\n' "${key}" "${value}" >> "${CONF_FILE}"
  fi
}

set_config_from_env() {
  local env_name="$1"
  local key="$2"
  local value="${!env_name:-}"
  if [[ -n "${value}" ]]; then
    set_config "${key}" "${value}"
  fi
}

configure_paths_and_network() {
  set_config "server.default_listen_address" "0.0.0.0"
  set_config "server.directories.data" "/data"
  set_config "server.directories.logs" "/logs"
  set_config "server.directories.import" "/import"
  set_config "server.directories.plugins" "/plugins"
}

configure_from_env() {
  set_config_from_env "NEO4J_server_default__listen__address" "server.default_listen_address"
  set_config_from_env "NEO4J_server_default__advertised__address" "server.default_advertised_address"
  set_config_from_env "NEO4J_server_bolt_listen__address" "server.bolt.listen_address"
  set_config_from_env "NEO4J_server_bolt_advertised__address" "server.bolt.advertised_address"
  set_config_from_env "NEO4J_server_http_listen__address" "server.http.listen_address"
  set_config_from_env "NEO4J_server_http_advertised__address" "server.http.advertised_address"
  set_config_from_env "NEO4J_server_https_listen__address" "server.https.listen_address"
  set_config_from_env "NEO4J_server_https_advertised__address" "server.https.advertised_address"
  set_config_from_env "NEO4J_server_bolt_tls__level" "server.bolt.tls_level"
  set_config_from_env "NEO4J_server_directories_data" "server.directories.data"
  set_config_from_env "NEO4J_server_directories_logs" "server.directories.logs"
  set_config_from_env "NEO4J_server_directories_import" "server.directories.import"
  set_config_from_env "NEO4J_server_directories_plugins" "server.directories.plugins"
  set_config_from_env "NEO4J_dbms_security_allow__csv__import__from__file__urls" "dbms.security.allow_csv_import_from_file_urls"
  set_config_from_env "NEO4J_server_memory_heap_initial__size" "server.memory.heap.initial_size"
  set_config_from_env "NEO4J_server_memory_heap_max__size" "server.memory.heap.max_size"
}

clear_stale_locks() {
  local data_dir="${NEO4J_server_directories_data:-/data}"
  local db_dir="${data_dir}/databases"

  if [[ -d "${db_dir}" ]]; then
    find "${db_dir}" -name "store_lock" -type f | while read -r lock_file; do
      echo "Removing stale store_lock: ${lock_file}" >&2
      rm -f "${lock_file}"
    done
  fi
}

force_reset_auth_if_requested() {
  local reset_auth="${NEO4J_FORCE_RESET_AUTH:-false}"
  case "${reset_auth,,}" in
    1|true|yes|on)
      local data_dir="${NEO4J_server_directories_data:-/data}"
      echo "NEO4J_FORCE_RESET_AUTH is enabled; removing auth files and system database." >&2
      # Remove auth marker files used by set-initial-password
      rm -f "${data_dir}/dbms/auth" "${data_dir}/dbms/auth.ini"
      # Also wipe the system database and its transaction logs so Neo4j recreates
      # it from scratch on next start, picking up the new password from set-initial-password.
      # Without this, set-initial-password has no effect on an already-initialized instance.
      rm -rf "${data_dir}/databases/system" "${data_dir}/transactions/system"
      echo "Auth state fully cleared. Neo4j will reinitialize with credentials from NEO4J_AUTH." >&2
      ;;
  esac
}

configure_auth() {
  local auth="${NEO4J_AUTH:-}"
  local auth_user
  local auth_password

  if [[ -z "${auth}" ]]; then
    return
  fi

  if [[ "${auth}" == "none" ]]; then
    set_config "dbms.security.auth_enabled" "false"
    return
  fi

  auth_user="${auth%%/*}"
  auth_password="${auth#*/}"

  if [[ "${auth_user}" == "${auth}" || -z "${auth_user}" || -z "${auth_password}" ]]; then
    echo "Invalid NEO4J_AUTH format. Use 'neo4j/<password>' or 'none'." >&2
    exit 1
  fi

  if [[ "${auth_user}" != "neo4j" ]]; then
    echo "NEO4J_AUTH user '${auth_user}' is not supported for initial setup in Community; applying password to 'neo4j'." >&2
  fi

  if [[ ! -f /data/dbms/auth && ! -f /data/dbms/auth.ini ]]; then
    "${NEO4J_HOME}/bin/neo4j-admin" dbms set-initial-password "${auth_password}" >/dev/null
  fi
}

ensure_runtime_permissions "$@"
configure_paths_and_network
configure_from_env
force_reset_auth_if_requested
configure_auth
clear_stale_locks

if [[ "$#" -gt 0 ]]; then
  exec "$@"
fi

exec "${NEO4J_HOME}/bin/neo4j" console
