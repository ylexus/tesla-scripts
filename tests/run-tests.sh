#!/usr/bin/env bash
# Runs everything that can be checked without a Tesla account:
#
#   bash tests/run-tests.sh
#
# Set TESLA_SKIP_AUTOCAPTURE=1 to skip the macOS URL-handler tests, which
# briefly register a tesla:// handler for the current user.
set -uo pipefail

HERE=$(unset CDPATH; cd -- "$(dirname -- "$0")" && pwd)
SRC=${1:-$HERE/../get-tesla-owner-token.sh}
RC=0

hdr() { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }

hdr "shellcheck"
if command -v shellcheck >/dev/null 2>&1; then
	if shellcheck "$SRC" "$HERE/unit.sh" "$HERE/e2e.sh" "$HERE/run-tests.sh"; then
		echo "  clean"
	else
		RC=1
	fi
else
	echo "  skip (shellcheck not installed)"
fi

hdr "syntax"
for sh in bash /bin/bash; do
	if command -v "$sh" >/dev/null 2>&1; then
		if "$sh" -n "$SRC"; then
			printf '  ok   %s (%s)\n' "$sh" "$("$sh" --version 2>/dev/null | head -1)"
		else
			RC=1
		fi
	fi
done

hdr "unit"
bash "$HERE/unit.sh" "$SRC" || RC=1

hdr "end-to-end"
bash "$HERE/e2e.sh" "$SRC" || RC=1

printf '\n'
if [ "$RC" -eq 0 ]; then printf '\033[32mALL TESTS PASSED\033[0m\n'; else printf '\033[31mFAILURES\033[0m\n'; fi
exit "$RC"
