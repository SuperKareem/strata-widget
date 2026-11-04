#!/bin/sh
# Manual alias for starting Gyro-M: same as gyro-Gyro-M.sh.
exec "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/gyro-Gyro-M.sh"
