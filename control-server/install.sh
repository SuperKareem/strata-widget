#!/bin/sh
# Install the strata control server in this folder: port, Strata-data path, boot,
# and the script each model endpoint runs.
#
#   ./install.sh
#
# Asks, in order: operating port (default 8090), Strata-data folder path
# (empty = search under $HOME), run on boot (default y). It then prints every
# /<model-id> endpoint next to the script it runs and asks, per model, whether
# that script path should point somewhere else; the answers are the defaults
# unless you type a path.
#
# Files it writes (all read back by server.js, nothing is edited inside it):
#   server.port          the port; absent means 8090
#   model-scripts.txt    "id<TAB>script" lines, only for models you repointed
#   $HOME/.strata-data-path (or $STRATA_DATA_CACHE) the folder path cache list-models.sh reads
#   $HOME/.config/systemd/user/strata-start-stop.service  when boot is yes
# Set DRY=1 to preview every write this script makes (config files, unit file,
# systemctl calls) instead of doing them. list-models.sh still refreshes its own
# path cache when a search runs.
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
LIST="$HERE/list-models.sh"
CACHE=${STRATA_DATA_CACHE:-$HOME/.strata-data-path}
UNIT=strata-start-stop.service
UNITFILE="$HOME/.config/systemd/user/$UNIT"
DRY=${DRY:-0}

run() {
    if [ "$DRY" = 1 ]; then
        printf 'dry-run: %s\n' "$*"
        return 0
    fi
    "$@"
}

# to <path>: stdin becomes the file; under DRY the content is printed instead.
to() {
    if [ "$DRY" = 1 ]; then
        printf 'dry-run: write %s\n' "$1"
        sed 's/^/  | /'
        return 0
    fi
    cat > "$1"
}

ask() {
    printf '%s [%s]: ' "$1" "$2"
    read -r ANSWER
    [ -n "$ANSWER" ] || ANSWER="$2"
}

# --- port -------------------------------------------------------------------
ask "Operating port" 8090
PORT="$ANSWER"
case "$PORT" in
    '' | *[!0-9]*) echo "not a number: $PORT - using 8090"; PORT=8090 ;;
esac
if [ "$PORT" -lt 1024 ] || [ "$PORT" -gt 65535 ]; then
    echo "port out of range (1024-65535) - using 8090"
    PORT=8090
fi

printf '%s\n' "$PORT" | to "$HERE/server.port"
if [ "$DRY" != 1 ]; then
    printf 'port written to %s (delete it to fall back to 8090)\n' "$HERE/server.port"
fi

# --- Strata-data folder -----------------------------------------------------
ask "Strata-data folder path (empty = search under \$HOME)" ""
if [ -n "$ANSWER" ]; then
    [ -d "$ANSWER" ] || { echo "not a directory: $ANSWER"; exit 1; }
    ROOT=$(CDPATH= cd -- "$ANSWER" && pwd)
    printf '%s\n' "$ROOT" | to "$CACHE"
    if [ "$DRY" != 1 ]; then
        printf 'cache written: %s -> %s\n' "$CACHE" "$ROOT"
    fi
else
    run rm -f "$CACHE"
    if ! sh "$LIST" >/dev/null; then
        echo "list-models.sh could not find the folder - pass its path to install.sh next time"
        exit 1
    fi
    ROOT=$(cat "$CACHE" 2>/dev/null)
    printf 'found: %s (cached in %s)\n' "$ROOT" "$CACHE"
fi

IDS=$(sh "$LIST" --ids)
if [ -z "$IDS" ]; then
    echo "no models under $ROOT/models"
    exit 1
fi

# --- endpoints, one per model -----------------------------------------------
printf 'endpoints on :%s\n' "$PORT"
REST="$IDS"
OVERRIDE=
while [ -n "$REST" ]; do
    line=$(printf '%s\n' "$REST" | head -1)
    REST=$(printf '%s\n' "$REST" | tail -n +2)
    [ -n "$line" ] || continue
    id=$(printf '%s' "$line" | cut -f1)
    state=$(printf '%s' "$line" | cut -f2)
    default="$HERE/$id.sh"
    printf '  /%s  %-8s %s\n' "$id" "$state" "$default"

    printf 'script for /%s (empty = keep %s): ' "$id" "$default"
    read -r ANSWER
    printf '\n'
    [ -n "$ANSWER" ] || continue
    [ -f "$ANSWER" ] || { echo "  no such file - keeping $default"; continue; }
    [ -x "$ANSWER" ] || { echo "  not executable - keeping $default"; continue; }
    SCRIPT_PATH=$(CDPATH= cd -- "$(dirname -- "$ANSWER")" && pwd)/"$(basename -- "$ANSWER")"
    OVERRIDE="${OVERRIDE}${id}$(printf '\t')${SCRIPT_PATH}
"
    printf '  /%s now runs %s\n' "$id" "$SCRIPT_PATH"
done
if printf '%s' "$OVERRIDE" | grep -q .; then
    printf '%s' "$OVERRIDE" | to "$HERE/model-scripts.txt"
else
    [ -f "$HERE/model-scripts.txt" ] &&
        echo "no repoint answers - every endpoint runs <id>.sh again; model-scripts.txt removed"
    run rm -f "$HERE/model-scripts.txt"
fi

# --- boot -------------------------------------------------------------------
ask "Make the server run on boot? (y/n)" y
BOOT="$ANSWER"
case "$BOOT" in
    [Yy]*)
        if [ -z "$(command -v systemctl 2>/dev/null)" ]; then
            echo "no systemctl here - start the server yourself, or copy a unit file manually"
        else
            run mkdir -p "$(dirname -- "$UNITFILE")"
            {
                echo "[Unit]"
                echo "Description=Strata control server (:$PORT)"
                echo
                echo "[Service]"
                echo "WorkingDirectory=$HERE"
                echo "ExecStart=$(command -v node) server.js"
                echo
                echo "[Install]"
                echo "WantedBy=default.target"
            } | to "$UNITFILE"
            run systemctl --user daemon-reload
            run systemctl --user enable "$UNIT"
            run systemctl --user restart "$UNIT"
        fi
        ;;
    *)
        echo "boot left off; the server only runs while you start it yourself"
        if [ -z "$(command -v systemctl 2>/dev/null)" ]; then
            echo "no systemctl here - nothing to disable"
        else
            run systemctl --user disable "$UNIT"
        fi
        ;;
esac

# --- summary ----------------------------------------------------------------
printf '\nport          %s\n' "$PORT"
printf 'Strata-data   %s\n' "$ROOT"
printf 'boot          %s\n' "$BOOT"
printf 'endpoints     /stop /status /models /start /coder-IQ1_M-prebuilt\n'
printf '%s\n' "$IDS" | while IFS="$(printf '\t')" read -r id state; do
    [ -n "$id" ] || continue
    script=$(printf '%s' "$OVERRIDE" | grep "^$(printf '%s\t' "$id")" | cut -f2)
    printf '              /%s -> %s\n' "$id" "${script:-$HERE/$id.sh}"
done
printf 'try           curl http://localhost:%s/models\n' "$PORT"
if [ "$DRY" = 1 ]; then
    printf '(dry-run: nothing was started, unit file only printed)\n'
fi
