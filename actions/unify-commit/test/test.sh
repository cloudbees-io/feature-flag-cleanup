#!/bin/bash
# Runs the unify-commit script against a mock GitHub API. Intended to run inside a Linux container: see run.sh.
set -euo pipefail

ACTION_YAML="${ACTION_YAML:-/src/actions/unify-commit/action.yaml}"
HERE="$(cd "$(dirname "$0")" && pwd)"
PORT=8099
ROOT=$(mktemp -d)
cd "$ROOT"
git config --global gc.auto 0
git config --global maintenance.auto false

# Extract the embedded script, un-indent it and point it at the mock API.
sed -n "/<< 'BASH_EOF'/,/^ *BASH_EOF\$/p" "$ACTION_YAML" | sed '1d;$d' | sed 's/^        //' \
    | sed "s#https://api.github.com#http://127.0.0.1:$PORT#" > "$ROOT/commit.sh"

git init -q --bare -b main "$ROOT/remote.git"
python3 -I "$HERE/mock_github.py" "$PORT" "$ROOT/remote.git" "$ROOT/mock.log" &
MOCK_PID=$!
trap 'kill $MOCK_PID 2>/dev/null; rm -rf "$ROOT"' EXIT
for _ in $(seq 50); do curl -s "http://127.0.0.1:$PORT/" > /dev/null && break; sleep 0.1; done

# Fresh working repo with a base commit, pushed to the bare "remote" that the mock API serves.
new_repo() {
    cd "$ROOT"
    rm -rf "$ROOT/work" "$ROOT/remote.git/refs/heads/main"
    git init -q -b main "$ROOT/work"
    cd "$ROOT/work"
    git config user.name test && git config user.email test@example.com
    git config url."$ROOT/remote.git".insteadOf https://github.com/o/r.git
    git remote add origin https://github.com/o/r.git
    echo base > modify.txt; echo gone > delete.txt; echo moved > rename_old.txt
    printf '#!/bin/sh\n' > tool.sh; chmod +x tool.sh
    git add -A && git commit -q -m base
    git push -q "$ROOT/remote.git" main
    : > "$ROOT/mock.log"
}

run_action() {
    GH_TOKEN=dummy COMMIT_MESSAGE="${1:-test commit}" bash "$ROOT/commit.sh"
}

fail() { echo "FAIL: $*" >&2; exit 1; }

echo "=== Scenario 1: files around and above the 128 KiB argument limit, binary, mode, delete, rename"
new_repo
mkdir -p "sub dir"
# Sizes are raw file bytes. 98304 is the exact boundary (base64 of 96 KiB is 131072 bytes, over the limit).
for kib in 95 96 100 1024 20480; do
    head -c $((kib * 1024)) /dev/urandom | base64 > "sub dir/text_${kib}k.txt"
done
head -c 300000 /dev/urandom > binary.bin
head -c 200000 /dev/urandom | base64 > modify.txt
: > empty.txt
printf '#!/bin/sh\necho hi\n' > new_tool.sh
git rm -q delete.txt
git mv rename_old.txt rename_new.txt
git add -A
chmod +x new_tool.sh; git update-index --chmod=+x new_tool.sh
EXPECTED_TREE=$(git write-tree)
run_action "scenario 1 message"
[ "$(git rev-parse 'HEAD^{tree}')" = "$EXPECTED_TREE" ] || fail "committed tree differs from staged tree"
[ "$(git rev-parse HEAD)" = "$(git --git-dir="$ROOT/remote.git" rev-parse main)" ] || fail "remote branch not updated"
[ "$(git log -1 --format=%s)" = "scenario 1 message" ] || fail "commit message"
git diff --cached --quiet && git diff --quiet || fail "working tree/index not clean after commit"
echo "OK"

echo "=== Scenario 2: tree request larger than 128 KiB"
new_repo
mkdir deep
for i in $(seq 1200); do
    f="deep/$(printf 'a_long_file_name_to_inflate_the_tree_payload_%080d' "$i").txt"
    echo "$i" > "$f"
done
git add -A
EXPECTED_TREE=$(git write-tree)
run_action "scenario 2 message" > /dev/null
[ "$(git rev-parse 'HEAD^{tree}')" = "$EXPECTED_TREE" ] || fail "committed tree differs from staged tree"
BYTES=$(awk '/^tree_request_bytes/ {print $2}' "$ROOT/mock.log")
[ "$BYTES" -gt 131072 ] || fail "tree request was only $BYTES bytes; scenario does not exceed the limit"
echo "OK (tree request: $BYTES bytes)"

echo "=== Scenario 3: API failure reports the failing stage and exits non-zero"
new_repo
echo FAIL_BLOB > bad.txt
git add -A
if OUT=$(run_action 2>&1); then fail "expected failure"; fi
echo "$OUT" | grep -q "failed while creating the blob for bad.txt" || fail "stage not reported: $OUT"
echo "$OUT" | grep -q "Validation Failed" || fail "API response not shown: $OUT"
echo "OK"

echo "All scenarios passed"
