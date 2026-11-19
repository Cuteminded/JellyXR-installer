#!/usr/bin/env bash
set -Eeuo pipefail

REPOSITORY=Cuteminded/JellyXR
ACTION=""
DOWNLOAD_FILE=""
LAUNCHER_FILE=""
ICON_DOWNLOAD=""
PROGRESS_PID=""

cleanup() {
    if [[ -n "$PROGRESS_PID" ]]; then
        kill "$PROGRESS_PID" 2>/dev/null || true
        wait "$PROGRESS_PID" 2>/dev/null || true
        PROGRESS_PID=""
    fi
    [[ -z "$DOWNLOAD_FILE" ]] || rm -f -- "$DOWNLOAD_FILE"
    [[ -z "$LAUNCHER_FILE" ]] || rm -f -- "$LAUNCHER_FILE"
    [[ -z "$ICON_DOWNLOAD" ]] || rm -f -- "$ICON_DOWNLOAD"
    return 0
}

notify() {
    printf '%s\n' "$2"
    zenity "--$1" --title="JellyXR installer" --width=520 --no-markup --text="$2" || true
}

fail() {
    cleanup
    notify error "$1" >&2
    exit 1
}

detect_architecture() {
    case "$(uname -m)" in
        x86_64|amd64) printf 'x86_64\n' ;;
        aarch64|arm64) printf 'arm64\n' ;;
        *) fail "Unsupported architecture. JellyXR requires x86_64 or ARM64 Linux." ;;
    esac
}

applications_directory() {
    local directory
    for directory in "$HOME/Applications" "$HOME/applications"; do
        if [[ -f "$directory/$APPIMAGE_NAME" || -f "$directory/JellyXR.AppImage" ]]; then
            printf '%s\n' "$directory"
            return
        fi
    done
    for directory in "$HOME/Applications" "$HOME/applications"; do
        if [[ -d "$directory" ]]; then
            printf '%s\n' "$directory"
            return
        fi
    done
    printf '%s\n' "$HOME/Applications"
}

choose_action() {
    local selection
    local options=(TRUE "Install or update" "Download the latest stable release")
    if [[ -f "$APPIMAGE" || -f "$LEGACY_APPIMAGE" ]]; then
        options+=(FALSE "Uninstall" "Remove JellyXR")
    fi
    selection=$(zenity --list --radiolist --title="JellyXR installer" --width=650 --height=360 --text="Choose what to do." --column="Select" --column="Action" --column="Description" "${options[@]}") || return 0
    case "$selection" in
        "Install or update") ACTION=install ;;
        Uninstall) ACTION=uninstall ;;
    esac
}

fetch() {
    curl --fail --location --silent --show-error --retry 2 --connect-timeout 15 --max-time 900 --proto '=https' --proto-redir '=https' --user-agent JellyXR-installer "$@"
}

find_release() {
    local release asset
    release=$(fetch "https://api.github.com/repos/$REPOSITORY/releases/latest")
    VERSION=$(jq -er '.tag_name | select(type == "string" and length > 0)' <<< "$release")
    asset=$(jq -ec --arg name "$APPIMAGE_NAME" 'first(.assets[] | select(.name == $name)) // empty' <<< "$release") || fail "The latest JellyXR release does not contain a build for $ARCHITECTURE."
    DOWNLOAD_URL=$(jq -er '.browser_download_url' <<< "$asset")
    DIGEST=$(jq -er '.digest | select(type == "string")' <<< "$asset") || fail "GitHub did not provide a checksum for this build."
    DOWNLOAD_SIZE=$(jq -er '.size | select(type == "number" and . > 0 and . == floor)' <<< "$asset")
    [[ "$DOWNLOAD_URL" == "https://github.com/$REPOSITORY/releases/download/"* ]] || fail "GitHub returned an unexpected download address."
    [[ "$DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]] || fail "GitHub returned an invalid checksum."
}

verify_download() {
    local actual_size actual_digest
    actual_size=$(stat -c %s -- "$DOWNLOAD_FILE")
    [[ "$actual_size" -eq "$DOWNLOAD_SIZE" ]] || fail "The download is incomplete. The existing app was kept."
    actual_digest=$(sha256sum "$DOWNLOAD_FILE")
    actual_digest=${actual_digest%% *}
    [[ "sha256:$actual_digest" == "$DIGEST" ]] || fail "The download checksum does not match. The existing app was kept."
}

write_launcher() {
    mkdir -p -- "$DATA_DIRECTORY/applications" "$DATA_DIRECTORY/jellyXR"
    ICON_DOWNLOAD=$(mktemp "$DATA_DIRECTORY/jellyXR/.jellyxr-XXXXXX")
    fetch "https://raw.githubusercontent.com/$REPOSITORY/master/assets/logo/jellyxr-logo-transparent-crop.png" --output "$ICON_DOWNLOAD"
    chmod 644 "$ICON_DOWNLOAD"
    mv -f -- "$ICON_DOWNLOAD" "$ICON"
    ICON_DOWNLOAD=""
    LAUNCHER_FILE=$(mktemp "$DATA_DIRECTORY/applications/.jellyxr-XXXXXX")
    cat > "$LAUNCHER_FILE" <<EOF
[Desktop Entry]
Type=Application
Name=JellyXR
Comment=Watch your Jellyfin movies and shows in VR
Exec=$APPIMAGE
Icon=$ICON
Terminal=false
Categories=AudioVideo;Video;
StartupNotify=false
EOF
    chmod 644 "$LAUNCHER_FILE"
    mv -f -- "$LAUNCHER_FILE" "$LAUNCHER"
    LAUNCHER_FILE=""
}

refresh_menu() {
    if command -v update-desktop-database >/dev/null 2>&1; then
        update-desktop-database "$DATA_DIRECTORY/applications" >/dev/null 2>&1 || true
    fi
}

download_progress() {
    trap - ERR EXIT INT TERM
    local downloaded percentage
    printf '0\n'
    while [[ -f "$1" ]]; do
        downloaded=$(stat -c %s -- "$1" 2>/dev/null) || downloaded=0
        percentage=$((downloaded * 95 / $2))
        if (( percentage >= 95 )); then
            printf '95\n# Checking the download...\n'
        else
            printf '%s\n# Downloading JellyXR v%s\n' "$percentage" "${VERSION#v}"
        fi
        sleep 0.2
    done
    printf '100\n'
}

install_app() {
    find_release
    mkdir -p -- "$APP_DIRECTORY"
    DOWNLOAD_FILE=$(mktemp "$APP_DIRECTORY/.jellyxr-download-XXXXXX")
    printf 'Downloading JellyXR %s...\n' "$VERSION"
    zenity --progress --percentage=0 --auto-close --no-cancel --title="Installing JellyXR $VERSION" --width=520 --text="Downloading JellyXR ${VERSION#v}" < <(download_progress "$DOWNLOAD_FILE" "$DOWNLOAD_SIZE") &
    PROGRESS_PID=$!
    fetch "$DOWNLOAD_URL" --output "$DOWNLOAD_FILE"
    verify_download
    chmod 755 "$DOWNLOAD_FILE"
    mv -f -- "$DOWNLOAD_FILE" "$APPIMAGE"
    DOWNLOAD_FILE=""
    write_launcher
    rm -f -- "$LEGACY_APPIMAGE"
    refresh_menu
    wait "$PROGRESS_PID" || true
    PROGRESS_PID=""
    notify info "JellyXR $VERSION is installed."
}

uninstall_app() {
    zenity --question --title="JellyXR installer" --text="Remove JellyXR and its launcher?" || return 0
    rm -f -- "$APPIMAGE" "$LEGACY_APPIMAGE" "$LAUNCHER" "$ICON"
    refresh_menu
    notify info "JellyXR was removed."
}

main() {
    trap cleanup EXIT
    trap 'fail "Installation failed near line $LINENO. Check the terminal output and try again."' ERR
    trap 'exit 130' INT
    trap 'exit 143' TERM
    [[ "$(uname -s)" == Linux ]] || fail "This installer supports Linux and SteamOS only."
    [[ "$EUID" -ne 0 ]] || fail "Run this installer as your normal user, without sudo."
    local dependency
    for dependency in zenity flock; do
        command -v "$dependency" >/dev/null 2>&1 || fail "Required command not found: $dependency"
    done
    ARCHITECTURE=$(detect_architecture)
    APPIMAGE_NAME="JellyXR-linux-$ARCHITECTURE.AppImage"
    APP_DIRECTORY=$(applications_directory)
    APPIMAGE="$APP_DIRECTORY/$APPIMAGE_NAME"
    LEGACY_APPIMAGE="$APP_DIRECTORY/JellyXR.AppImage"
    DATA_DIRECTORY=${XDG_DATA_HOME:-"$HOME/.local/share"}
    [[ "$DATA_DIRECTORY" == /* ]] || DATA_DIRECTORY="$HOME/.local/share"
    [[ "$APP_DIRECTORY$DATA_DIRECTORY" != *$'\n'* && "$APP_DIRECTORY$DATA_DIRECTORY" != *$'\r'* ]] || fail "The installation path contains unsupported control characters."
    LAUNCHER="$DATA_DIRECTORY/applications/jellyxr.desktop"
    ICON="$DATA_DIRECTORY/jellyXR/jellyxr.png"
    choose_action
    [[ -n "$ACTION" ]] || return 0
    mkdir -p -- "$DATA_DIRECTORY"
    exec 9> "$DATA_DIRECTORY/.jellyxr-installer.lock"
    flock -n 9 || fail "Another JellyXR installer is already running."
    if [[ "$ACTION" == uninstall ]]; then
        uninstall_app
    else
        for dependency in curl jq sha256sum stat; do
            command -v "$dependency" >/dev/null 2>&1 || fail "Required command not found: $dependency"
        done
        install_app
    fi
}

main
