#!/usr/bin/env bash
#
# Tests for android/scripts/setup-termux-signing.sh.
# Uses a synthetic keystore and a mock gh; no real credentials or network.

set -uo pipefail

HERE=$(cd -- "$(dirname -- "$0")" && pwd)
SCRIPT="$HERE/../setup-termux-signing.sh"
ROOT=$(mktemp -d)
trap 'rm -rf -- "$ROOT"' EXIT

PASS=0
FAIL=0
CURRENT=""
STATUS=0
OUT=""
OUTDIR=""
CAPTURE=""
SETUP_CWD=""
SETUP_STDIN_FILE=""
SETUP_SCRIPT_ARGS=()

ok() { PASS=$((PASS + 1)); }
bad() {
  FAIL=$((FAIL + 1))
  printf 'FAIL [%s]: %s\n' "$CURRENT" "$1" >&2
  if [ -n "$OUT" ]; then
    printf '%s\n' "$OUT" >&2
  fi
}
check_status() {
  if [ "$STATUS" -eq "$1" ]; then ok; else bad "expected exit $1, got $STATUS"; fi
}
check_contains() {
  case "$OUT" in
    *"$1"*) ok ;;
    *) bad "output does not contain: $1" ;;
  esac
}
check_not_contains() {
  case "$OUT" in
    *"$1"*) bad "output unexpectedly contains: $1" ;;
    *) ok ;;
  esac
}
check_file() {
  if [ -f "$1" ]; then ok; else bad "missing file: $1"; fi
}
check_no_file() {
  if [ -e "$1" ]; then bad "unexpected file: $1"; else ok; fi
}
check_secret_equals() {
  local name="$1"
  local expected="$2"
  local actual_file="$CAPTURE/secret_$name"
  if [ ! -f "$actual_file" ]; then
    bad "secret $name was not uploaded"
    return
  fi
  if [ "$(cat "$actual_file")" = "$expected" ]; then
    ok
  else
    bad "secret $name has the wrong value"
  fi
}

b64_file() {
  base64 <"$1" | tr -d '\r\n'
}

KEYS="$ROOT/keys"
mkdir -p "$KEYS"
KEYSTORE="$KEYS/melo-release.jks"
STORE_PASS='synthetic-store-pass'
KEY_PASS='synthetic-key-pass'
ALIAS='melo-test'

make_keystore() {
  local path="$1"
  mkdir -p "$(dirname -- "$path")"
  keytool -genkeypair \
    -storetype JKS \
    -keystore "$path" \
    -storepass "$STORE_PASS" \
    -keypass "$KEY_PASS" \
    -alias "$ALIAS" \
    -keyalg RSA -keysize 2048 -validity 365 \
    -dname "CN=Melo Synthetic Test, O=Melo Test, C=US" >/dev/null 2>&1
}

if ! make_keystore "$KEYSTORE"; then
  printf 'could not create a synthetic test keystore\n' >&2
  exit 1
fi
VALID_B64=$(b64_file "$KEYSTORE")

CORRUPTED_KEYSTORE="$ROOT/corrupted.jks"
CORRUPTED_READY=0
for offset in 20 40 60; do
  cp "$KEYSTORE" "$CORRUPTED_KEYSTORE"
  printf '\000' | dd of="$CORRUPTED_KEYSTORE" bs=1 seek="$offset" count=1 conv=notrunc 2>/dev/null
  if ! cmp -s "$KEYSTORE" "$CORRUPTED_KEYSTORE"; then
    CORRUPTED_READY=1
    break
  fi
done
if [ "$CORRUPTED_READY" -ne 1 ]; then
  printf 'could not corrupt the synthetic test keystore\n' >&2
  exit 1
fi

MOCK_GH="$ROOT/mock-gh"
cat >"$MOCK_GH" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
: "${MOCK_CAPTURE_DIR:?}"
printf '%s\n' "$*" >>"$MOCK_CAPTURE_DIR/gh.log"
case "${1:-} ${2:-}" in
  "auth status")
    exit 0
    ;;
  "repo view")
    case "${MOCK_REPO_VIEW:-target}" in
      target) printf 'hakosworld-blip/melo\n' ;;
      fork) printf 'IcyShadow5/melo\n' ;;
      *) printf 'unexpected/repo\n' ;;
    esac
    exit 0
    ;;
  "secret set")
    if [ "$#" -ne 5 ] || [ "${4:-}" != "--repo" ]; then
      printf 'unexpected secret set arguments\n' >&2
      exit 2
    fi
    if [ "${MOCK_FAIL_SECRET:-}" = "${3:-}" ]; then
      printf 'mock upload failure for %s\n' "$3" >&2
      exit 1
    fi
    cat >"$MOCK_CAPTURE_DIR/secret_$3"
    exit 0
    ;;
  *)
    printf 'unexpected gh invocation: %s\n' "$*" >&2
    exit 2
    ;;
esac
EOF
chmod +x "$MOCK_GH"

UNAUTH_GH="$ROOT/unauth-gh"
cat >"$UNAUTH_GH" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-} ${2:-}" = "auth status" ]; then
  exit 1
fi
exit 2
EOF
chmod +x "$UNAUTH_GH"

run_setup() {
  local name="$1"
  shift
  CURRENT="$name"
  OUTDIR="$ROOT/$name"
  CAPTURE="$OUTDIR/mock"
  mkdir -p "$CAPTURE"
  local stdin_file="/dev/null"
  if [ -n "$SETUP_STDIN_FILE" ]; then
    stdin_file="$SETUP_STDIN_FILE"
  fi
  (
    if [ -n "$SETUP_CWD" ]; then
      cd "$SETUP_CWD" || exit 99
    fi
    env GITHUB_ACTIONS= \
      MELO_GH_BIN="$MOCK_GH" \
      MELO_ASSUME_YES=1 \
      MOCK_CAPTURE_DIR="$CAPTURE" \
      MELO_KEYSTORE_FILE="$KEYSTORE" \
      MELO_KEY_ALIAS="$ALIAS" \
      MELO_KEYSTORE_PASSWORD="$STORE_PASS" \
      MELO_KEY_PASSWORD="$KEY_PASS" \
      "$@" \
      bash "$SCRIPT" ${SETUP_SCRIPT_ARGS[@]+"${SETUP_SCRIPT_ARGS[@]}"}
  ) >"$OUTDIR/stdout" 2>"$OUTDIR/stderr" <"$stdin_file"
  STATUS=$?
  OUT=$(cat "$OUTDIR/stdout" "$OUTDIR/stderr")
}

# --- successful setup ------------------------------------------------------
run_setup success
check_status 0
check_contains "Uploaded the four signing secrets to hakosworld-blip/melo"
check_contains "Target repository: hakosworld-blip/melo"
check_contains "No release was started"
check_contains "Back up the signing key now"
check_secret_equals ANDROID_KEYSTORE_BASE64 "$VALID_B64"
check_secret_equals ANDROID_KEY_ALIAS "$ALIAS"
check_secret_equals ANDROID_KEYSTORE_PASSWORD "$STORE_PASS"
check_secret_equals ANDROID_KEY_PASSWORD "$KEY_PASS"
check_not_contains "$STORE_PASS"
check_not_contains "$KEY_PASS"
check_not_contains "$VALID_B64"

# --- redaction in gh arguments --------------------------------------------
CURRENT="success-gh-log"
GH_LOG="$CAPTURE/gh.log"
if grep -qF -- "$STORE_PASS" "$GH_LOG"; then bad "gh log contains the store password"; else ok; fi
if grep -qF -- "$KEY_PASS" "$GH_LOG"; then bad "gh log contains the key password"; else ok; fi
if grep -qF -- "$VALID_B64" "$GH_LOG"; then bad "gh log contains the Base64 payload"; else ok; fi
if grep -Eq 'workflow run|release create|git tag|git push' "$GH_LOG"; then
  bad "gh log shows a release-triggering command"
else
  ok
fi

# --- no keystore copies or plaintext secrets ------------------------------
CURRENT="success-no-copies"
extra_files=$(find "$KEYS" -maxdepth 1 -type f ! -name 'melo-release.jks' | wc -l | tr -d ' ')
if [ "$extra_files" = "0" ]; then ok; else bad "the helper created extra files next to the keystore"; fi
b64_files=$(find "$ROOT" -name '*.b64' | wc -l | tr -d ' ')
if [ "$b64_files" = "0" ]; then ok; else bad "the helper created a Base64 file"; fi

# --- idempotent rerun ------------------------------------------------------
run_setup success
check_status 0
check_secret_equals ANDROID_KEYSTORE_BASE64 "$VALID_B64"
check_secret_equals ANDROID_KEY_ALIAS "$ALIAS"
check_secret_equals ANDROID_KEYSTORE_PASSWORD "$STORE_PASS"
check_secret_equals ANDROID_KEY_PASSWORD "$KEY_PASS"

# --- interactive prompts (no credential env vars) -------------------------
SETUP_STDIN_FILE="$ROOT/answers.txt"
printf '%s\n%s\n%s\n' "$STORE_PASS" "$ALIAS" "$KEY_PASS" >"$SETUP_STDIN_FILE"
run_setup interactive \
  MELO_KEYSTORE_PASSWORD= \
  MELO_KEY_ALIAS= \
  MELO_KEY_PASSWORD=
SETUP_STDIN_FILE=""
check_status 0
check_secret_equals ANDROID_KEYSTORE_BASE64 "$VALID_B64"
check_secret_equals ANDROID_KEY_ALIAS "$ALIAS"
check_secret_equals ANDROID_KEYSTORE_PASSWORD "$STORE_PASS"
check_secret_equals ANDROID_KEY_PASSWORD "$KEY_PASS"
check_not_contains "$STORE_PASS"
check_not_contains "$KEY_PASS"

# --- empty interactive answers are rejected -------------------------------
SETUP_STDIN_FILE="$ROOT/empty-answers.txt"
printf '\n' >"$SETUP_STDIN_FILE"
run_setup empty-store-password \
  MELO_KEYSTORE_PASSWORD= \
  MELO_KEY_ALIAS="$ALIAS" \
  MELO_KEY_PASSWORD="$KEY_PASS"
check_status 1
check_contains "No keystore password was entered"

printf '\n' >"$SETUP_STDIN_FILE"
run_setup empty-alias \
  MELO_KEY_ALIAS= \
  MELO_KEY_PASSWORD="$KEY_PASS"
SETUP_STDIN_FILE=""
check_status 1
check_contains "No key alias was entered"

if [ -e "$CAPTURE/secret_ANDROID_KEYSTORE_BASE64" ]; then
  CURRENT="empty-answers-upload"
  bad "uploaded a secret after an empty answer"
else
  CURRENT="empty-answers-upload"
  ok
fi

# --- default keystore path -------------------------------------------------
DEFAULT_DIR="$ROOT/default"
make_keystore "$DEFAULT_DIR/melo-release.jks" || {
  printf 'could not create the default-path synthetic keystore\n' >&2
  exit 1
}
SETUP_CWD="$DEFAULT_DIR"
run_setup default-path MELO_KEYSTORE_FILE=
SETUP_CWD=""
check_status 0
check_secret_equals ANDROID_KEY_ALIAS "$ALIAS"

# --- ~/melo-release.jks fallback ------------------------------------------
HOME_DIR="$ROOT/fake-home"
EMPTY_CWD="$ROOT/empty-cwd"
make_keystore "$HOME_DIR/melo-release.jks" || {
  printf 'could not create the home-path synthetic keystore\n' >&2
  exit 1
}
mkdir -p "$EMPTY_CWD"
SETUP_CWD="$EMPTY_CWD"
run_setup home-path MELO_KEYSTORE_FILE= HOME="$HOME_DIR"
SETUP_CWD=""
check_status 0
check_secret_equals ANDROID_KEY_ALIAS "$ALIAS"

# --- missing keystore must not create one ---------------------------------
MISSING_DIR="$ROOT/missing"
run_setup missing-keystore MELO_KEYSTORE_FILE="$MISSING_DIR/melo-release.jks"
check_status 1
check_contains "never creates or overwrites"
check_no_file "$MISSING_DIR/melo-release.jks"
if [ -e "$CAPTURE/secret_ANDROID_KEYSTORE_BASE64" ]; then
  CURRENT="missing-keystore-upload"
  bad "uploaded a secret without a keystore"
else
  CURRENT="missing-keystore-upload"
  ok
fi

# --- wrong passwords and alias --------------------------------------------
run_setup wrong-store-password MELO_KEYSTORE_PASSWORD="wrong-store-password"
check_status 1
check_contains "could not be opened"
check_contains "may be wrong"
check_not_contains "password is incorrect"

run_setup corrupted-keystore MELO_KEYSTORE_FILE="$CORRUPTED_KEYSTORE"
check_status 1
check_contains "could not be opened"
check_contains "corrupted"

run_setup wrong-alias MELO_KEY_ALIAS="does-not-exist"
check_status 1
check_contains "was not found in the keystore"

run_setup wrong-key-password MELO_KEY_PASSWORD="wrong-key-password"
check_status 1
check_contains "does not unlock the private key"

# --- partial secret uploads ----------------------------------------------
run_setup partial-upload MOCK_FAIL_SECRET=ANDROID_KEY_PASSWORD
check_status 1
check_contains "could not upload ANDROID_KEY_PASSWORD"
check_contains "partially updated"
check_contains "ANDROID_KEYSTORE_BASE64, ANDROID_KEY_ALIAS, ANDROID_KEYSTORE_PASSWORD"
check_contains "Rerunning re-uploads all four secrets and is safe"
check_file "$CAPTURE/secret_ANDROID_KEYSTORE_PASSWORD"
check_no_file "$CAPTURE/secret_ANDROID_KEY_PASSWORD"
check_not_contains "$STORE_PASS"
check_not_contains "$KEY_PASS"
check_not_contains "$VALID_B64"

run_setup first-upload-failure MOCK_FAIL_SECRET=ANDROID_KEYSTORE_BASE64
check_status 1
check_contains "could not upload ANDROID_KEYSTORE_BASE64"
check_contains "No secret upload was confirmed"
check_contains "remote state is unknown"
check_not_contains "$STORE_PASS"
check_not_contains "$KEY_PASS"
if [ -e "$CAPTURE/secret_ANDROID_KEYSTORE_BASE64" ]; then
  CURRENT="first-upload-failure-file"
  bad "a secret was stored after the first upload failed"
else
  CURRENT="first-upload-failure-file"
  ok
fi

# --- gh availability and authentication -----------------------------------
run_setup gh-missing MELO_GH_BIN="$ROOT/no-such-gh"
check_status 1
check_contains "pkg install gh"
check_contains "gh auth login"

run_setup gh-unauthenticated MELO_GH_BIN="$UNAUTH_GH"
check_status 1
check_contains "not authenticated"
check_contains "gh auth login"

# --- repository targeting safeguards --------------------------------------
run_setup fork-detected MOCK_REPO_VIEW=fork
check_status 1
check_contains "Refusing to upload signing secrets"
check_contains "IcyShadow5/melo"
check_contains "hakosworld-blip/melo"
check_not_contains "$STORE_PASS"
check_not_contains "$KEY_PASS"
check_no_file "$CAPTURE/secret_ANDROID_KEYSTORE_BASE64"

SETUP_SCRIPT_ARGS=(--repo IcyShadow5/melo)
run_setup fork-explicit-no-allow
SETUP_SCRIPT_ARGS=()
check_status 1
check_contains "--allow-non-target-repo"
check_no_file "$CAPTURE/secret_ANDROID_KEYSTORE_BASE64"

SETUP_SCRIPT_ARGS=(--repo IcyShadow5/melo --allow-non-target-repo)
SETUP_STDIN_FILE="$ROOT/wrong-repo-name.txt"
printf 'hakosworld-blip/melo\n' >"$SETUP_STDIN_FILE"
run_setup fork-allow-wrong-confirmation
SETUP_SCRIPT_ARGS=()
SETUP_STDIN_FILE=""
check_status 1
check_contains "Aborted. Nothing was uploaded."
check_no_file "$CAPTURE/secret_ANDROID_KEYSTORE_BASE64"

# --yes must never bypass the alternate-repository confirmation.
SETUP_SCRIPT_ARGS=(--repo IcyShadow5/melo --allow-non-target-repo)
run_setup fork-allow-yes-still-needs-confirmation
SETUP_SCRIPT_ARGS=()
check_status 1
check_contains "Type the repository name exactly"
check_not_contains "$STORE_PASS"
check_no_file "$CAPTURE/secret_ANDROID_KEYSTORE_BASE64"

SETUP_SCRIPT_ARGS=(--repo IcyShadow5/melo --allow-non-target-repo)
SETUP_STDIN_FILE="$ROOT/fork-name.txt"
printf 'IcyShadow5/melo\n' >"$SETUP_STDIN_FILE"
run_setup fork-allow-confirmed
SETUP_SCRIPT_ARGS=()
SETUP_STDIN_FILE=""
check_status 0
check_contains "Uploaded the four signing secrets to IcyShadow5/melo"
check_secret_equals ANDROID_KEY_ALIAS "$ALIAS"
CURRENT="fork-allow-gh-log"
if grep -qF -- "--repo IcyShadow5/melo" "$CAPTURE/gh.log"; then
  ok
else
  bad "uploads did not target the confirmed repository"
fi

# A fork checkout can still target the intended repository explicitly.
SETUP_SCRIPT_ARGS=(--repo hakosworld-blip/melo)
run_setup fork-explicit-intended MOCK_REPO_VIEW=fork
SETUP_SCRIPT_ARGS=()
check_status 0
check_contains "Uploaded the four signing secrets to hakosworld-blip/melo"

SETUP_SCRIPT_ARGS=(--repo hakosworld-blip/melo --allow-non-target-repo)
run_setup intended-with-allow
SETUP_SCRIPT_ARGS=()
check_status 1
check_contains "only needed for repositories other than"
check_no_file "$CAPTURE/secret_ANDROID_KEYSTORE_BASE64"

SETUP_SCRIPT_ARGS=(--repo not-a-repo)
run_setup malformed-repo
SETUP_SCRIPT_ARGS=()
check_status 1
check_contains "Invalid --repo"
check_no_file "$CAPTURE/secret_ANDROID_KEYSTORE_BASE64"

# --- static safety checks --------------------------------------------------
CURRENT="source-never-generates"
if grep -q 'genkeypair' "$SCRIPT"; then
  bad "the helper contains a key-generation command"
else
  ok
fi

CURRENT="source-hidden-prompts"
if grep -q 'read -r -s' "$SCRIPT"; then
  ok
else
  bad "the helper does not read passwords with echo disabled"
fi

CURRENT="source-no-release"
if grep -Eq 'workflow run|release create|git tag|git push' "$SCRIPT"; then
  bad "the helper contains a release-triggering command"
else
  ok
fi

# --- summary ---------------------------------------------------------------
printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
if [ "$FAIL" -ne 0 ]; then
  exit 1
fi
