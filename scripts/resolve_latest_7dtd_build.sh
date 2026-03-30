#!/usr/bin/env bash
set -euo pipefail

tools_dir="${TOOLS_DIR:-$(pwd)/.tools}"
steamcmd_dir="${STEAMCMD_DIR:-$tools_dir/steamcmd}"
steamcmd_bin="${STEAMCMD_BIN:-$steamcmd_dir/steamcmd.sh}"
steam_state_dir="${STEAM_STATE_DIR:-$(pwd)/.cache/steamcmd}"
steamcmd_url="${STEAMCMD_URL:-https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz}"
steamcmd_mode="${STEAMCMD_MODE:-auto}"
container_runtime="${CONTAINER_RUNTIME:-docker}"
docker_image="${DOCKER_IMAGE:-debian:bookworm-slim}"
app_id="${APP_ID:?APP_ID is required}"
steam_user="${STEAM_USER:-anonymous}"
steam_pass="${STEAM_PASS:-}"
steam_guard="${STEAM_GUARD:-}"

log() {
    printf '[resolve_latest_7dtd_build] %s\n' "$*"
}

fail() {
    printf '[resolve_latest_7dtd_build] %s\n' "$*" >&2
    exit 1
}

ensure_command() {
    command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

require_steamcmd_runtime() {
    if [ ! -e /lib/ld-linux.so.2 ] && [ ! -e /lib32/ld-linux.so.2 ] && [ ! -e /lib/i386-linux-gnu/ld-linux.so.2 ]; then
        fail "steamcmd requires 32-bit glibc loader (ld-linux.so.2). Install your distro's 32-bit glibc/Steam runtime support, or rerun with STEAMCMD_MODE=docker."
    fi
}

can_use_local_steamcmd() {
    [ -x "$steamcmd_bin" ] || return 1
    [ -e /lib/ld-linux.so.2 ] || [ -e /lib32/ld-linux.so.2 ] || [ -e /lib/i386-linux-gnu/ld-linux.so.2 ]
}

can_use_container_runtime() {
    command -v "$container_runtime" >/dev/null 2>&1 || return 1
    "$container_runtime" info >/dev/null 2>&1
}

install_steamcmd() {
    if [ -x "$steamcmd_bin" ]; then
        return
    fi

    ensure_command curl
    ensure_command tar

    log "Installing local steamcmd into $steamcmd_dir"
    mkdir -p "$steamcmd_dir"

    local archive
    archive="$(mktemp)"
    trap "rm -f '$archive'" RETURN
    curl -fsSL "$steamcmd_url" -o "$archive"
    tar -xzf "$archive" -C "$steamcmd_dir"
    steamcmd_bin="$steamcmd_dir/steamcmd.sh"
}

append_login_args() {
    local -n target_ref="$1"

    if [ "$steam_user" = "anonymous" ]; then
        target_ref+=(+login anonymous)
        return
    fi

    if [ -z "$steam_pass" ]; then
        fail "STEAM_PASS is required when STEAM_USER is not anonymous"
    fi

    if [ -n "$steam_guard" ]; then
        target_ref+=(+set_steam_guard_code "$steam_guard")
    fi

    target_ref+=(+login "$steam_user" "$steam_pass")
}

run_steamcmd_local() {
    install_steamcmd
    require_steamcmd_runtime

    local -a cmd=("$steamcmd_bin")
    append_login_args cmd
    cmd+=(+app_info_update 1 +app_info_print "$app_id" +quit)

    "${cmd[@]}"
}

run_steamcmd_docker() {
    can_use_container_runtime || fail "Container runtime '$container_runtime' is not available"

    mkdir -p "$steam_state_dir"

    "$container_runtime" run --rm \
        --entrypoint bash \
        -v "$steam_state_dir:/mnt/steam" \
        -e "APP_ID=$app_id" \
        -e "HOST_UID=$(id -u)" \
        -e "HOST_GID=$(id -g)" \
        -e "STEAM_USER=$steam_user" \
        -e "STEAM_PASS=$steam_pass" \
        -e "STEAM_GUARD=$steam_guard" \
        -e "STEAMCMD_URL=$steamcmd_url" \
        "$docker_image" \
        -lc '
            set -euo pipefail

            needs_steamcmd_deps=0
            if ! command -v curl >/dev/null 2>&1 || ! command -v tar >/dev/null 2>&1; then
                needs_steamcmd_deps=1
            fi
            if [ ! -e /lib/ld-linux.so.2 ] && [ ! -e /lib32/ld-linux.so.2 ] && [ ! -e /lib/i386-linux-gnu/ld-linux.so.2 ]; then
                needs_steamcmd_deps=1
            fi

            if [ "$needs_steamcmd_deps" -eq 1 ]; then
                if ! command -v apt-get >/dev/null 2>&1; then
                    echo "Container image is missing required SteamCMD dependencies and does not provide apt-get" >&2
                    exit 1
                fi

                export DEBIAN_FRONTEND=noninteractive
                apt-get update
                apt-get install -y --no-install-recommends ca-certificates curl tar lib32gcc-s1 lib32stdc++6
                rm -rf /var/lib/apt/lists/*
            fi

            if command -v steamcmd >/dev/null 2>&1; then
                steamcmd_bin="$(command -v steamcmd)"
            elif [ -x /home/steam/steamcmd/steamcmd.sh ]; then
                steamcmd_bin=/home/steam/steamcmd/steamcmd.sh
            elif [ -x /steamcmd/steamcmd.sh ]; then
                steamcmd_bin=/steamcmd/steamcmd.sh
            else
                cd /tmp
                mkdir -p steamcmd-bootstrap
                curl -fsSL -o steamcmd.tar.gz "$STEAMCMD_URL"
                tar -xzf steamcmd.tar.gz -C steamcmd-bootstrap
                steamcmd_bin=/tmp/steamcmd-bootstrap/steamcmd.sh
            fi

            mkdir -p /mnt/steam
            export HOME=/mnt/steam

            if [[ "$STEAM_USER" == "anonymous" ]]; then
                "$steamcmd_bin" +login anonymous +app_info_update 1 +app_info_print "$APP_ID" +quit
                chown -R "$HOST_UID:$HOST_GID" /mnt/steam
                exit 0
            fi

            if [[ -n "${STEAM_GUARD:-}" ]]; then
                "$steamcmd_bin" +set_steam_guard_code "$STEAM_GUARD" +login "$STEAM_USER" "$STEAM_PASS" +app_info_update 1 +app_info_print "$APP_ID" +quit
                chown -R "$HOST_UID:$HOST_GID" /mnt/steam
                exit 0
            fi

            "$steamcmd_bin" +login "$STEAM_USER" "$STEAM_PASS" +app_info_update 1 +app_info_print "$APP_ID" +quit
            chown -R "$HOST_UID:$HOST_GID" /mnt/steam
        '
}

query_app_info() {
    case "$steamcmd_mode" in
        local)
            run_steamcmd_local
            ;;
        docker)
            run_steamcmd_docker
            ;;
        auto)
            if can_use_local_steamcmd; then
                run_steamcmd_local
            elif can_use_container_runtime; then
                run_steamcmd_docker
            else
                run_steamcmd_local
            fi
            ;;
        *)
            fail "Unsupported STEAMCMD_MODE: $steamcmd_mode (expected auto, local, or docker)"
            ;;
    esac
}

extract_public_build_id() {
    local source_file="$1"

    awk '
        /"branches"[[:space:]]*$/ {
            in_branches = 1
            next
        }

        in_branches && /"privatebranches"[[:space:]]/ {
            exit
        }

        in_branches && $0 ~ /^[[:space:]]*"[^"]+"[[:space:]]*$/ {
            current_branch = $0
            sub(/^[[:space:]]*"/, "", current_branch)
            sub(/"[[:space:]]*$/, "", current_branch)
            next
        }

        in_branches && current_branch == "public" && $0 ~ /^[[:space:]]*"buildid"[[:space:]]*"/ {
            build_id = $0
            sub(/.*"buildid"[[:space:]]*"/, "", build_id)
            sub(/".*$/, "", build_id)
            print build_id
            exit
        }
    ' "$source_file"
}

main() {
    local query_output
    query_output="$(mktemp)"
    trap "rm -f '$query_output'" EXIT

    log "Resolving latest public build for app $app_id"
    query_app_info | sed -E 's/\x1B\[[0-9;]*[[:alpha:]]//g' > "$query_output"

    latest_build_id="$(extract_public_build_id "$query_output")"
    if [ -z "$latest_build_id" ]; then
        fail "Could not determine latest public build id for app $app_id"
    fi

    if [ -n "${GITHUB_OUTPUT:-}" ]; then
        {
            printf 'app_id=%s\n' "$app_id"
            printf 'latest_build_id=%s\n' "$latest_build_id"
        } >> "$GITHUB_OUTPUT"
    fi

    printf 'App ID: %s\n' "$app_id"
    printf 'Latest build id: %s\n' "$latest_build_id"
}

main "$@"
