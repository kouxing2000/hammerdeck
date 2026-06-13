#!/usr/bin/env bash
# Stop then rebuild + relaunch Hammerdeck (the usual after a code change). See app.sh.
exec "$(dirname "${BASH_SOURCE[0]}")/app.sh" restart "$@"
