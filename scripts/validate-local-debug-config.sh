#!/bin/zsh

set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
    print -u2 -r -- "usage: $0 <local-config> [--print-bundle-identifier|--print-signing-identity]"
    exit 2
fi

config_path="${1:A}"
mode="${2:-}"
if [[ -n "$mode" && "$mode" != "--print-bundle-identifier" && "$mode" != "--print-signing-identity" ]]; then
    print -u2 -r -- "error: unsupported option $mode"
    exit 2
fi

[[ -f "$config_path" ]] || {
    print -u2 -r -- "error: LocalConfig.xcconfig is missing; copy LocalConfig.sample.xcconfig and configure it before building"
    exit 1
}

read_setting() {
    local key="$1"
    /usr/bin/awk -F= -v target="$key" '
        $1 ~ "^[[:space:]]*" target "[[:space:]]*$" {
            value = $2
            sub(/^[[:space:]]+/, "", value)
            sub(/[[:space:]]+$/, "", value)
            print value
            exit
        }
    ' "$config_path"
}

development_team="$(read_setting DEVELOPMENT_TEAM)"
bundle_identifier_prefix="$(read_setting BUNDLE_IDENTIFIER_PREFIX)"
local_signing_identity="$(read_setting LOCAL_CODE_SIGN_IDENTITY)"

if [[ -n "$local_signing_identity" ]]; then
    [[ "$local_signing_identity" =~ '^[A-Fa-f0-9]{40}$' ]] || {
        print -u2 -r -- "error: LOCAL_CODE_SIGN_IDENTITY must be a certificate SHA-1 fingerprint, not an ad-hoc identity or certificate name"
        exit 1
    }
fi
[[ -n "$development_team" || -n "$local_signing_identity" ]] || {
    print -u2 -r -- "error: DEVELOPMENT_TEAM must be configured in LocalConfig.xcconfig"
    exit 1
}
[[ -n "$bundle_identifier_prefix" && "$bundle_identifier_prefix" != "com.example" ]] || {
    print -u2 -r -- "error: BUNDLE_IDENTIFIER_PREFIX must be configured in LocalConfig.xcconfig"
    exit 1
}
[[ "$bundle_identifier_prefix" != .* \
    && "$bundle_identifier_prefix" != *. \
    && "$bundle_identifier_prefix" != *..* \
    && "$bundle_identifier_prefix" =~ '^[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]$' ]] || {
    print -u2 -r -- "error: BUNDLE_IDENTIFIER_PREFIX is not a valid reverse-DNS prefix"
    exit 1
}

bundle_identifier="$bundle_identifier_prefix.mactools.dev"
if [[ "$mode" == "--print-bundle-identifier" ]]; then
    print -r -- "$bundle_identifier"
elif [[ "$mode" == "--print-signing-identity" ]]; then
    print -r -- "$local_signing_identity"
fi
