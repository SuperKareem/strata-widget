#!/bin/sh
# Print the downloaded model ids in Strata-data/models. A model is complete when every
# non-marker file in its folder has a matching "<file>.done"; folders with no files are
# skipped, as are loose top-level files such as mmproj.
#   ./list-models.sh                     human-readable table
#   ./list-models.sh --ids               "id<TAB>state" per model (for the /models endpoint)
#   ./list-models.sh [path-to-Strata-data]
# The discovered Strata-data path is cached in ~/.strata-data-path (override with
# STRATA_DATA_CACHE) so the search runs once; a missing or stale cache re-searches.
set -u

IDS=0
ROOT=
for arg in "$@"; do
    case "$arg" in
        --ids) IDS=1 ;;
        *) ROOT="$arg" ;;
    esac
done
if [ -z "$ROOT" ]; then
    CACHE=${STRATA_DATA_CACHE:-$HOME/.strata-data-path}
    if [ -f "$CACHE" ] && [ -d "$(cat "$CACHE" 2>/dev/null)" ]; then
        ROOT=$(cat "$CACHE")
    else
        ROOT=$(find "$HOME" -maxdepth 4 -type d -name 'Strata-data' 2>/dev/null | head -1)
        if [ -z "$ROOT" ]; then
            echo "no Strata-data folder found under $HOME (max depth 4) - pass its path as an argument"
            exit 1
        fi
        printf '%s\n' "$ROOT" > "$CACHE" || echo "warning: could not write cache $CACHE" >&2
    fi
fi
[ -d "$ROOT" ] || { echo "not a directory: $ROOT"; exit 1; }

MODELS="$ROOT/models"
[ -d "$MODELS" ] || { echo "no models/ under $ROOT"; exit 1; }

if [ "$IDS" -eq 0 ]; then
    echo "Strata-data: $ROOT"
    printf '%-22s %-10s %s\n' "MODEL ID" "STATE" "DETAIL"
fi

for dir in "$MODELS"/*/; do
    name=$(basename "$dir")
    case "$name" in .*) continue ;; esac

    total=0
    missing=0
    size=0
    for f in "$dir"*; do
        [ -f "$f" ] || continue
        case "$f" in *.done) continue ;; esac
        total=$((total + 1))
        [ -f "$f.done" ] || missing=$((missing + 1))
        size=$((size + $(wc -c < "$f")))
    done

    [ "$total" -gt 0 ] || continue
    state=DONE
    [ "$missing" -eq 0 ] || state=PARTIAL

    if [ "$IDS" -eq 1 ]; then
        printf '%s\t%s\n' "$name" "$state"
    else
        gib=$(awk -v b="$size" 'BEGIN {printf "%.1f GiB", b / 1073741824}')
        if [ "$missing" -eq 0 ]; then
            printf '%-22s %-10s %s\n' "$name" "$state" "$total file(s), $gib"
        else
            printf '%-22s %-10s %s\n' "$name" "$state" "$missing of $total file(s) lack .done, $gib"
        fi
    fi
done
