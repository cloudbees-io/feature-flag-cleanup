#!/bin/sh
# Runs the unify-commit tests in a Linux container (the argument-size limit being tested is Linux-specific).
set -eu
REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
docker run --rm -v "$REPO_ROOT":/src:ro alpine:3.24 sh -c \
    'apk add --no-cache -q bash jq curl git python3 && bash /src/actions/unify-commit/test/test.sh'
