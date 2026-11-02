#!/usr/bin/env bash
#
# Interactive Termux helper for melo Android release signing.
#
# It uses an EXISTING melo-release.jks, verifies it locally, then uploads the
# four repository secrets through standard input. It never generates or
# overwrites a keystore, never writes a password or Base64 copy to disk, and
# never starts a release.
#
# Usage:
#   bash android/scripts/setup-termux-signing.sh
#   bash android/scripts/setup-termux-signing.sh --keystore ~/melo-release.jks
#   bash android/scripts/setup-termux-signing.sh --repo owner/name
#
# Signing secrets belong to hakosworld-blip/melo. A checkout that resolves to
# any other repository is refused unless the target is passed explicitly with
# --repo and --allow-non-target-repo, and its name is typed back to confirm.
# --yes skips the ordinary prompt only for the intended repository.
#
# Optional environment (mainly for tests/automation):
#   MELO_KEYSTORE_FILE, MELO_KEY_ALIAS,
#   MELO_KEYSTORE_PASSWORD, MELO_KEY_PASSWORD,
#   MELO_GH_BIN, MELO_ASSUME_YES=1

set -uo pipefail
export LC_ALL=C

INTENDED_REPO="hakosworld-blip/melo"

usage() {
  cat <<'EOF'
Usage: setup-termux-signing.sh [--keystore PATH] [--repo OWNER/NAME] [--yes]

Verifies an existing melo-release.jks and uploads:
  ANDROID_KEYSTORE_BASE64, ANDROID_KEYSTORE_PASSWORD,
  ANDROID_KEY_ALIAS, ANDROID_KEY_PASSWORD

This helper never creates or overwrites a signing key and never starts a release.

Options:
  --keystore PATH        keystore to use (default: ./melo-release.jks, then ~/melo-release.jks)
  --repo OWNER/NAME      repository to update (default: the repository gh reports)
  --allow-non-target-repo  allow a repository other than hakosworld-blip/melo;
                         requires --repo and typing the repository name
  --yes, -y              skip the ordinary upload confirmation (the intended
                         repository only; never the alternate-repo check)
  --help, -h             show this help
EOF
}

fail() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

gh_install_help() {
  cat >&2 <<'EOF'
GitHub CLI (gh) is required.

Termux:
  pkg install gh
Debian/Ubuntu:
  sudo apt install gh

Then authenticate once:
  gh auth login
EOF
}

ks_path="${MELO_KEYSTORE_FILE:-}"
if [ -z "$ks_path" ]; then
  if [ -f "$PWD/melo-release.jks" ]; then
    ks_path="$PWD/melo-release.jks"
  elif [ -f "${HOME:-}/melo-release.jks" ]; then
    ks_path="${HOME:-}/melo-release.jks"
  else
    ks_path="$PWD/melo-release.jks"
  fi
fi
repo_hint=""
allow_non_target_repo=0
assume_yes="${MELO_ASSUME_YES:-0}"
gh_bin="${MELO_GH_BIN:-gh}"
keytool_bin="${MELO_KEYTOOL:-keytool}"

while [ $# -gt 0 ]; do
  case "$1" in
    --keystore)
      [ $# -ge 2 ] || fail "--keystore needs a path."
      ks_path="$2"
      shift 2
      ;;
    --repo)
      [ $# -ge 2 ] || fail "--repo needs OWNER/NAME."
      repo_hint="$2"
      shift 2
      ;;
    --allow-non-target-repo)
      allow_non_target_repo=1
      shift
      ;;
    --yes|-y)
      assume_yes=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      usage >&2
      fail "Unknown option: $1"
      ;;
  esac
done

store_pass="${MELO_KEYSTORE_PASSWORD:-}"
key_pass="${MELO_KEY_PASSWORD:-}"
alias_name="${MELO_KEY_ALIAS:-}"

cleanup() {
  local status=$?
  unset store_pass key_pass
  exit "$status"
}
trap cleanup EXIT

command -v "$keytool_bin" >/dev/null 2>&1 \
  || fail "keytool was not found. Install a JDK (for example: pkg install openjdk-17)."
command -v base64 >/dev/null 2>&1 \
  || fail "base64 was not found. Install coreutils (for example: pkg install coreutils)."

if ! command -v "$gh_bin" >/dev/null 2>&1; then
  gh_install_help
  exit 1
fi
if ! "$gh_bin" auth status >/dev/null 2>&1; then
  cat >&2 <<'EOF'
GitHub CLI is not authenticated.

Authenticate once, then rerun this helper:
  gh auth login

Choose GitHub.com, HTTPS, and browser login when prompted.
EOF
  exit 1
fi

if [ ! -f "$ks_path" ]; then
  fail "No keystore at $ks_path. This helper never creates or overwrites a signing key. See android/README.md to create one first."
fi
if [ ! -r "$ks_path" ]; then
  fail "The keystore at $ks_path is not readable."
fi

prompt_secret() {
  local prompt="$1"
  local var_name="$2"
  local value=""
  printf '%s' "$prompt" >&2
  IFS= read -r -s value || {
    printf '\n' >&2
    fail "No value entered."
  }
  printf '\n' >&2
  printf -v "$var_name" '%s' "$value"
  unset value
}

if [ -z "$store_pass" ]; then
  prompt_secret "Keystore password (input hidden): " store_pass
fi
if [ -z "$alias_name" ]; then
  printf 'Key alias: ' >&2
  IFS= read -r alias_name || fail "No alias entered."
fi
if [ -z "$key_pass" ]; then
  prompt_secret "Key password (input hidden; press Enter if it matches the keystore password): " key_pass
  if [ -z "$key_pass" ]; then
    key_pass="$store_pass"
  fi
fi
if [ -z "$store_pass" ]; then
  fail "No keystore password was entered."
fi
if [ -z "$alias_name" ]; then
  fail "No key alias was entered."
fi

keytool_out=$(MELO_SETUP_STORE_PASS="$store_pass" "$keytool_bin" \
  -list -keystore "$ks_path" -storepass:env MELO_SETUP_STORE_PASS 2>&1)
keytool_status=$?
if [ "$keytool_status" -ne 0 ]; then
  case "$keytool_out" in
    *"password was incorrect"*|*"tampered with"*)
      fail "The keystore could not be opened. The password may be wrong, or the file may be corrupted or incomplete."
      ;;
    *)
      fail "The keystore could not be read. Is it a valid .jks file?"
      ;;
  esac
fi

keytool_out=$(MELO_SETUP_STORE_PASS="$store_pass" "$keytool_bin" \
  -list -keystore "$ks_path" -storepass:env MELO_SETUP_STORE_PASS -alias "$alias_name" 2>&1)
keytool_status=$?
if [ "$keytool_status" -ne 0 ]; then
  fail "The alias '$alias_name' was not found in the keystore. Run keytool -list -keystore '$ks_path' to see the available aliases."
fi
case "$keytool_out" in
  *PrivateKeyEntry*) ;;
  *) fail "The alias '$alias_name' is not a private-key entry. Choose the alias whose entry type is PrivateKeyEntry." ;;
esac

keytool_out=$(MELO_SETUP_STORE_PASS="$store_pass" MELO_SETUP_KEY_PASS="$key_pass" "$keytool_bin" \
  -certreq -keystore "$ks_path" \
  -storepass:env MELO_SETUP_STORE_PASS \
  -keypass:env MELO_SETUP_KEY_PASS \
  -alias "$alias_name" 2>&1)
keytool_status=$?
if [ "$keytool_status" -ne 0 ]; then
  case "$keytool_out" in
    *"Cannot recover key"*|*"UnrecoverableKeyException"*)
      fail "The key password does not unlock the private key for alias '$alias_name'."
      ;;
    *)
      fail "The private key for alias '$alias_name' is not accessible. Check the alias and key password."
      ;;
  esac
fi
unset keytool_out

valid_repo_name() {
  [[ "$1" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]
}

lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

if [ -n "$repo_hint" ]; then
  repo="$repo_hint"
  valid_repo_name "$repo" || fail "Invalid --repo '$repo'. Use OWNER/NAME with no spaces."
else
  repo=$("$gh_bin" repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null) || repo=""
  if [ -z "$repo" ]; then
    fail "Could not determine the GitHub repository. Refusing to guess. Rerun with --repo $INTENDED_REPO (or --repo OWNER/NAME --allow-non-target-repo for a deliberately different repository)."
  fi
  valid_repo_name "$repo" || fail "gh reported an unexpected repository name. Refusing to upload. Pass --repo $INTENDED_REPO explicitly."
fi

repo_lower=$(lower "$repo")
intended_lower=$(lower "$INTENDED_REPO")
if [ "$repo_lower" = "$intended_lower" ]; then
  alternate_repo=0
else
  alternate_repo=1
fi

if [ "$allow_non_target_repo" -eq 1 ] && [ "$alternate_repo" -eq 0 ]; then
  fail "--allow-non-target-repo is only needed for repositories other than $INTENDED_REPO. Refusing to continue with an ambiguous target."
fi
if [ "$alternate_repo" -eq 1 ] && [ "$allow_non_target_repo" -ne 1 ]; then
  fail "Refusing to upload signing secrets to '$repo'. The intended repository is '$INTENDED_REPO'. If '$repo' is deliberate, rerun with --repo $repo --allow-non-target-repo and confirm the name when prompted."
fi

printf 'Target repository: %s\n' "$repo" >&2

if [ "$alternate_repo" -eq 1 ]; then
  printf 'WARNING: %s is not the intended signing repository (%s).\n' "$repo" "$INTENDED_REPO" >&2
  printf 'The signing key and its passwords will be uploaded to %s.\n' "$repo" >&2
  printf 'Type the repository name exactly (%s) to confirm: ' "$repo" >&2
  IFS= read -r typed_repo || typed_repo=""
  if [ "$typed_repo" != "$repo" ]; then
    printf 'Aborted. Nothing was uploaded.\n' >&2
    exit 1
  fi
elif [ "$assume_yes" != "1" ]; then
  printf 'This updates only the four repository signing secrets; it does not start a release.\n' >&2
  printf 'Upload the four signing secrets to %s? [y/N] ' "$repo" >&2
  IFS= read -r answer || answer=""
  case "$answer" in
    y|Y|yes|YES) ;;
    *)
      printf 'Aborted. Nothing was uploaded.\n' >&2
      exit 1
      ;;
  esac
fi

uploaded_list=""
mark_uploaded() {
  uploaded_list="${uploaded_list}${uploaded_list:+, }$1"
}

partial_upload_failure() {
  local failed="$1"
  printf 'error: could not upload %s.\n' "$failed" >&2
  if [ -n "$uploaded_list" ]; then
    printf 'The repository secrets may now be partially updated. Updated before the failure: %s.\n' "$uploaded_list" >&2
  else
    printf 'No secret upload was confirmed; the remote state is unknown. Check the repository secrets before retrying.\n' >&2
  fi
  printf 'Fix gh authentication or repository permissions, then rerun this helper. Rerunning re-uploads all four secrets and is safe.\n' >&2
  exit 1
}

if ! base64 "$ks_path" 2>/dev/null | tr -d '\r\n' \
  | "$gh_bin" secret set ANDROID_KEYSTORE_BASE64 --repo "$repo" >/dev/null 2>&1; then
  partial_upload_failure ANDROID_KEYSTORE_BASE64
fi
mark_uploaded ANDROID_KEYSTORE_BASE64

if ! printf '%s' "$alias_name" \
  | "$gh_bin" secret set ANDROID_KEY_ALIAS --repo "$repo" >/dev/null 2>&1; then
  partial_upload_failure ANDROID_KEY_ALIAS
fi
mark_uploaded ANDROID_KEY_ALIAS

if ! printf '%s' "$store_pass" \
  | "$gh_bin" secret set ANDROID_KEYSTORE_PASSWORD --repo "$repo" >/dev/null 2>&1; then
  partial_upload_failure ANDROID_KEYSTORE_PASSWORD
fi
mark_uploaded ANDROID_KEYSTORE_PASSWORD

if ! printf '%s' "$key_pass" \
  | "$gh_bin" secret set ANDROID_KEY_PASSWORD --repo "$repo" >/dev/null 2>&1; then
  partial_upload_failure ANDROID_KEY_PASSWORD
fi
mark_uploaded ANDROID_KEY_PASSWORD

unset store_pass key_pass

cat <<EOF
Uploaded the four signing secrets to $repo.
No release was started.

Back up the signing key now:
  * Keep the .jks file ($ks_path) in encrypted storage.
  * Keep both passwords in a password manager.
  * Keep a second encrypted offline copy somewhere else too.
  * Termux home directories are wiped when Termux is reinstalled.
  * Losing this key means you cannot publish updates that install over existing melo versions.
  * Do not store passwords in plaintext files, shell history, chats or issues.
EOF
