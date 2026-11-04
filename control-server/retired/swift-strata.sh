#!/bin/sh
# Alias kept for the control server's /swift endpoint: same start as start-swift.sh.
exec "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/start-swift.sh"
