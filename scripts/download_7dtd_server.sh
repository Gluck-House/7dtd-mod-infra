#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tools_dir="${TOOLS_DIR:-$repo_root/.tools}"
steamcmd_dir="${STEAMCMD_DIR:-$tools_dir/steamcmd}"
steamcmd_bin="${STEAMCMD_BIN:-$steamcmd_dir/steamcmd.sh}"
server_dir="${SERVER_DIR:-$repo_root/.cache/7dtd-dedicated-server}"
deps_dir="${DEPS_DIR:-$repo_root/deps}"
steam_state_dir="${STEAM_STATE_DIR:-$repo_root/.cache/steamcmd}"
steamcmd_url="${STEAMCMD_URL:-https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz}"
steam_user="${STEAM_USER:-anonymous}"
steam_pass="${STEAM_PASS:-}"
steam_guard="${STEAM_GUARD:-}"
app_id="${APP_ID:-294420}"
validate="${VALIDATE:-0}"
steamcmd_mode="${STEAMCMD_MODE:-auto}"
container_runtime="${CONTAINER_RUNTIME:-docker}"
docker_image="${DOCKER_IMAGE:-debian:bookworm-slim}"

required_files=(
    "0Harmony.dll"
    "Assembly-CSharp.dll"
    "LogLibrary.dll"
    "UnityEngine.dll"
    "UnityEngine.CoreModule.dll"
)

log() {
    printf '[download_7dtd_server] %s\n' "$*"
}

fail() {
    printf '[download_7dtd_server] %s\n' "$*" >&2
    exit 1
}

ensure_command() {
    command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

require_steamcmd_runtime() {
    local steamcmd_runtime_bin
    steamcmd_runtime_bin="$(cd "$(dirname "$steamcmd_bin")" && pwd)/linux32/steamcmd"

    if [ ! -f "$steamcmd_runtime_bin" ]; then
        fail "steamcmd binary not found after install: $steamcmd_runtime_bin"
    fi

    if [ ! -e /lib/ld-linux.so.2 ] && [ ! -e /lib32/ld-linux.so.2 ] && [ ! -e /lib/i386-linux-gnu/ld-linux.so.2 ]; then
        fail "steamcmd requires 32-bit glibc loader (ld-linux.so.2). Install your distro's 32-bit glibc/Steam runtime support, then rerun."
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
    trap 'rm -f "$archive"' RETURN
    curl -fsSL "$steamcmd_url" -o "$archive"
    tar -xzf "$archive" -C "$steamcmd_dir"
    steamcmd_bin="$steamcmd_dir/steamcmd.sh"
}

build_login_args() {
    if [ "$steam_user" = "anonymous" ]; then
        printf '%s\n' "+login anonymous"
        return
    fi

    if [ -z "$steam_pass" ]; then
        fail "STEAM_PASS is required when STEAM_USER is not anonymous"
    fi

    if [ -n "$steam_guard" ]; then
        printf '%s\n' "+set_steam_guard_code $steam_guard"
    fi

    printf '%s\n' "+login $steam_user $steam_pass"
}

build_app_update_args() {
    local cmd="+app_update $app_id"

    if [ "$validate" = "1" ]; then
        cmd="$cmd validate"
    fi

    printf '%s\n' "$cmd"
}

append_steamcmd_args() {
    local -n target_ref="$1"

    while IFS= read -r arg; do
        target_ref+=("$arg")
    done < <(build_login_args)

    while IFS= read -r arg; do
        target_ref+=("$arg")
    done < <(build_app_update_args)
}

execute_steamcmd_command() {
    local -a cmd=("$@")

    if "${cmd[@]}"; then
        return
    fi

    local status=$?
    if [ "$steam_user" = "anonymous" ]; then
        fail "steamcmd could not install app $app_id with anonymous login. Re-run with STEAM_USER and STEAM_PASS if anonymous access is blocked for your environment."
    fi

    exit "$status"
}

run_steamcmd_local() {
    install_steamcmd
    require_steamcmd_runtime

    mkdir -p "$server_dir"

    local cmd=(
        "$steamcmd_bin"
        +force_install_dir "$server_dir"
    )

    append_steamcmd_args cmd
    cmd+=(+quit)

    log "Downloading 7 Days to Die dedicated server into $server_dir with local steamcmd"
    execute_steamcmd_command "${cmd[@]}"
}

run_steamcmd_docker() {
    can_use_container_runtime || fail "Docker runtime '$container_runtime' is not available"

    mkdir -p "$server_dir" "$steam_state_dir"

    local cmd=(
        "$container_runtime" run --rm
        --entrypoint bash
        -v "$server_dir:/mnt/server"
        -v "$steam_state_dir:/mnt/steam"
        -e "APP_ID=$app_id"
        -e "HOST_UID=$(id -u)"
        -e "HOST_GID=$(id -g)"
        -e "VALIDATE=$validate"
        -e "STEAMCMD_URL=$steamcmd_url"
    )

    if [ "$steam_user" != "anonymous" ]; then
        cmd+=(-e "STEAM_USER=$steam_user" -e "STEAM_PASS=$steam_pass")
    fi

    if [ -n "$steam_guard" ]; then
        cmd+=(-e "STEAM_AUTH=$steam_guard")
    fi

    cmd+=(
        "$docker_image"
        -lc
        "set -euo pipefail
        needs_steamcmd_deps=0
        if ! command -v curl >/dev/null 2>&1 || ! command -v tar >/dev/null 2>&1; then
            needs_steamcmd_deps=1
        fi
        if [ ! -e /lib/ld-linux.so.2 ] && [ ! -e /lib32/ld-linux.so.2 ] && [ ! -e /lib/i386-linux-gnu/ld-linux.so.2 ]; then
            needs_steamcmd_deps=1
        fi
        if [ \"\$needs_steamcmd_deps\" -eq 1 ]; then
            if ! command -v apt-get >/dev/null 2>&1; then
                echo \"Container image is missing required SteamCMD dependencies and does not provide apt-get\" >&2
                exit 1
            fi
            export DEBIAN_FRONTEND=noninteractive
            apt-get update
            apt-get install -y --no-install-recommends ca-certificates curl tar lib32gcc-s1 lib32stdc++6
            rm -rf /var/lib/apt/lists/*
        fi
        if command -v steamcmd >/dev/null 2>&1; then
            steamcmd_bin=\$(command -v steamcmd)
        elif [ -x /home/steam/steamcmd/steamcmd.sh ]; then
            steamcmd_bin=/home/steam/steamcmd/steamcmd.sh
        elif [ -x /steamcmd/steamcmd.sh ]; then
            steamcmd_bin=/steamcmd/steamcmd.sh
        else
            cd /tmp
            mkdir -p steamcmd-bootstrap
            curl -fsSL -o steamcmd.tar.gz \"\$STEAMCMD_URL\"
            tar -xzf steamcmd.tar.gz -C steamcmd-bootstrap
            steamcmd_bin=/tmp/steamcmd-bootstrap/steamcmd.sh
        fi
        if [[ \"\${STEAM_USER:-}\" == \"\" ]] || [[ \"\${STEAM_PASS:-}\" == \"\" ]]; then
            STEAM_USER=anonymous
            STEAM_PASS=
            STEAM_AUTH=
        fi
        mkdir -p /mnt/server/steamapps
        mkdir -p /mnt/steam
        chown -R root:root /mnt
        export HOME=/mnt/steam
        cmd=(\"\$steamcmd_bin\" +force_install_dir /mnt/server)
        if [[ \"\${STEAM_USER:-anonymous}\" == \"anonymous\" ]]; then
            cmd+=(+login anonymous)
        else
            if [[ -z \"\${STEAM_PASS:-}\" ]]; then
                echo \"STEAM_PASS is required when STEAM_USER is not anonymous\" >&2
                exit 1
            fi
            if [[ -n \"\${STEAM_AUTH:-}\" ]]; then
                cmd+=(+set_steam_guard_code \"\$STEAM_AUTH\")
            fi
            cmd+=(+login \"\$STEAM_USER\" \"\$STEAM_PASS\")
        fi
        cmd+=(+app_update \"$APP_ID\")
        if [[ \"\${VALIDATE:-0}\" == \"1\" ]]; then
            cmd+=(validate)
        fi
        cmd+=(+quit)
        \"\${cmd[@]}\"
        chown -R \"\$HOST_UID:\$HOST_GID\" /mnt/server /mnt/steam"
    )

    log "Downloading 7 Days to Die dedicated server into $server_dir with $container_runtime image $docker_image"
    execute_steamcmd_command "${cmd[@]}"
}

run_steamcmd() {
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
                install_steamcmd
                require_steamcmd_runtime
            fi
            ;;
        *)
            fail "Unsupported STEAMCMD_MODE: $steamcmd_mode (expected auto, local, or docker)"
            ;;
    esac
}

copy_dependency() {
    local source_path="$1"
    local target_path="$2"

    if [ ! -f "$source_path" ]; then
        fail "Expected dependency not found: $source_path"
    fi

    cp "$source_path" "$target_path"
}

main() {
    mkdir -p "$server_dir" "$deps_dir"
    run_steamcmd

    log "Copying required build DLLs into $deps_dir"
    copy_dependency "$server_dir/Mods/0_TFP_Harmony/0Harmony.dll" "$deps_dir/0Harmony.dll"
    copy_dependency "$server_dir/7DaysToDieServer_Data/Managed/Assembly-CSharp.dll" "$deps_dir/Assembly-CSharp.dll"
    copy_dependency "$server_dir/7DaysToDieServer_Data/Managed/LogLibrary.dll" "$deps_dir/LogLibrary.dll"
    copy_dependency "$server_dir/7DaysToDieServer_Data/Managed/UnityEngine.dll" "$deps_dir/UnityEngine.dll"
    copy_dependency "$server_dir/7DaysToDieServer_Data/Managed/UnityEngine.CoreModule.dll" "$deps_dir/UnityEngine.CoreModule.dll"

    log "Done. Dependencies available in $deps_dir"
}

main "$@"
