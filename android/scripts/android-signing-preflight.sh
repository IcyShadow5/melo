#!/usr/bin/env bash
#
# Android release signing preflight.
#
# Usage: android-signing-preflight.sh validate|prepare-signing
#
# Both modes decode ANDROID_KEYSTORE_BASE64 into a temporary file and validate,
# in order:
#   * all four signing secrets are present
#   * the Base64 payload is structurally valid
#   * the decoded file is a readable keystore
#   * ANDROID_KEYSTORE_PASSWORD unlocks the keystore
#   * ANDROID_KEY_ALIAS exists and is a private-key entry
#   * ANDROID_KEY_PASSWORD unlocks that private key
#
# Modes:
#   validate         Always delete the decoded keystore, even on success, and
#                    never export MELO_KEYSTORE_PATH. Used early to report
#                    problems before the Android SDK and unit tests.
#   prepare-signing  Keep the decoded keystore (mode 600) and export
#                    MELO_KEYSTORE_PATH for the build. Used directly before
#                    assembleRelease. Failures still delete the file.
#
# It never prints a secret, a password, the Base64 payload, or raw keytool
# output. Failures are emitted as GitHub Actions annotations with a stable
# category in the title (or as "signing-preflight[category]" outside Actions).
#
# Required environment:
#   ANDROID_KEYSTORE_BASE64
#   ANDROID_KEYSTORE_PASSWORD
#   ANDROID_KEY_ALIAS
#   ANDROID_KEY_PASSWORD
#
# Optional environment:
#   RUNNER_TEMP / TMPDIR / MELO_PREFLIGHT_TMPDIR  where to write the temp file
#   GITHUB_ENV                                   receives MELO_KEYSTORE_PATH
#                                                in prepare-signing mode only
#   GITHUB_ACTIONS=true                          enables ::error annotations

set -uo pipefail
export LC_ALL=C

readonly SECRET_NAMES=(
  ANDROID_KEYSTORE_BASE64
  ANDROID_KEYSTORE_PASSWORD
  ANDROID_KEY_ALIAS
  ANDROID_KEY_PASSWORD
)

annotate() {
  local category="$1"
  local message="$2"
  if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
    printf '::error title=Signing preflight: %s::%s\n' "$category" "$message"
  else
    printf 'signing-preflight[%s]: %s\n' "$category" "$message" >&2
  fi
}

fail() {
  local category="$1"
  local message="$2"
  annotate "$category" "$message"
  exit 1
}

if [ "$#" -ne 1 ]; then
  fail usage-error "Run with exactly one mode: validate or prepare-signing."
fi
mode="$1"
case "$mode" in
  validate|prepare-signing) ;;
  *)
    fail usage-error "Unknown mode '$mode'. Use validate or prepare-signing."
    ;;
esac

if ! command -v keytool >/dev/null 2>&1; then
  fail keytool-missing "keytool was not found. Install a JDK (21 recommended) and retry."
fi
if ! command -v base64 >/dev/null 2>&1; then
  fail base64-missing "base64 was not found. Install coreutils and retry."
fi

missing=0
for name in "${SECRET_NAMES[@]}"; do
  if [ -z "${!name:-}" ]; then
    annotate missing-secret \
      "$name is not set. Add it under Settings -> Secrets and variables -> Actions. See android/README.md."
    missing=1
  fi
done
if [ "$missing" -ne 0 ]; then
  exit 1
fi

alias_name="$ANDROID_KEY_ALIAS"

tmpdir="${MELO_PREFLIGHT_TMPDIR:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}}"
if [ ! -d "$tmpdir" ] || [ ! -w "$tmpdir" ]; then
  fail tempfile-error "The temporary directory ($tmpdir) is missing or not writable."
fi

if ! command -v mktemp >/dev/null 2>&1; then
  fail tempfile-error "mktemp was not found. Install coreutils and retry."
fi

umask 077
ks_path=$(mktemp "$tmpdir/melo-signing.XXXXXXXXXX" 2>/dev/null) \
  || fail tempfile-error "Could not create a unique temporary keystore in $tmpdir."

remove_keystore() {
  if [ -z "${ks_path:-}" ]; then
    return 0
  fi
  if [ ! -e "$ks_path" ]; then
    return 0
  fi
  rm -f -- "$ks_path" 2>/dev/null || return 1
  [ ! -e "$ks_path" ] || return 1
  return 0
}

cleanup() {
  local status=$?
  if [ "$status" -ne 0 ]; then
    if ! remove_keystore; then
      annotate tempfile-error "The temporary keystore at $ks_path could not be removed. Delete it manually; it contains private key material."
    fi
  fi
  exit "$status"
}
trap cleanup EXIT

chmod 600 "$ks_path" 2>/dev/null \
  || fail tempfile-error "Could not restrict permissions on the temporary keystore at $ks_path."

b64=$(printf '%s' "$ANDROID_KEYSTORE_BASE64" | tr -d '[:space:]')
if [ -z "$b64" ]; then
  fail invalid-base64 "ANDROID_KEYSTORE_BASE64 is empty after removing whitespace. Re-encode the .jks file with base64."
fi
if ! [[ "$b64" =~ ^[A-Za-z0-9+/]+={0,2}$ ]]; then
  fail invalid-base64 "ANDROID_KEYSTORE_BASE64 contains characters that are not valid Base64. Re-encode the .jks file as one Base64 line with no extra text."
fi
if [[ "$b64" == *=* ]] && [ $(( ${#b64} % 4 )) -ne 0 ]; then
  fail invalid-base64 "ANDROID_KEYSTORE_BASE64 has invalid padding. Re-encode the .jks file with base64."
fi
case $(( ${#b64} % 4 )) in
  0) ;;
  2) b64="${b64}==" ;;
  3) b64="${b64}=" ;;
  *) fail invalid-base64 "ANDROID_KEYSTORE_BASE64 is truncated. Re-encode the complete .jks file with base64." ;;
esac

if ! printf '%s' "$b64" | base64 -d >"$ks_path" 2>/dev/null; then
  fail invalid-base64 "ANDROID_KEYSTORE_BASE64 could not be decoded. Re-encode the .jks file with base64."
fi
if [ ! -s "$ks_path" ]; then
  fail invalid-keystore "The decoded keystore is empty. Re-encode the original .jks file; do not paste the keystore itself."
fi

header=""
if command -v od >/dev/null 2>&1; then
  header=$(od -An -tx1 -N4 "$ks_path" 2>/dev/null | tr -d ' \r\n')
fi
if [ -n "$header" ]; then
  case "$header" in
    feedfeed|cececece|308*) ;;
    *)
      fail invalid-keystore "The decoded file does not look like a JKS/PKCS12 keystore. Re-encode the original .jks file from a known-good copy."
      ;;
  esac
fi

keytool_out=$(keytool -list -keystore "$ks_path" -storepass:env ANDROID_KEYSTORE_PASSWORD 2>&1)
keytool_status=$?
if [ "$keytool_status" -ne 0 ]; then
  case "$keytool_out" in
    *"password was incorrect"*|*"tampered with"*)
      fail cannot-open-keystore "The keystore could not be opened. ANDROID_KEYSTORE_PASSWORD may be wrong, or the decoded file may be corrupted or incomplete; keytool reports the same error for both. Re-enter the password without a trailing newline. If it is already correct, re-encode the original .jks file from a known-good copy."
      ;;
    *)
      fail invalid-keystore "The decoded file is not a readable JKS/PKCS12 keystore. Re-encode the original .jks file from a known-good copy."
      ;;
  esac
fi

keytool_out=$(keytool -list -keystore "$ks_path" -storepass:env ANDROID_KEYSTORE_PASSWORD -alias "$alias_name" 2>&1)
keytool_status=$?
if [ "$keytool_status" -ne 0 ]; then
  case "$keytool_out" in
    *"password was incorrect"*|*"tampered with"*)
      fail cannot-open-keystore "The keystore could not be opened. ANDROID_KEYSTORE_PASSWORD may be wrong, or the decoded file may be corrupted or incomplete; keytool reports the same error for both. Re-enter the password without a trailing newline. If it is already correct, re-encode the original .jks file from a known-good copy."
      ;;
    *)
      fail missing-alias "ANDROID_KEY_ALIAS was not found in the keystore. List aliases with keytool -list and update the secret without trailing spaces or newlines."
      ;;
  esac
fi
case "$keytool_out" in
  *PrivateKeyEntry*) ;;
  *)
    fail unusable-private-key "The configured alias is not a private-key entry. Choose the alias whose entry type is PrivateKeyEntry."
    ;;
esac

keytool_out=$(keytool -certreq -keystore "$ks_path" \
  -storepass:env ANDROID_KEYSTORE_PASSWORD \
  -keypass:env ANDROID_KEY_PASSWORD \
  -alias "$alias_name" 2>&1)
keytool_status=$?
if [ "$keytool_status" -ne 0 ]; then
  case "$keytool_out" in
    *"Cannot recover key"*|*"UnrecoverableKeyException"*)
      fail wrong-key-password "ANDROID_KEY_PASSWORD does not unlock the private key for the configured alias. Re-enter it without a trailing newline; if the key uses the keystore password, set both secrets to the same value."
      ;;
    *"has no key"*|*"not a key entry"*|*"Certificate chain not found"*)
      fail unusable-private-key "The configured alias has no accessible private key. Choose the alias whose entry type is PrivateKeyEntry."
      ;;
    *"does not exist"*)
      fail missing-alias "ANDROID_KEY_ALIAS was not found in the keystore. List aliases with keytool -list and update the secret without trailing spaces or newlines."
      ;;
    *"password was incorrect"*|*"tampered with"*)
      fail cannot-open-keystore "The keystore could not be opened. ANDROID_KEYSTORE_PASSWORD may be wrong, or the decoded file may be corrupted or incomplete; keytool reports the same error for both. Re-enter the password without a trailing newline. If it is already correct, re-encode the original .jks file from a known-good copy."
      ;;
    *)
      fail unusable-private-key "The private key for the configured alias could not be used. Check the alias and key password."
      ;;
  esac
fi
unset keytool_out

if [ "$mode" = "prepare-signing" ]; then
  if [ -n "${GITHUB_ENV:-}" ]; then
    env_line="MELO_KEYSTORE_PATH=$ks_path"
    if ! grep -qxF -- "$env_line" "$GITHUB_ENV" 2>/dev/null; then
      printf '%s\n' "$env_line" >>"$GITHUB_ENV" || fail tempfile-error "Could not export MELO_KEYSTORE_PATH to $GITHUB_ENV."
    fi
  fi
  printf 'Signing preflight passed: keystore, alias and private key are usable. Keystore prepared for signing.\n'
else
  if ! remove_keystore; then
    fail tempfile-error "Validation succeeded, but the temporary keystore at $ks_path could not be removed. Delete it manually before continuing."
  fi
  printf 'Signing preflight passed: keystore, alias and private key are usable. Validation only; keystore removed.\n'
fi
