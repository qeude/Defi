#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCAL_ENV_FILE="$ROOT_DIR/.env.local"

IDENTITY_WAS_SET=0
TEAM_WAS_SET=0
if [[ "${DEFI_CODESIGN_IDENTITY+x}" == "x" ]]; then
  IDENTITY_WAS_SET=1
fi
if [[ "${DEFI_DEVELOPMENT_TEAM+x}" == "x" ]]; then
  TEAM_WAS_SET=1
fi

trim() {
  sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

load_local_environment() {
  [[ -f "$LOCAL_ENV_FILE" ]] || return 0

  local line key value value_length
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="$(printf '%s' "$line" | trim)"
    [[ -z "$line" || "$line" == \#* ]] && continue

    if [[ "$line" =~ ^(export[[:space:]]+)?(DEFI_CODESIGN_IDENTITY|DEFI_DEVELOPMENT_TEAM)[[:space:]]*=(.*)$ ]]; then
      key="${BASH_REMATCH[2]}"
      value="$(printf '%s' "${BASH_REMATCH[3]}" | trim)"
      value_length="${#value}"
      if (( value_length >= 2 )) && { [[ "$value" == \"*\" ]] || [[ "$value" == \'*\' ]]; }; then
        value="${value:1:value_length-2}"
      fi

      case "$key" in
        DEFI_CODESIGN_IDENTITY)
          if [[ "$IDENTITY_WAS_SET" -eq 0 ]]; then
            DEFI_CODESIGN_IDENTITY="$value"
          fi
          ;;
        DEFI_DEVELOPMENT_TEAM)
          if [[ "$TEAM_WAS_SET" -eq 0 ]]; then
            DEFI_DEVELOPMENT_TEAM="$value"
          fi
          ;;
      esac
    else
      echo "Unsupported entry in $LOCAL_ENV_FILE: $line" >&2
      exit 1
    fi
  done < "$LOCAL_ENV_FILE"
}

load_local_environment

if [[ -n "${DEFI_CODESIGN_IDENTITY:-}" ]]; then
  printf '%s\n' "$DEFI_CODESIGN_IDENTITY"
  exit 0
fi

IDENTITY_OUTPUT="$(security find-identity -p codesigning -v)"
DEVELOPMENT_IDENTITIES="$(
  printf '%s\n' "$IDENTITY_OUTPUT" |
    awk '$0 ~ /Apple Development:/ { print $2 }'
)"
IDENTITY_COUNT="$(printf '%s\n' "$DEVELOPMENT_IDENTITIES" | awk 'NF { count++ } END { print count + 0 }')"

if [[ "$IDENTITY_COUNT" -eq 0 ]]; then
  echo "No Apple Development signing identity found." >&2
  exit 1
fi

TEAM_ID="${DEFI_DEVELOPMENT_TEAM:-}"
if [[ -z "$TEAM_ID" ]]; then
  if [[ "$IDENTITY_COUNT" -eq 1 ]]; then
    printf '%s\n' "$DEVELOPMENT_IDENTITIES"
    exit 0
  fi

  echo "Multiple Apple Development signing identities found:" >&2
  printf '%s\n' "$IDENTITY_OUTPUT" | awk '$0 ~ /Apple Development:/ { sub(/^[[:space:]]+/, ""); print "  " $0 }' >&2
  echo "Set DEFI_DEVELOPMENT_TEAM in .env.local or the environment." >&2
  exit 1
fi

if [[ ! "$TEAM_ID" =~ ^[[:alnum:]]+$ ]]; then
  echo "Invalid DEFI_DEVELOPMENT_TEAM: $TEAM_ID" >&2
  exit 1
fi

CERTIFICATE_DIRECTORY="$(mktemp -d "${TMPDIR:-/tmp}/defi-signing.XXXXXX")"
cleanup() {
  rm -rf -- "$CERTIFICATE_DIRECTORY"
}
trap cleanup EXIT

security find-certificate -a -c "Apple Development:" -p |
  awk -v directory="$CERTIFICATE_DIRECTORY" '
    /-----BEGIN CERTIFICATE-----/ {
      certificate++
      path = sprintf("%s/certificate-%d.pem", directory, certificate)
      writing = 1
    }
    writing { print >> path }
    /-----END CERTIFICATE-----/ {
      close(path)
      writing = 0
    }
  '

TEAM_FINGERPRINTS=""
for certificate in "$CERTIFICATE_DIRECTORY"/*.pem; do
  [[ -e "$certificate" ]] || continue
  subject="$(openssl x509 -in "$certificate" -noout -subject -nameopt RFC2253)"
  case "$subject" in
    *",OU=$TEAM_ID,"*)
      fingerprint="$(
        openssl x509 -in "$certificate" -noout -fingerprint -sha1 |
          awk -F= '{ gsub(":", "", $2); print toupper($2) }'
      )"
      TEAM_FINGERPRINTS="${TEAM_FINGERPRINTS}${fingerprint}"$'\n'
      ;;
  esac
done

MATCHING_IDENTITIES=""
while IFS= read -r identity; do
  [[ -n "$identity" ]] || continue
  if printf '%s' "$TEAM_FINGERPRINTS" | grep -Fqx "$identity"; then
    MATCHING_IDENTITIES="${MATCHING_IDENTITIES}${identity}"$'\n'
  fi
done <<< "$DEVELOPMENT_IDENTITIES"

MATCH_COUNT="$(printf '%s' "$MATCHING_IDENTITIES" | awk 'NF { count++ } END { print count + 0 }')"
case "$MATCH_COUNT" in
  0)
    echo "No valid Apple Development identity found for team $TEAM_ID." >&2
    exit 1
    ;;
  1)
    printf '%s' "$MATCHING_IDENTITIES"
    ;;
  *)
    echo "Multiple Apple Development identities found for team $TEAM_ID." >&2
    echo "Set DEFI_CODESIGN_IDENTITY to an exact SHA-1 fingerprint." >&2
    exit 1
    ;;
esac
