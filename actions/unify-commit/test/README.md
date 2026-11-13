# unify-commit tests

Tests for the script embedded in `../action.yaml`, which creates a verified commit using the GitHub REST API.

## Running

```sh
actions/unify-commit/test/run.sh
```

This needs Docker. It runs `test.sh` in an `alpine` container with the repository mounted read-only. A Linux container
is used because the bug these tests guard against (a staged file whose base64 content exceeds the 128 KiB single
command-line argument limit) is Linux-specific. The tests are also run by CI on every push and pull request to `main`
(`.cloudbees/workflows/unify-commit-tests.yaml`).

To test a different version of the action, set `ACTION_YAML` to the path of its `action.yaml` as seen inside the
container. For example, to confirm the tests fail against an older revision:

```sh
git show <revision>:actions/unify-commit/action.yaml > /tmp/old/action.yaml
docker run --rm -v "$PWD":/src:ro -v /tmp/old:/old:ro -e ACTION_YAML=/old/action.yaml alpine:3.24 sh -c \
    'apk add --no-cache -q bash jq curl git python3 && bash /src/actions/unify-commit/test/test.sh'
```

## How they work

`test.sh` extracts the script from the `action.yaml`, points it at a local mock API instead of `https://api.github.com`,
and runs it against throwaway git repositories. `mock_github.py` implements the handful of Git Data API endpoints the
script uses (blobs, trees, commits and refs) on top of a real bare git repository, so the hashes it returns are real.
The tests can therefore compare the committed tree with the staged tree, which checks contents, file modes and paths
byte-for-byte.

The mock is deliberately lenient: it checks that the script builds correct requests and preserves content, not that
GitHub would accept them. It does not enforce GitHub's validation, rate limits or request size limits, and it cannot show
that commits are signed or verified, which GitHub does server-side. Confirm those with a run against the real service.

Scenarios:

1. Files of 95 KiB, 96 KiB, 100 KiB, 1 MiB and 20 MiB, a binary file, an empty file, an executable file, a modified
   file, a deletion and a rename are committed exactly as staged.
2. 1,200 files produce a tree request over 128 KiB, which is also committed exactly as staged.
3. An API failure exits non-zero and reports the failing stage and GitHub's response.
