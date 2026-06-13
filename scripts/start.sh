#!/usr/bin/env bash
# Rebuild + launch Hammerdeck in the background. See app.sh.
exec "$(dirname "${BASH_SOURCE[0]}")/app.sh" start "$@"
