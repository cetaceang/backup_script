#!/usr/bin/env bash

set -Eeuo pipefail
umask 077
export LC_ALL=C

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly ENV_FILE="${BACKUP_ENV_FILE:-${SCRIPT_DIR}/.env}"

partial_path=""
response_file=""
auth_header_file=""
declare -a SOURCE_PATHS=()
declare -a SOURCE_ENTRIES=()

log() {
    local level="$1"
    shift
    printf '%s [%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$level" "$*" >&2
}

die() {
    log ERROR "$*"
    exit 1
}

cleanup() {
    local status=$?

    if [[ -n "$partial_path" && -e "$partial_path" ]]; then
        rm -f -- "$partial_path"
    fi
    if [[ -n "$response_file" && -e "$response_file" ]]; then
        rm -f -- "$response_file"
    fi
    if [[ -n "$auth_header_file" && -e "$auth_header_file" ]]; then
        rm -f -- "$auth_header_file"
    fi
    if (( status != 0 )); then
        log ERROR "Backup failed (exit status: ${status})."
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

require_commands() {
    local command_name
    local -a missing=()

    for command_name in tar gzip curl flock sha256sum hostname date stat df realpath mktemp grep awk mkdir head tr mv rm; do
        if ! command -v "$command_name" >/dev/null 2>&1; then
            missing+=("$command_name")
        fi
    done

    if (( ${#missing[@]} > 0 )); then
        die "Missing required commands: ${missing[*]}"
    fi
}

load_config() {
    local env_owner env_mode env_mode_value

    [[ -f "$ENV_FILE" ]] || die "Configuration file not found: ${ENV_FILE}. Copy .env.example to .env and edit it."

    env_owner="$(stat -Lc '%u' -- "$ENV_FILE")" || die "Cannot inspect configuration owner: ${ENV_FILE}"
    if [[ "$env_owner" != "$EUID" ]]; then
        die "Configuration must be owned by the running user (uid ${EUID}): ${ENV_FILE}"
    fi

    env_mode="$(stat -Lc '%a' -- "$ENV_FILE")" || die "Cannot inspect configuration permissions: ${ENV_FILE}"
    env_mode_value=$((8#$env_mode))
    if (( (env_mode_value & 077) != 0 )); then
        die "Configuration permissions are too open (${env_mode}); run: chmod 600 '${ENV_FILE}'"
    fi

    unset OPENLIST_URL OPENLIST_TOKEN OPENLIST_REMOTE_DIR SOURCE_DIRS WORK_DIR
    # This is a trusted, owner-only Bash environment file (mode 600).
    # shellcheck disable=SC1090
    source "$ENV_FILE"

    : "${OPENLIST_URL:?OPENLIST_URL is required in ${ENV_FILE}}"
    : "${OPENLIST_TOKEN:?OPENLIST_TOKEN is required in ${ENV_FILE}}"
    : "${OPENLIST_REMOTE_DIR:?OPENLIST_REMOTE_DIR is required in ${ENV_FILE}}"
    : "${SOURCE_DIRS:?SOURCE_DIRS is required in ${ENV_FILE}}"

    WORK_DIR="${WORK_DIR:-/var/tmp/openlist-backup}"
}

validate_config() {
    if [[ "$OPENLIST_URL" != http://* && "$OPENLIST_URL" != https://* ]]; then
        die "OPENLIST_URL must start with http:// or https://"
    fi
    if [[ "$OPENLIST_URL" == *$'\n'* || "$OPENLIST_URL" == *$'\r'* ]]; then
        die "OPENLIST_URL contains a newline."
    fi
    if [[ "$OPENLIST_TOKEN" == *$'\n'* || "$OPENLIST_TOKEN" == *$'\r'* ]]; then
        die "OPENLIST_TOKEN contains a newline."
    fi
    if [[ "$OPENLIST_REMOTE_DIR" != /* ]]; then
        die "OPENLIST_REMOTE_DIR must be an absolute OpenList path beginning with '/'."
    fi
    if [[ "$OPENLIST_REMOTE_DIR" == *$'\n'* || "$OPENLIST_REMOTE_DIR" == *$'\r'* ]]; then
        die "OPENLIST_REMOTE_DIR contains a newline."
    fi
    if [[ "$WORK_DIR" != /* ]]; then
        die "WORK_DIR must be an absolute local path."
    fi

    OPENLIST_URL="${OPENLIST_URL%/}"
    if [[ "$OPENLIST_REMOTE_DIR" != "/" ]]; then
        OPENLIST_REMOTE_DIR="${OPENLIST_REMOTE_DIR%/}"
    fi
}

parse_sources() {
    local source source_real work_real
    local -a lines=()

    mapfile -t lines <<< "$SOURCE_DIRS"
    SOURCE_PATHS=()
    SOURCE_ENTRIES=()

    work_real="$(realpath -e -- "$WORK_DIR")" || die "Cannot resolve WORK_DIR: ${WORK_DIR}"

    for source in "${lines[@]}"; do
        source="${source%$'\r'}"
        [[ -n "$source" ]] || continue

        if [[ "$source" != /* ]]; then
            die "Every source must be an absolute path; invalid source: ${source}"
        fi
        while [[ "$source" != "/" && "$source" == */ ]]; do
            source="${source%/}"
        done
        [[ -d "$source" ]] || die "Source directory does not exist: ${source}"
        [[ ! -L "$source" ]] || die "Source directory must not be a symbolic link; use its resolved path: ${source}"
        [[ -r "$source" && -x "$source" ]] || die "Source directory is not readable: ${source}"

        source_real="$(realpath -e -- "$source")" || die "Cannot resolve source directory: ${source}"
        if [[ "$source_real" == "/" || "$work_real" == "$source_real" || "$work_real" == "$source_real/"* ]]; then
            die "WORK_DIR (${WORK_DIR}) must not be inside a source directory (${source})."
        fi

        SOURCE_PATHS+=("$source")
        SOURCE_ENTRIES+=("${source#/}")
    done

    if (( ${#SOURCE_PATHS[@]} == 0 )); then
        die "SOURCE_DIRS does not contain any directories."
    fi
}

urlencode() {
    local input="$1"
    local output="" char hex
    local i

    for ((i = 0; i < ${#input}; i++)); do
        char="${input:i:1}"
        case "$char" in
            [a-zA-Z0-9.~_-]) output+="$char" ;;
            *)
                printf -v hex '%%%02X' "'$char"
                output+="$hex"
                ;;
        esac
    done
    printf '%s' "$output"
}

format_response() {
    local file="$1"
    head -c 2000 -- "$file" | tr '\r\n' '  '
}

main() {
    local available_bytes archive_name archive_path hostname_safe timestamp
    local archive_size archive_sha remote_path encoded_remote_path http_code curl_status
    local env_real env_entry env_real_entry response_text
    local work_owner work_mode work_mode_value
    local -a tar_excludes=()

    require_commands
    load_config
    validate_config

    mkdir -p -- "$WORK_DIR" || die "Cannot create WORK_DIR: ${WORK_DIR}"
    [[ -d "$WORK_DIR" && -w "$WORK_DIR" && -x "$WORK_DIR" ]] || die "WORK_DIR is not writable: ${WORK_DIR}"

    work_owner="$(stat -Lc '%u' -- "$WORK_DIR")"
    [[ "$work_owner" == "$EUID" ]] || die "WORK_DIR must be owned by the running user (uid ${EUID}): ${WORK_DIR}"
    work_mode="$(stat -Lc '%a' -- "$WORK_DIR")"
    work_mode_value=$((8#$work_mode))
    if (( (work_mode_value & 077) != 0 )); then
        die "WORK_DIR permissions are too open (${work_mode}); run: chmod 700 '${WORK_DIR}'"
    fi

    exec 9>"${WORK_DIR}/.backup.lock"
    if ! flock -n 9; then
        die "Another backup process is already running."
    fi

    parse_sources

    available_bytes="$(df -PB1 -- "$WORK_DIR" | awk 'NR == 2 { print $4 }')"
    [[ "$available_bytes" =~ ^[0-9]+$ && "$available_bytes" -gt 0 ]] || die "Unable to determine free space for WORK_DIR."
    log INFO "Available workspace capacity: ${available_bytes} bytes."

    hostname_safe="$(hostname -s)"
    hostname_safe="$(printf '%s' "$hostname_safe" | tr -c 'a-zA-Z0-9._-' '_')"
    [[ -n "$hostname_safe" ]] || hostname_safe="unknown-host"
    timestamp="$(date -u '+%Y%m%dT%H%M%SZ')"
    archive_name="backup-${hostname_safe}-${timestamp}.tar.gz"
    archive_path="${WORK_DIR}/${archive_name}"
    partial_path="${archive_path}.partial"

    if [[ -e "$archive_path" || -e "$partial_path" ]]; then
        die "Local archive name already exists: ${archive_path}"
    fi

    env_real="$(realpath -e -- "$ENV_FILE")"
    env_entry="${ENV_FILE#/}"
    env_real_entry="${env_real#/}"
    tar_excludes+=("--exclude=${env_entry}")
    if [[ "$env_real_entry" != "$env_entry" ]]; then
        tar_excludes+=("--exclude=${env_real_entry}")
    fi

    log INFO "Creating ${archive_name} from ${#SOURCE_PATHS[@]} source directories."
    if ! tar -C / "${tar_excludes[@]}" -czf "$partial_path" -- "${SOURCE_ENTRIES[@]}"; then
        die "tar failed; the incomplete archive will be removed."
    fi
    mv -- "$partial_path" "$archive_path"
    partial_path=""

    archive_size="$(stat -c '%s' -- "$archive_path")"
    archive_sha="$(sha256sum -- "$archive_path")"
    archive_sha="${archive_sha%% *}"
    log INFO "Archive created (${archive_size} bytes, sha256: ${archive_sha})."

    remote_path="${OPENLIST_REMOTE_DIR%/}/${archive_name}"
    encoded_remote_path="$(urlencode "$remote_path")"
    response_file="$(mktemp "${WORK_DIR}/.openlist-response.XXXXXX")"
    auth_header_file="$(mktemp "${WORK_DIR}/.openlist-auth.XXXXXX")"
    printf 'Authorization: %s\n' "$OPENLIST_TOKEN" > "$auth_header_file"

    log INFO "Uploading to OpenList path: ${remote_path}"
    if http_code="$(curl \
        --silent \
        --show-error \
        --fail-with-body \
        --retry 3 \
        --retry-delay 2 \
        --retry-all-errors \
        --connect-timeout 15 \
        --request PUT \
        --output "$response_file" \
        --write-out '%{http_code}' \
        --header "@${auth_header_file}" \
        --header "File-Path: ${encoded_remote_path}" \
        --header 'Overwrite: false' \
        --header 'Content-Type: application/gzip' \
        --header "X-File-Size: ${archive_size}" \
        --header "X-File-Sha256: ${archive_sha}" \
        --upload-file "$archive_path" \
        "${OPENLIST_URL}/api/fs/put")"; then
        curl_status=0
    else
        curl_status=$?
    fi

    if (( curl_status != 0 )); then
        response_text="$(format_response "$response_file")"
        [[ -n "$response_text" ]] && log ERROR "OpenList response: ${response_text}"
        die "Upload request failed (curl status: ${curl_status}, HTTP status: ${http_code:-000}); local archive retained: ${archive_path}"
    fi

    if [[ "$http_code" != "200" ]] || ! grep -Eq '^[[:space:]]*\{[[:space:]]*"code"[[:space:]]*:[[:space:]]*200([[:space:]]*[,}])' "$response_file"; then
        response_text="$(format_response "$response_file")"
        die "OpenList rejected the upload (HTTP status: ${http_code}, response: ${response_text:-empty}); local archive retained: ${archive_path}"
    fi

    rm -f -- "$archive_path"
    log INFO "Upload completed and local archive removed: ${remote_path}"
}

main "$@"
