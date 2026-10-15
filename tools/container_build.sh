#!/usr/bin/env bash
# Thin shim: the build is Python now (tools/build.py).
#
# A shell launcher was where the incidents lived -- a SIGHUP to it killed the fits
# still running under it and lost the artifacts, and `>/dev/null` hid the error that
# explained a failure. tools/build.py starts its children in their own session, keeps
# every line of output, and prints one verdict with one exit code. This path is kept so
# existing docs and habits still work.
exec python3 "$(cd "$(dirname "$0")" && pwd)/build.py" "$@"
