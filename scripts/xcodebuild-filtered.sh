#!/bin/zsh
set -o pipefail

# A pinned local certificate is an opt-in for signed Debug builds only.
# Explicit signing arguments (including unsigned XCTest builds) take precedence.
configuration=""
explicit_signing=false
arguments=("$@")
for (( index = 1; index <= ${#arguments}; index++ )); do
    if [[ "${arguments[$index]}" == "-configuration" ]]; then
        configuration="${arguments[$((index + 1))]:-}"
    fi
    case "${arguments[$index]}" in
        CODE_SIGN*=*|DEVELOPMENT_TEAM=*) explicit_signing=true ;;
    esac
done
if [[ "$configuration" == "Debug" && "$explicit_signing" == false ]]; then
    repository_root="${0:A:h:h}"
    local_identity="$("$repository_root/scripts/validate-local-debug-config.sh" \
        "$repository_root/LocalConfig.xcconfig" --print-signing-identity)" || exit 1
    if [[ -n "$local_identity" ]]; then
        arguments+=("CODE_SIGN_STYLE=Manual" "CODE_SIGN_IDENTITY=$local_identity" "DEVELOPMENT_TEAM=")
    fi
fi

if [[ -z "${PYTHON3:-}" ]]; then
    if [[ -x /usr/bin/python3 ]]; then
        PYTHON3=/usr/bin/python3
    else
        PYTHON3=python3
    fi
fi

tmp_stderr="$(mktemp "${TMPDIR:-/tmp}/mactools-xcodebuild-stderr.XXXXXX")"
trap 'rm -f "$tmp_stderr"' EXIT

xcodebuild "${arguments[@]}" 2> "$tmp_stderr"
xcodebuild_status=$?

"$PYTHON3" - "$tmp_stderr" <<'PY'
import re
import sys

path = sys.argv[1]
try:
    text = open(path, encoding="utf-8", errors="replace").read()
except OSError:
    sys.exit(0)

patterns = [
    re.compile(
        r"(?m)^[^\n]*DVTErrorPresenter: Unable to load simulator devices\.\n"
        r"Domain: DVTCoreSimulatorAdditionsErrorDomain\n"
        r"Code: 3\n"
        r"Failure Reason: The version of the CoreSimulator framework installed on this Mac is out-of-date[^\n]*\n"
        r"(?:Recovery Suggestion: [^\n]*\n)?"
        r"--\n"
        r"CoreSimulator is out of date\. Current version [^\n]*\n"
        r"Domain: DVTCoreSimulatorAdditionsErrorDomain\n"
        r"Code: 3\n"
        r"--\n\n?"
    ),
    re.compile(
        r"(?m)^.*iOSSimulator: \[SimServiceContext sharedServiceContextForDeveloperDir:error:\] "
        r"returned nil \(Error Domain=DVTCoreSimulatorAdditionsErrorDomain Code=3 "
        r"\"CoreSimulator is out of date\..*?Simulator device support disabled\.\n?"
    ),
]

filtered = text
for pattern in patterns:
    filtered = pattern.sub("", filtered)

if filtered != text:
    open(path, "w", encoding="utf-8").write(filtered)
PY

cat "$tmp_stderr" >&2
exit "$xcodebuild_status"
