#!/usr/bin/env bash
#
# Tests for android/scripts/android-signing-preflight.sh.
# Uses synthetic keystores generated at runtime; no real signing material.

set -uo pipefail

HERE=$(cd -- "$(dirname -- "$0")" && pwd)
SCRIPT="$HERE/../android-signing-preflight.sh"
WORKFLOW="$HERE/../../../.github/workflows/android-release.yml"
ROOT=$(mktemp -d)
trap 'rm -rf -- "$ROOT"' EXIT

PASS=0
FAIL=0
CURRENT=""
STATUS=0
OUT=""
OUTDIR=""

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

exported_path() {
  grep '^MELO_KEYSTORE_PATH=' "$1" 2>/dev/null | tail -1 | cut -d= -f2-
}

runner_count() {
  find "$1" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' '
}

check_runner_empty() {
  local count
  count=$(runner_count "$1")
  if [ "$count" = "0" ]; then ok; else bad "expected no temporary keystore files, found $count"; fi
}

run_preflight() {
  local name="$1"
  shift
  run_preflight_mode "$name" prepare-signing "$@"
}

run_preflight_mode() {
  local name="$1"
  local mode="$2"
  shift 2
  CURRENT="$name"
  OUTDIR="$ROOT/$name"
  mkdir -p "$OUTDIR/runner"
  if [ "$mode" = "__none__" ]; then
    env GITHUB_ACTIONS=true \
      RUNNER_TEMP="$OUTDIR/runner" \
      GITHUB_ENV="$OUTDIR/github_env" \
      "$@" \
      bash "$SCRIPT" >"$OUTDIR/stdout" 2>"$OUTDIR/stderr"
  else
    env GITHUB_ACTIONS=true \
      RUNNER_TEMP="$OUTDIR/runner" \
      GITHUB_ENV="$OUTDIR/github_env" \
      "$@" \
      bash "$SCRIPT" "$mode" >"$OUTDIR/stdout" 2>"$OUTDIR/stderr"
  fi
  STATUS=$?
  OUT=$(cat "$OUTDIR/stdout" "$OUTDIR/stderr")
}

b64_file() {
  base64 <"$1" | tr -d '\r\n'
}

SOURCE="$ROOT/source"
mkdir -p "$SOURCE"
KEYSTORE="$SOURCE/melo-release.jks"
STORE_PASS='synthetic-store-pass'
KEY_PASS='synthetic-key-pass'
ALIAS='melo-test'

if ! keytool -genkeypair \
  -storetype JKS \
  -keystore "$KEYSTORE" \
  -storepass "$STORE_PASS" \
  -keypass "$KEY_PASS" \
  -alias "$ALIAS" \
  -keyalg RSA -keysize 2048 -validity 365 \
  -dname "CN=Melo Synthetic Test, O=Melo Test, C=US" >/dev/null 2>&1; then
  printf 'could not create a synthetic test keystore\n' >&2
  exit 1
fi

VALID_B64=$(b64_file "$KEYSTORE")
GARBAGE_B64=$(printf 'not a keystore' | base64 | tr -d '\r\n')
TRUNCATED_B64=$(head -c $(( $(wc -c <"$KEYSTORE") / 2 )) "$KEYSTORE" | base64 | tr -d '\r\n')

# A single flipped byte after the JKS magic yields keytool's ambiguous
# "tampered with, or password was incorrect" error, exactly like a bad password.
CORRUPTED_JKS="$SOURCE/corrupted.jks"
CORRUPTED_B64=""
for offset in 20 40 60; do
  cp "$KEYSTORE" "$CORRUPTED_JKS"
  printf '\000' | dd of="$CORRUPTED_JKS" bs=1 seek="$offset" count=1 conv=notrunc 2>/dev/null
  if ! cmp -s "$KEYSTORE" "$CORRUPTED_JKS"; then
    CORRUPTED_B64=$(b64_file "$CORRUPTED_JKS")
    break
  fi
done
if [ -z "$CORRUPTED_B64" ]; then
  printf 'could not corrupt the synthetic test keystore\n' >&2
  exit 1
fi

keytool -exportcert -keystore "$KEYSTORE" -storepass "$STORE_PASS" -alias "$ALIAS" \
  -file "$SOURCE/melo.cer" >/dev/null 2>&1
keytool -importcert -noprompt -keystore "$SOURCE/trusted.jks" -storepass "$STORE_PASS" \
  -alias trusted -file "$SOURCE/melo.cer" >/dev/null 2>&1
TRUSTED_B64=$(b64_file "$SOURCE/trusted.jks")

# --- missing secrets -------------------------------------------------------
for missing_name in ANDROID_KEYSTORE_BASE64 ANDROID_KEYSTORE_PASSWORD ANDROID_KEY_ALIAS ANDROID_KEY_PASSWORD; do
  b64="$VALID_B64"
  sp="$STORE_PASS"
  al="$ALIAS"
  kp="$KEY_PASS"
  case "$missing_name" in
    ANDROID_KEYSTORE_BASE64) b64="" ;;
    ANDROID_KEYSTORE_PASSWORD) sp="" ;;
    ANDROID_KEY_ALIAS) al="" ;;
    ANDROID_KEY_PASSWORD) kp="" ;;
  esac
  name="missing-${missing_name#ANDROID_}"
  run_preflight "$name" \
    ANDROID_KEYSTORE_BASE64="$b64" \
    ANDROID_KEYSTORE_PASSWORD="$sp" \
    ANDROID_KEY_ALIAS="$al" \
    ANDROID_KEY_PASSWORD="$kp"
  check_status 1
  check_contains "missing-secret"
  check_contains "$missing_name"
  check_runner_empty "$OUTDIR/runner"
done

# --- invalid Base64 --------------------------------------------------------
run_preflight invalid-base64 \
  ANDROID_KEYSTORE_BASE64="not base64!!" \
  ANDROID_KEYSTORE_PASSWORD="$STORE_PASS" \
  ANDROID_KEY_ALIAS="$ALIAS" \
  ANDROID_KEY_PASSWORD="$KEY_PASS"
check_status 1
check_contains "invalid-base64"
check_runner_empty "$OUTDIR/runner"

run_preflight truncated-base64 \
  ANDROID_KEYSTORE_BASE64="AAAAA" \
  ANDROID_KEYSTORE_PASSWORD="$STORE_PASS" \
  ANDROID_KEY_ALIAS="$ALIAS" \
  ANDROID_KEY_PASSWORD="$KEY_PASS"
check_status 1
check_contains "invalid-base64"
check_runner_empty "$OUTDIR/runner"

run_preflight bad-padding \
  ANDROID_KEYSTORE_BASE64="AAAA=" \
  ANDROID_KEYSTORE_PASSWORD="$STORE_PASS" \
  ANDROID_KEY_ALIAS="$ALIAS" \
  ANDROID_KEY_PASSWORD="$KEY_PASS"
check_status 1
check_contains "invalid-base64"
check_runner_empty "$OUTDIR/runner"

run_preflight whitespace-base64 \
  ANDROID_KEYSTORE_BASE64="   " \
  ANDROID_KEYSTORE_PASSWORD="$STORE_PASS" \
  ANDROID_KEY_ALIAS="$ALIAS" \
  ANDROID_KEY_PASSWORD="$KEY_PASS"
check_status 1
check_contains "invalid-base64"
check_runner_empty "$OUTDIR/runner"

# --- empty or invalid decoded keystore ------------------------------------
run_preflight garbage-keystore \
  ANDROID_KEYSTORE_BASE64="$GARBAGE_B64" \
  ANDROID_KEYSTORE_PASSWORD="$STORE_PASS" \
  ANDROID_KEY_ALIAS="$ALIAS" \
  ANDROID_KEY_PASSWORD="$KEY_PASS"
check_status 1
check_contains "invalid-keystore"
check_runner_empty "$OUTDIR/runner"

run_preflight truncated-keystore \
  ANDROID_KEYSTORE_BASE64="$TRUNCATED_B64" \
  ANDROID_KEYSTORE_PASSWORD="$STORE_PASS" \
  ANDROID_KEY_ALIAS="$ALIAS" \
  ANDROID_KEY_PASSWORD="$KEY_PASS"
check_status 1
check_contains "invalid-keystore"
check_runner_empty "$OUTDIR/runner"

# --- incorrect keystore password or corrupted keystore --------------------
# keytool reports the same error for both, so the preflight must not claim a
# confirmed wrong password; it names the ambiguity instead.
run_preflight wrong-store-password \
  ANDROID_KEYSTORE_BASE64="$VALID_B64" \
  ANDROID_KEYSTORE_PASSWORD="wrong-store-password" \
  ANDROID_KEY_ALIAS="$ALIAS" \
  ANDROID_KEY_PASSWORD="$KEY_PASS"
check_status 1
check_contains "cannot-open-keystore"
check_contains "may be wrong"
check_contains "corrupted"
check_not_contains "wrong-store-password"
check_runner_empty "$OUTDIR/runner"

run_preflight corrupted-keystore \
  ANDROID_KEYSTORE_BASE64="$CORRUPTED_B64" \
  ANDROID_KEYSTORE_PASSWORD="$STORE_PASS" \
  ANDROID_KEY_ALIAS="$ALIAS" \
  ANDROID_KEY_PASSWORD="$KEY_PASS"
check_status 1
check_contains "cannot-open-keystore"
check_contains "may be wrong"
check_contains "corrupted"
check_runner_empty "$OUTDIR/runner"

# --- missing or incorrect key alias ---------------------------------------
run_preflight missing-alias \
  ANDROID_KEYSTORE_BASE64="$VALID_B64" \
  ANDROID_KEYSTORE_PASSWORD="$STORE_PASS" \
  ANDROID_KEY_ALIAS="does-not-exist" \
  ANDROID_KEY_PASSWORD="$KEY_PASS"
check_status 1
check_contains "missing-alias"
check_runner_empty "$OUTDIR/runner"

# --- incorrect key password ------------------------------------------------
run_preflight wrong-key-password \
  ANDROID_KEYSTORE_BASE64="$VALID_B64" \
  ANDROID_KEYSTORE_PASSWORD="$STORE_PASS" \
  ANDROID_KEY_ALIAS="$ALIAS" \
  ANDROID_KEY_PASSWORD="wrong-key-password"
check_status 1
check_contains "wrong-key-password"
check_runner_empty "$OUTDIR/runner"

# --- inaccessible private-key entry ---------------------------------------
run_preflight unusable-private-key \
  ANDROID_KEYSTORE_BASE64="$TRUSTED_B64" \
  ANDROID_KEYSTORE_PASSWORD="$STORE_PASS" \
  ANDROID_KEY_ALIAS="trusted" \
  ANDROID_KEY_PASSWORD="$STORE_PASS"
check_status 1
check_contains "unusable-private-key"
check_runner_empty "$OUTDIR/runner"

# --- redaction -------------------------------------------------------------
for case_name in wrong-store-password corrupted-keystore wrong-key-password invalid-base64 garbage-keystore missing-alias unusable-private-key; do
  CURRENT="redaction-$case_name"
  OUT=$(cat "$ROOT/$case_name/stdout" "$ROOT/$case_name/stderr")
  check_not_contains "$STORE_PASS"
  check_not_contains "$KEY_PASS"
  check_not_contains "$VALID_B64"
  check_not_contains "keytool error"
  check_not_contains "Exception"
  check_not_contains "Keystore was tampered"
done

# --- success, permissions and exported path -------------------------------
run_preflight success \
  ANDROID_KEYSTORE_BASE64="$VALID_B64" \
  ANDROID_KEYSTORE_PASSWORD="$STORE_PASS" \
  ANDROID_KEY_ALIAS="$ALIAS" \
  ANDROID_KEY_PASSWORD="$KEY_PASS"
check_status 0
check_contains "Signing preflight passed"
check_not_contains "::error"
check_file "$OUTDIR/github_env"
SUCCESS_PATH=$(exported_path "$OUTDIR/github_env")
CURRENT="success-path"
case "$SUCCESS_PATH" in
  "$OUTDIR/runner/"melo-signing.*) ok ;;
  *) bad "unexpected keystore path: ${SUCCESS_PATH:-<empty>}" ;;
esac
check_file "$SUCCESS_PATH"
CURRENT="success-env"
if [ -n "$SUCCESS_PATH" ] && grep -qxF "MELO_KEYSTORE_PATH=$SUCCESS_PATH" "$OUTDIR/github_env"; then
  ok
else
  bad "GITHUB_ENV does not contain the exported keystore path"
fi
if [ -n "$SUCCESS_PATH" ]; then
  case "$(uname -s)" in
    Linux)
      mode=$(stat -c '%a' "$SUCCESS_PATH" 2>/dev/null || true)
      ;;
    Darwin)
      mode=$(stat -f '%Lp' "$SUCCESS_PATH" 2>/dev/null || true)
      ;;
    *)
      # Windows/MSYS does not enforce POSIX file modes; CI runs this on Linux.
      mode=""
      ;;
  esac
  if [ -n "$mode" ]; then
    CURRENT="success-mode"
    if [ "$mode" = "600" ]; then ok; else bad "expected mode 600, got $mode"; fi
  fi
fi
CURRENT="success-redaction"
OUT=$(cat "$OUTDIR/stdout" "$OUTDIR/stderr")
check_not_contains "$STORE_PASS"
check_not_contains "$KEY_PASS"
check_not_contains "$VALID_B64"

# --- PKCS12 keystore is also accepted -------------------------------------
PKCS12="$SOURCE/melo-release.p12"
keytool -genkeypair \
  -storetype PKCS12 \
  -keystore "$PKCS12" \
  -storepass "$STORE_PASS" \
  -keypass "$STORE_PASS" \
  -alias "$ALIAS" \
  -keyalg RSA -keysize 2048 -validity 365 \
  -dname "CN=Melo Synthetic Test, O=Melo Test, C=US" >/dev/null 2>&1
PKCS12_B64=$(b64_file "$PKCS12")
run_preflight success-pkcs12 \
  ANDROID_KEYSTORE_BASE64="$PKCS12_B64" \
  ANDROID_KEYSTORE_PASSWORD="$STORE_PASS" \
  ANDROID_KEY_ALIAS="$ALIAS" \
  ANDROID_KEY_PASSWORD="$STORE_PASS"
check_status 0
check_contains "Signing preflight passed"
check_file "$(exported_path "$OUTDIR/github_env")"

# --- Base64 with line breaks and spaces -----------------------------------
WRAPPED_B64=$(base64 "$KEYSTORE" | tr '\n' ' ')
run_preflight success-wrapped-base64 \
  ANDROID_KEYSTORE_BASE64="$WRAPPED_B64" \
  ANDROID_KEYSTORE_PASSWORD="$STORE_PASS" \
  ANDROID_KEY_ALIAS="$ALIAS" \
  ANDROID_KEY_PASSWORD="$KEY_PASS"
check_status 0
check_contains "Signing preflight passed"
check_file "$(exported_path "$OUTDIR/github_env")"

# --- repeated runs use independent keystore files -------------------------
run_preflight success \
  ANDROID_KEYSTORE_BASE64="$VALID_B64" \
  ANDROID_KEYSTORE_PASSWORD="$STORE_PASS" \
  ANDROID_KEY_ALIAS="$ALIAS" \
  ANDROID_KEY_PASSWORD="$KEY_PASS"
check_status 0
SECOND_PATH=$(exported_path "$OUTDIR/github_env")
CURRENT="repeat-env"
env_lines=$(grep -c '^MELO_KEYSTORE_PATH=' "$OUTDIR/github_env" || true)
if [ "$env_lines" = "2" ]; then ok; else bad "expected two exported paths, got $env_lines"; fi
CURRENT="repeat-distinct"
if [ -n "$SECOND_PATH" ] && [ "$SECOND_PATH" != "$SUCCESS_PATH" ]; then
  ok
else
  bad "repeated runs reused the same keystore path"
fi
CURRENT="repeat-both-exist"
check_file "$SUCCESS_PATH"
check_file "$SECOND_PATH"
CURRENT="repeat-files"
runner_files=$(runner_count "$OUTDIR/runner")
if [ "$runner_files" = "2" ]; then ok; else bad "expected two temporary files, got $runner_files"; fi

CURRENT="repeat-remove-latest"
rm -f "$SECOND_PATH"
check_file "$SUCCESS_PATH"
check_no_file "$SECOND_PATH"

# --- simulated cleanup step ------------------------------------------------
rm -f "$SUCCESS_PATH"
CURRENT="cleanup"
check_runner_empty "$OUTDIR/runner"

# --- explicit modes --------------------------------------------------------
run_preflight_mode usage-no-mode __none__ \
  ANDROID_KEYSTORE_BASE64="$VALID_B64" \
  ANDROID_KEYSTORE_PASSWORD="$STORE_PASS" \
  ANDROID_KEY_ALIAS="$ALIAS" \
  ANDROID_KEY_PASSWORD="$KEY_PASS"
check_status 1
check_contains "usage-error"
check_contains "validate or prepare-signing"
check_runner_empty "$OUTDIR/runner"

run_preflight_mode usage-unknown bogus \
  ANDROID_KEYSTORE_BASE64="$VALID_B64" \
  ANDROID_KEYSTORE_PASSWORD="$STORE_PASS" \
  ANDROID_KEY_ALIAS="$ALIAS" \
  ANDROID_KEY_PASSWORD="$KEY_PASS"
check_status 1
check_contains "usage-error"
check_contains "Unknown mode"
check_runner_empty "$OUTDIR/runner"

run_preflight_mode validate-success validate \
  ANDROID_KEYSTORE_BASE64="$VALID_B64" \
  ANDROID_KEYSTORE_PASSWORD="$STORE_PASS" \
  ANDROID_KEY_ALIAS="$ALIAS" \
  ANDROID_KEY_PASSWORD="$KEY_PASS"
check_status 0
check_contains "Validation only; keystore removed"
check_not_contains "MELO_KEYSTORE_PATH"
check_runner_empty "$OUTDIR/runner"
check_no_file "$OUTDIR/github_env"

run_preflight_mode validate-wrong-key validate \
  ANDROID_KEYSTORE_BASE64="$VALID_B64" \
  ANDROID_KEYSTORE_PASSWORD="$STORE_PASS" \
  ANDROID_KEY_ALIAS="$ALIAS" \
  ANDROID_KEY_PASSWORD="wrong-key-password"
check_status 1
check_contains "wrong-key-password"
check_runner_empty "$OUTDIR/runner"
check_no_file "$OUTDIR/github_env"

run_preflight_mode prepare-success prepare-signing \
  ANDROID_KEYSTORE_BASE64="$VALID_B64" \
  ANDROID_KEYSTORE_PASSWORD="$STORE_PASS" \
  ANDROID_KEY_ALIAS="$ALIAS" \
  ANDROID_KEY_PASSWORD="$KEY_PASS"
check_status 0
check_contains "Keystore prepared for signing"
PREPARE_PATH=$(exported_path "$OUTDIR/github_env")
CURRENT="prepare-path"
case "$PREPARE_PATH" in
  "$OUTDIR/runner/"melo-signing.*) ok ;;
  *) bad "unexpected prepare-signing path: ${PREPARE_PATH:-<empty>}" ;;
esac
check_file "$PREPARE_PATH"
check_file "$OUTDIR/github_env"
CURRENT="prepare-env"
if [ -n "$PREPARE_PATH" ] && grep -qxF "MELO_KEYSTORE_PATH=$PREPARE_PATH" "$OUTDIR/github_env"; then
  ok
else
  bad "prepare-signing did not export MELO_KEYSTORE_PATH"
fi

run_preflight_mode prepare-wrong-key prepare-signing \
  ANDROID_KEYSTORE_BASE64="$VALID_B64" \
  ANDROID_KEYSTORE_PASSWORD="$STORE_PASS" \
  ANDROID_KEY_ALIAS="$ALIAS" \
  ANDROID_KEY_PASSWORD="wrong-key-password"
check_status 1
check_contains "wrong-key-password"
check_runner_empty "$OUTDIR/runner"
check_no_file "$OUTDIR/github_env"

# --- unrelated file at the old fixed name is untouched --------------------
BYSTANDER_DIR="$ROOT/bystander"
mkdir -p "$BYSTANDER_DIR/runner"
printf 'unrelated file that must survive\n' >"$BYSTANDER_DIR/runner/melo-release.jks"
BEFORE_SUM=$(cksum <"$BYSTANDER_DIR/runner/melo-release.jks")
run_preflight_mode bystander validate \
  ANDROID_KEYSTORE_BASE64="$VALID_B64" \
  ANDROID_KEYSTORE_PASSWORD="$STORE_PASS" \
  ANDROID_KEY_ALIAS="$ALIAS" \
  ANDROID_KEY_PASSWORD="$KEY_PASS"
check_status 0
CURRENT="bystander-exists"
check_file "$BYSTANDER_DIR/runner/melo-release.jks"
CURRENT="bystander-unchanged"
AFTER_SUM=$(cksum <"$BYSTANDER_DIR/runner/melo-release.jks")
if [ "$BEFORE_SUM" = "$AFTER_SUM" ]; then ok; else bad "the unrelated melo-release.jks was modified"; fi
CURRENT="bystander-only-file"
bystander_files=$(runner_count "$BYSTANDER_DIR/runner")
if [ "$bystander_files" = "1" ]; then ok; else bad "expected only the unrelated file, found $bystander_files"; fi

# --- concurrent runs use independent files --------------------------------
CONC_DIR="$ROOT/concurrent"
mkdir -p "$CONC_DIR/one/runner" "$CONC_DIR/two/runner"
env GITHUB_ACTIONS=true RUNNER_TEMP="$CONC_DIR/one/runner" GITHUB_ENV="$CONC_DIR/one/github_env" \
  ANDROID_KEYSTORE_BASE64="$VALID_B64" ANDROID_KEYSTORE_PASSWORD="$STORE_PASS" \
  ANDROID_KEY_ALIAS="$ALIAS" ANDROID_KEY_PASSWORD="$KEY_PASS" \
  bash "$SCRIPT" prepare-signing >"$CONC_DIR/one/out" 2>&1 &
CONC_PID1=$!
env GITHUB_ACTIONS=true RUNNER_TEMP="$CONC_DIR/two/runner" GITHUB_ENV="$CONC_DIR/two/github_env" \
  ANDROID_KEYSTORE_BASE64="$VALID_B64" ANDROID_KEYSTORE_PASSWORD="$STORE_PASS" \
  ANDROID_KEY_ALIAS="$ALIAS" ANDROID_KEY_PASSWORD="$KEY_PASS" \
  bash "$SCRIPT" prepare-signing >"$CONC_DIR/two/out" 2>&1 &
CONC_PID2=$!
wait "$CONC_PID1"
CONC_STATUS1=$?
wait "$CONC_PID2"
CONC_STATUS2=$?
CURRENT="concurrent-status"
if [ "$CONC_STATUS1" -eq 0 ] && [ "$CONC_STATUS2" -eq 0 ]; then
  ok
else
  bad "concurrent runs failed: $CONC_STATUS1/$CONC_STATUS2"
fi
CONC_PATH1=$(exported_path "$CONC_DIR/one/github_env")
CONC_PATH2=$(exported_path "$CONC_DIR/two/github_env")
CURRENT="concurrent-distinct"
if [ -n "$CONC_PATH1" ] && [ -n "$CONC_PATH2" ] && [ "$CONC_PATH1" != "$CONC_PATH2" ]; then
  ok
else
  bad "concurrent runs reused the same keystore path"
fi
CURRENT="concurrent-files"
check_file "$CONC_PATH1"
check_file "$CONC_PATH2"
rm -f "$CONC_PATH1" "$CONC_PATH2" 2>/dev/null

# --- cleanup failure fails validation -------------------------------------
FAILBIN="$ROOT/failbin"
mkdir -p "$FAILBIN"
printf '#!/usr/bin/env bash\nexit 1\n' >"$FAILBIN/rm"
chmod +x "$FAILBIN/rm"
run_preflight_mode cleanup-failure validate \
  PATH="$FAILBIN:$PATH" \
  ANDROID_KEYSTORE_BASE64="$VALID_B64" \
  ANDROID_KEYSTORE_PASSWORD="$STORE_PASS" \
  ANDROID_KEY_ALIAS="$ALIAS" \
  ANDROID_KEY_PASSWORD="$KEY_PASS"
check_status 1
check_contains "could not be removed"
check_not_contains "Signing preflight passed"
find "$OUTDIR/runner" -maxdepth 1 -type f -exec rm -f {} + 2>/dev/null || true

# --- workflow ordering and preserved cleanup -------------------------------
CURRENT="workflow-ordering"
jdk_line=$(grep -n 'Set up JDK 21' "$WORKFLOW" | head -1 | cut -d: -f1)
validate_line=$(grep -n 'android-signing-preflight.sh validate' "$WORKFLOW" | head -1 | cut -d: -f1)
sdk_line=$(grep -n 'Set up Android SDK' "$WORKFLOW" | head -1 | cut -d: -f1)
tests_line=$(grep -n 'Run unit tests' "$WORKFLOW" | head -1 | cut -d: -f1)
prepare_line=$(grep -n 'android-signing-preflight.sh prepare-signing' "$WORKFLOW" | head -1 | cut -d: -f1)
build_line=$(grep -n 'Build signed release APK' "$WORKFLOW" | head -1 | cut -d: -f1)
if [ -n "$jdk_line" ] && [ -n "$validate_line" ] && [ -n "$sdk_line" ] \
  && [ -n "$tests_line" ] && [ -n "$prepare_line" ] && [ -n "$build_line" ] \
  && [ "$jdk_line" -lt "$validate_line" ] \
  && [ "$validate_line" -lt "$sdk_line" ] \
  && [ "$validate_line" -lt "$tests_line" ] \
  && [ "$tests_line" -lt "$prepare_line" ] \
  && [ "$prepare_line" -lt "$build_line" ]; then
  ok
else
  bad "validate must run after JDK and before SDK/tests; prepare-signing must run after tests and before the build"
fi

CURRENT="workflow-two-phases"
phase_count=$(grep -c 'android-signing-preflight.sh' "$WORKFLOW" || true)
if [ "$phase_count" = "2" ]; then ok; else bad "expected exactly two preflight invocations, got $phase_count"; fi

CURRENT="workflow-cleanup"
cleanup_line=$(grep -n 'Remove temporary keystore' "$WORKFLOW" | head -1 | cut -d: -f1)
verify_line=$(grep -n 'Verify signature, package id and checksum' "$WORKFLOW" | head -1 | cut -d: -f1)
upload_line=$(grep -n 'Upload APK artifact' "$WORKFLOW" | head -1 | cut -d: -f1)
release_line=$(grep -n 'Publish GitHub Release' "$WORKFLOW" | head -1 | cut -d: -f1)
next_step_line=$(awk -v start="${build_line:-0}" 'NR > start && /^      - name:/ { print NR; exit }' "$WORKFLOW")
if [ -n "$cleanup_line" ] && [ -n "$verify_line" ] && [ -n "$upload_line" ] \
  && [ -n "$release_line" ] && [ -n "$next_step_line" ] \
  && [ "$cleanup_line" -eq "$next_step_line" ] \
  && [ "$cleanup_line" -lt "$verify_line" ] \
  && [ "$cleanup_line" -lt "$upload_line" ] \
  && [ "$cleanup_line" -lt "$release_line" ]; then
  ok
else
  bad "temporary-keystore cleanup must immediately follow the build and precede verification, upload and release"
fi

CURRENT="workflow-cleanup-always"
cleanup_block=$(sed -n "${cleanup_line},$((cleanup_line + 3))p" "$WORKFLOW" 2>/dev/null || true)
case "$cleanup_block" in
  *"if: always()"*) ok ;;
  *) bad "the temporary-keystore cleanup step lost its if: always() guard" ;;
esac

CURRENT="workflow-old-decode-step"
if grep -q 'Decode keystore to a temporary file' "$WORKFLOW"; then
  bad "the old inline decode step is still present"
else
  ok
fi

# --- summary ---------------------------------------------------------------
printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
if [ "$FAIL" -ne 0 ]; then
  exit 1
fi
