#!/usr/bin/env bash

set -Eeuo pipefail
umask 077
export LC_ALL=C

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_DIR
ENV_FILE="${BACKUP_ENV_FILE:-${SCRIPT_DIR}/.env}"
readonly ENV_FILE

partial_path=""
response_file=""
auth_header_file=""
request_file=""
tool_partial_path=""
JSON_PARSER_KIND=""
JSON_PARSER_COMMAND=""
declare -a SOURCE_PATHS=()
declare -a SOURCE_ENTRIES=()

readonly JQ_VERSION="1.8.2"
readonly JQ_RELEASE_BASE_URL="https://github.com/jqlang/jq/releases/download/jq-${JQ_VERSION}"

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
    if [[ -n "$request_file" && -e "$request_file" ]]; then
        rm -f -- "$request_file"
    fi
    if [[ -n "$tool_partial_path" && -e "$tool_partial_path" ]]; then
        rm -f -- "$tool_partial_path"
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

    for command_name in tar gzip curl flock sha256sum hostname date stat df realpath mktemp grep awk mkdir head tr sort uname chmod mv rm; do
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

    unset OPENLIST_URL OPENLIST_TOKEN OPENLIST_REMOTE_DIR SOURCE_DIRS WORK_DIR BACKUP_ID REMOTE_KEEP_COUNT
    # This is a trusted, owner-only Bash environment file (mode 600).
    # shellcheck disable=SC1090
    source "$ENV_FILE"

    : "${OPENLIST_URL:?OPENLIST_URL is required in ${ENV_FILE}}"
    : "${OPENLIST_TOKEN:?OPENLIST_TOKEN is required in ${ENV_FILE}}"
    : "${OPENLIST_REMOTE_DIR:?OPENLIST_REMOTE_DIR is required in ${ENV_FILE}}"
    : "${SOURCE_DIRS:?SOURCE_DIRS is required in ${ENV_FILE}}"

    WORK_DIR="${WORK_DIR:-/var/tmp/openlist-backup}"
    REMOTE_KEEP_COUNT="${REMOTE_KEEP_COUNT:-7}"

    if [[ -z "${BACKUP_ID:-}" ]]; then
        BACKUP_ID="$(hostname -s)"
        BACKUP_ID="$(printf '%s' "$BACKUP_ID" | tr -c 'a-zA-Z0-9._-' '_')"
        [[ -n "$BACKUP_ID" ]] || BACKUP_ID="unknown-host"
    fi
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
    if [[ ! "$BACKUP_ID" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]{0,63}$ ]]; then
        die "BACKUP_ID must be 1-64 characters using only letters, numbers, dots, underscores, or hyphens."
    fi
    if [[ ! "$REMOTE_KEEP_COUNT" =~ ^[0-9]+$ ]]; then
        die "REMOTE_KEEP_COUNT must be a non-negative integer."
    fi
    if (( ${#REMOTE_KEEP_COUNT} > 6 )); then
        die "REMOTE_KEEP_COUNT is unreasonably large."
    fi
    REMOTE_KEEP_COUNT=$((10#$REMOTE_KEEP_COUNT))

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

download_jq() {
    local machine asset expected_sha tool_dir target actual_sha

    if [[ "$(uname -s)" != "Linux" ]]; then
        die "Automatic jq download supports Linux only; install jq or Python 3 manually."
    fi

    machine="$(uname -m)"
    case "$machine" in
        x86_64|amd64)
            asset="jq-linux-amd64"
            expected_sha="b1c22172dd303f3be49e935aa56aa48a8b7a46e0bc838b4997d3bb451495870f"
            ;;
        aarch64|arm64)
            asset="jq-linux-arm64"
            expected_sha="8b85c817833814ddca00a144c33705546355afccf0cf39b188f3cdb48b852309"
            ;;
        armv7l|armv7*)
            asset="jq-linux-armhf"
            expected_sha="78458244fb546469b4042e9e07cf78714ef6848895eb9515df76b4eb0b1dc992"
            ;;
        armv5*|armv6l|armel)
            asset="jq-linux-armel"
            expected_sha="d88f6bd640ef8909b3deb587f12c03a0ed38fe8bd5e2e882e2b1bf88f5dab8d2"
            ;;
        i386|i486|i586|i686)
            asset="jq-linux-i386"
            expected_sha="ba996e8ce436973e2f39e2639405a37e8c81ba8c722b71c83996278ad0af16dd"
            ;;
        *)
            die "No bundled jq download is available for architecture '${machine}'; install jq or Python 3 manually."
            ;;
    esac

    tool_dir="${WORK_DIR}/.tools"
    mkdir -p -- "$tool_dir" || die "Cannot create tool cache: ${tool_dir}"
    chmod 700 -- "$tool_dir" || die "Cannot secure tool cache: ${tool_dir}"
    target="${tool_dir}/jq-${JQ_VERSION}-${asset}"

    if [[ -f "$target" ]]; then
        actual_sha="$(sha256sum -- "$target")"
        actual_sha="${actual_sha%% *}"
        if [[ "$actual_sha" == "$expected_sha" ]]; then
            chmod 700 -- "$target" || die "Cannot make cached jq executable: ${target}"
            if "$target" --version >/dev/null 2>&1; then
                JSON_PARSER_KIND="jq"
                JSON_PARSER_COMMAND="$target"
                log INFO "Using cached jq ${JQ_VERSION}: ${target}"
                return
            fi
        fi
        log WARN "Ignoring invalid cached jq and downloading a verified copy: ${target}"
    fi

    tool_partial_path="$(mktemp "${target}.partial.XXXXXX")"
    log INFO "Downloading jq ${JQ_VERSION} for ${machine}."
    if ! curl \
        --silent \
        --show-error \
        --fail \
        --location \
        --retry 3 \
        --retry-delay 2 \
        --retry-all-errors \
        --connect-timeout 15 \
        --output "$tool_partial_path" \
        "${JQ_RELEASE_BASE_URL}/${asset}"; then
        die "Unable to download jq; install jq or Python 3 manually."
    fi

    actual_sha="$(sha256sum -- "$tool_partial_path")"
    actual_sha="${actual_sha%% *}"
    if [[ "$actual_sha" != "$expected_sha" ]]; then
        die "Downloaded jq checksum mismatch (expected ${expected_sha}, got ${actual_sha})."
    fi

    chmod 700 -- "$tool_partial_path" || die "Cannot make downloaded jq executable."
    if ! "$tool_partial_path" --version >/dev/null 2>&1; then
        die "Downloaded jq failed its executable check."
    fi
    mv -- "$tool_partial_path" "$target"
    tool_partial_path=""

    JSON_PARSER_KIND="jq"
    JSON_PARSER_COMMAND="$target"
    log INFO "Downloaded and verified jq ${JQ_VERSION}: ${target}"
}

select_json_parser() {
    local candidate

    if candidate="$(command -v jq 2>/dev/null)" && "$candidate" -n '1' >/dev/null 2>&1; then
        JSON_PARSER_KIND="jq"
        JSON_PARSER_COMMAND="$candidate"
        log INFO "Using system jq for OpenList retention."
        return
    fi

    if candidate="$(command -v python3 2>/dev/null)" && "$candidate" -c 'import json, sys; assert sys.version_info >= (3, 6)' >/dev/null 2>&1; then
        JSON_PARSER_KIND="python"
        JSON_PARSER_COMMAND="$candidate"
        log INFO "Using system python3 for OpenList retention."
        return
    fi

    if candidate="$(command -v python 2>/dev/null)" && "$candidate" -c 'import json, sys; assert sys.version_info >= (3, 6)' >/dev/null 2>&1; then
        JSON_PARSER_KIND="python"
        JSON_PARSER_COMMAND="$candidate"
        log INFO "Using Python 3 from '${candidate}' for OpenList retention."
        return
    fi

    download_jq
}

json_quote() {
    local value="$1"

    case "$JSON_PARSER_KIND" in
        jq)
            # The single-quoted expression is jq syntax, not a shell expansion.
            # shellcheck disable=SC2016
            "$JSON_PARSER_COMMAND" -cn --arg value "$value" '$value'
            ;;
        python)
            "$JSON_PARSER_COMMAND" -c 'import json, sys; sys.stdout.write(json.dumps(sys.argv[1], ensure_ascii=True))' "$value"
            ;;
        *)
            return 1
            ;;
    esac
}

json_list_backup_names() {
    local file="$1"
    local prefix="$2"

    case "$JSON_PARSER_KIND" in
        jq)
            # The single-quoted expression is jq syntax, not a shell expansion.
            # shellcheck disable=SC2016
            "$JSON_PARSER_COMMAND" -r --arg prefix "$prefix" '
                if .code != 200 then
                    error("OpenList list error: " + (.message // "unknown error"))
                elif ((.data.content // []) | type) != "array" then
                    error("OpenList list response has no content array")
                else
                    [
                        (.data.content // [])[]
                        | select(.is_dir == false)
                        | .name
                        | select(type == "string")
                        | select(startswith($prefix))
                        | ltrimstr($prefix)
                        | select(test("^[0-9]{8}T[0-9]{6}Z\\.tar\\.gz$"))
                        | $prefix + .
                    ]
                    | unique
                    | sort
                    | reverse
                    | .[]
                end
            ' "$file"
            ;;
        python)
            "$JSON_PARSER_COMMAND" -c '
import json
import re
import sys

file_name, prefix = sys.argv[1], sys.argv[2]
with open(file_name, "r", encoding="utf-8") as stream:
    payload = json.load(stream)
if payload.get("code") != 200:
    raise SystemExit("OpenList list error: " + str(payload.get("message", "unknown error")))
data = payload.get("data")
content = data.get("content") if isinstance(data, dict) else None
if content is None:
    content = []
if not isinstance(content, list):
    raise SystemExit("OpenList list response has no content array")
pattern = re.compile(r"^" + re.escape(prefix) + r"[0-9]{8}T[0-9]{6}Z\.tar\.gz$")
names = sorted({
    item.get("name")
    for item in content
    if isinstance(item, dict)
    and item.get("is_dir") is False
    and isinstance(item.get("name"), str)
    and pattern.fullmatch(item.get("name"))
}, reverse=True)
sys.stdout.write("\n".join(names))
if names:
    sys.stdout.write("\n")
' "$file" "$prefix"
            ;;
        *)
            return 1
            ;;
    esac
}

json_response_is_success() {
    local file="$1"

    case "$JSON_PARSER_KIND" in
        jq)
            "$JSON_PARSER_COMMAND" -e '.code == 200' "$file" >/dev/null
            ;;
        python)
            "$JSON_PARSER_COMMAND" -c '
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as stream:
    payload = json.load(stream)
if payload.get("code") != 200:
    raise SystemExit("OpenList error: " + str(payload.get("message", "unknown error")))
' "$file"
            ;;
        *)
            return 1
            ;;
    esac
}

write_list_request() {
    local file="$1"
    local quoted_dir

    quoted_dir="$(json_quote "$OPENLIST_REMOTE_DIR")" || return 1
    printf '{"path":%s,"password":"","page":1,"per_page":0,"refresh":true}\n' "$quoted_dir" > "$file"
}

write_remove_request() {
    local file="$1"
    shift
    local quoted_dir name separator=""

    quoted_dir="$(json_quote "$OPENLIST_REMOTE_DIR")" || return 1
    {
        printf '{"dir":%s,"names":[' "$quoted_dir"
        for name in "$@"; do
            printf '%s"%s"' "$separator" "$name"
            separator=","
        done
        printf ']}\n'
    } > "$file"
}

openlist_post_json() {
    local endpoint="$1"
    local body_file="$2"
    local http_code curl_status response_text

    if http_code="$(curl \
        --silent \
        --show-error \
        --fail-with-body \
        --retry 3 \
        --retry-delay 2 \
        --retry-all-errors \
        --connect-timeout 15 \
        --request POST \
        --output "$response_file" \
        --write-out '%{http_code}' \
        --header "@${auth_header_file}" \
        --header 'Content-Type: application/json' \
        --data-binary "@${body_file}" \
        "${OPENLIST_URL}${endpoint}")"; then
        curl_status=0
    else
        curl_status=$?
    fi

    if (( curl_status != 0 )) || [[ "$http_code" != "200" ]]; then
        response_text="$(format_response "$response_file")"
        [[ -n "$response_text" ]] && log ERROR "OpenList response: ${response_text}"
        log ERROR "OpenList request failed (endpoint: ${endpoint}, curl status: ${curl_status}, HTTP status: ${http_code:-000})."
        return 1
    fi
}

prune_remote_backups() {
    local prefix names_output response_text
    local total delete_count
    local -a remote_backups=()
    local -a delete_names=()

    if (( REMOTE_KEEP_COUNT == 0 )); then
        log INFO "Remote retention is disabled (REMOTE_KEEP_COUNT=0)."
        return
    fi

    select_json_parser
    request_file="$(mktemp "${WORK_DIR}/.openlist-request.XXXXXX")"

    write_list_request "$request_file" || die "Unable to build the OpenList list request."
    if ! openlist_post_json "/api/fs/list" "$request_file"; then
        die "Unable to list remote backups; the newly uploaded backup remains in OpenList."
    fi

    prefix="backup-${BACKUP_ID}-"
    if ! names_output="$(json_list_backup_names "$response_file" "$prefix")"; then
        response_text="$(format_response "$response_file")"
        log ERROR "OpenList response: ${response_text:-empty}"
        die "Unable to parse the remote backup list; the newly uploaded backup remains in OpenList."
    fi
    if [[ -n "$names_output" ]]; then
        mapfile -t remote_backups <<< "$names_output"
    fi

    total=${#remote_backups[@]}
    if (( total <= REMOTE_KEEP_COUNT )); then
        log INFO "Remote retention: ${total} matching backup(s), nothing to delete (keeping ${REMOTE_KEEP_COUNT})."
        return
    fi

    delete_names=("${remote_backups[@]:REMOTE_KEEP_COUNT}")
    delete_count=${#delete_names[@]}
    write_remove_request "$request_file" "${delete_names[@]}" || die "Unable to build the OpenList remove request."
    if ! openlist_post_json "/api/fs/remove" "$request_file"; then
        die "Unable to remove old remote backups; the newly uploaded backup remains in OpenList."
    fi
    if ! json_response_is_success "$response_file"; then
        response_text="$(format_response "$response_file")"
        log ERROR "OpenList response: ${response_text:-empty}"
        die "OpenList rejected removal of old backups; the newly uploaded backup remains in OpenList."
    fi

    log INFO "Remote retention removed ${delete_count} old backup(s); kept the newest ${REMOTE_KEEP_COUNT}."
}

main() {
    local available_bytes archive_name archive_path timestamp
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

    timestamp="$(date -u '+%Y%m%dT%H%M%SZ')"
    archive_name="backup-${BACKUP_ID}-${timestamp}.tar.gz"
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

    prune_remote_backups
}

main "$@"
