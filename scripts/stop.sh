#!/usr/bin/env bash
# Gracefully stop the running Hammerdeck. See app.sh.
exec "$(dirname "${BASH_SOURCE[0]}")/app.sh" stop
