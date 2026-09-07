#!/usr/bin/env bash
# End-to-end tests for get-tesla-owner-token.sh.
#
# Spins up a local fake of Tesla's token endpoint and Owner API, points a copy
# of the script at it, and drives the real flows. No Tesla account and no
# network access are needed.
#
#   bash tests/e2e.sh [path-to-script]
#
set -uo pipefail

HERE=$(unset CDPATH; cd -- "$(dirname -- "$0")" && pwd)
SRC=${1:-$HERE/../get-tesla-owner-token.sh}
[ -f "$SRC" ] || { echo "no such script: $SRC" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "e2e tests need python3" >&2; exit 2; }

TMP=$(mktemp -d)
SERVER_PID=""
cleanup() {
	[ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null
	rm -rf "$TMP"
}
trap cleanup EXIT

PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
no() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n     expected: [%s]\n     actual:   [%s]\n' "$1" "$2" "$3"; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "$2" "$3"; fi; }
has() { case $3 in *"$2"*) ok "$1" ;; *) no "$1" "contains: $2" "$3" ;; esac; }
hasnt() { case $3 in *"$2"*) no "$1" "must not contain: $2" "$3" ;; *) ok "$1" ;; esac; }

python3 "$HERE/fake-tesla-server.py" "$TMP/req.json" > "$TMP/port" 2>/dev/null &
SERVER_PID=$!
for _ in $(seq 1 40); do [ -s "$TMP/port" ] && break; sleep 0.25; done
PORT=$(cat "$TMP/port" 2>/dev/null)
[ -n "$PORT" ] || { echo "fake server failed to start" >&2; exit 1; }
BASE="http://127.0.0.1:$PORT"

# A copy of the script whose endpoints point at the fake server.
# $1 = token path on the fake server (default /token)
mkscript() {
	sed -e "s#^TOKEN_URL=.*#TOKEN_URL=\"$BASE${1:-/token}\"#" \
	    -e "s#^TOKEN_URL_CN=.*#TOKEN_URL_CN=\"$BASE/token\"#" \
	    "$SRC" > "$TMP/s.sh"
	printf '%s' "$TMP/s.sh"
}
# Count leftover macOS handler bundles (find, not ls: shellcheck SC2012).
leftover_bundles() {
	find "$HOME/Library/Caches" -maxdepth 1 -name 'tesla-scripts.*' 2>/dev/null | wc -l | tr -d ' '
}
req_field() { python3 -c "import json,sys;print(json.load(open('$TMP/req.json')).get(sys.argv[1],''))" "$1"; }

S=$(mkscript /token)
CB='tesla://auth/callback?code=THECODE&issuer=https%3A%2F%2Fauth.tesla.com%2Foauth2%2Fv3'

echo "== interactive exchange =="
out=$(printf '%s\n' "$CB" | bash "$S" --manual --json 2>/dev/null); rc=$?
eq "exit 0"            0 "$rc"
has "access_token"     '"access_token":"ACCESS.TOKEN.aaa-_1"' "$out"
has "refresh_token"    '"refresh_token":"REFRESH.TOKEN.bbb-_2"' "$out"
has "expires_in"       '"expires_in":28800' "$out"
eq  "grant_type sent"  'authorization_code' "$(req_field grant_type)"
eq  "client_id sent"   'ownerapi' "$(req_field client_id)"
eq  "code sent"        'THECODE' "$(req_field code)"
eq  "redirect_uri sent, unmangled" 'tesla://auth/callback' "$(req_field redirect_uri)"
v=$(req_field code_verifier); eq "code_verifier length 86" 86 "${#v}"

echo "== issuer selects the region =="
out=$(printf '%s\n' 'tesla://auth/callback?code=C&issuer=https%3A%2F%2Fauth.tesla.cn%2Foauth2%2Fv3' | bash "$S" --manual --json 2>/dev/null)
has "cn issuer -> china" '"region":"china"' "$out"
out=$(printf '%s\n' "$CB" | bash "$S" --manual --json 2>/dev/null)
has "com issuer -> global" '"region":"global"' "$out"

echo "== callback error handling =="
err=$(printf '%s\n' 'tesla://auth/callback?code=X&state=DEADBEEF' | bash "$S" --manual 2>&1 >/dev/null); rc=$?
eq  "state mismatch exits 1" 1 "$rc"
has "state mismatch explained" 'state mismatch' "$err"
err=$(printf '%s\n' 'tesla://auth/callback?error=login_cancelled' | bash "$S" --manual 2>&1 >/dev/null); rc=$?
eq  "login_cancelled exits 0" 0 "$rc"
has "login_cancelled message" 'cancelled' "$err"
err=$(printf '%s\n' 'tesla://auth/callback?error=server_error&error_description=boom' | bash "$S" --manual 2>&1 >/dev/null); rc=$?
eq  "other error exits 1" 1 "$rc"
has "other error described" 'boom' "$err"
err=$(printf '\n' | bash "$S" --manual 2>&1 >/dev/null); rc=$?
eq  "empty input exits 1" 1 "$rc"

echo "== token endpoint failures =="
SN=$(mkscript /token-noref)
err=$(TESLA_REFRESH_TOKEN=X bash "$SN" --refresh 2>&1 >/dev/null </dev/null); rc=$?
eq  "missing refresh_token is fatal" 1 "$rc"
has "missing refresh_token explained" 'no refresh_token' "$err"
SB=$(mkscript /token-badredirect)
err=$(TESLA_REFRESH_TOKEN=X bash "$SB" --refresh 2>&1 >/dev/null </dev/null); rc=$?
eq  "redirect_uri error exits 1" 1 "$rc"
has "void/callback explained" 'void/callback' "$err"

echo "== refresh: token sources =="
S=$(mkscript /token)
out=$(TESLA_REFRESH_TOKEN=ENVTOK bash "$S" --refresh --json </dev/null 2>/dev/null)
eq "env var used"        'ENVTOK' "$(req_field refresh_token)"
has "refresh succeeded"  '"access_token"' "$out"
printf 'STDINTOK\n' | TESLA_REFRESH_TOKEN=ENVLOSES bash "$S" --refresh - --json >/dev/null 2>&1
eq "explicit - beats env" 'STDINTOK' "$(req_field refresh_token)"
TESLA_REFRESH_TOKEN=ENVLOSES bash "$S" --refresh ARGTOK --json </dev/null >/dev/null 2>&1
eq "argument beats env"   'ARGTOK' "$(req_field refresh_token)"
bash "$S" --refresh=EQTOK --json </dev/null >/dev/null 2>&1
eq "--refresh=TOKEN form" 'EQTOK' "$(req_field refresh_token)"
printf 'PIPEDTOK\n' | bash "$S" --refresh --json >/dev/null 2>&1
eq "piped stdin, no env"  'PIPEDTOK' "$(req_field refresh_token)"
eq "refresh grant_type"   'refresh_token' "$(req_field grant_type)"
eq "refresh scope"        'openid email offline_access' "$(req_field scope)"

echo "== mint backend (TLS stack for the token exchange) =="
out_curl=$(printf '%s\n' "$CB" | bash "$S" --manual --json --mint-with curl 2>/dev/null)
has "curl backend mints" '"access_token":"ACCESS.TOKEN.aaa-_1"' "$out_curl"
eq  "curl backend sends redirect_uri" 'tesla://auth/callback' "$(req_field redirect_uri)"
if python3 -c 'import ssl,sys; sys.exit(0 if "openssl" in ssl.OPENSSL_VERSION.lower() else 1)' 2>/dev/null; then
	out_py=$(printf '%s\n' "$CB" | bash "$S" --manual --json --mint-with python 2>/dev/null)
	has "python backend mints" '"access_token":"ACCESS.TOKEN.aaa-_1"' "$out_py"
	eq  "python backend sends redirect_uri" 'tesla://auth/callback' "$(req_field redirect_uri)"
	eq  "python backend sends grant_type"   'authorization_code' "$(req_field grant_type)"
	v=$(req_field code_verifier); eq "python backend sends verifier" 86 "${#v}"
	n1=$(printf '%s' "$out_curl" | sed 's/"expires_at":[0-9]*//')
	n2=$(printf '%s' "$out_py"   | sed 's/"expires_at":[0-9]*//')
	eq "both backends produce identical output" "$n1" "$n2"
	printf 'PYREFRESH\n' | bash "$S" --refresh - --json --mint-with python >/dev/null 2>&1
	eq "python backend refreshes" 'PYREFRESH' "$(req_field refresh_token)"
else
	echo "  skip (python3 has no OpenSSL)"
fi
bash "$S" --mint-with bogus >/dev/null 2>&1; eq "bad --mint-with exits 2" 2 "$?"

# Windows rarely has "python3" on PATH. Check the other two spellings resolve.
PYBIN=$(command -v python3 2>/dev/null || true)
if [ -n "$PYBIN" ]; then
	mkdir -p "$TMP/spell"
	ln -sf "$PYBIN" "$TMP/spell/python"
	printf '#!/bin/sh\nshift\nexec %s "$@"\n' "$PYBIN" > "$TMP/spell/py"
	chmod +x "$TMP/spell/py"
	out=$(printf '%s\n' "$CB" | PATH="$TMP/spell:/usr/bin:/bin" bash "$S" --manual --json --mint-with python 2>&1)
	has "finds 'python' when python3 is absent" '"access_token"' "$out"
	rm -f "$TMP/spell/python"
	out=$(printf '%s\n' "$CB" | PATH="$TMP/spell:/usr/bin:/bin" bash "$S" --manual --json --mint-with python 2>&1)
	has "falls back to 'py -3'" '"access_token"' "$out"
fi

echo "== jq fallback parity =="
mkdir -p "$TMP/nojq"
out_jq=$(printf '%s\n' "$CB" | bash "$S" --manual --json 2>/dev/null)
out_nojq=$(printf '%s\n' "$CB" | PATH="/usr/bin:/bin" bash "$S" --manual --json 2>/dev/null)
n1=$(printf '%s' "$out_jq"   | sed 's/"expires_at":[0-9]*//')
n2=$(printf '%s' "$out_nojq" | sed 's/"expires_at":[0-9]*//')
eq "output identical with and without jq" "$n1" "$n2"
printf '#!/bin/sh\nexit 127\n' > "$TMP/nojq/jq"; chmod +x "$TMP/nojq/jq"
out_broken=$(printf '%s\n' "$CB" | PATH="$TMP/nojq:$PATH" bash "$S" --manual --json 2>/dev/null)
n3=$(printf '%s' "$out_broken" | sed 's/"expires_at":[0-9]*//')
eq "a broken jq falls back cleanly" "$n1" "$n3"

echo "== usage =="
bash "$S" --help >/dev/null 2>&1; eq "--help exits 0" 0 "$?"
out=$(bash "$S" --help 2>&1)
has "--help documents --manual" '--manual' "$out"
has "--help documents --mint-with" '--mint-with' "$out"
bash "$S" --bogus >/dev/null 2>&1; eq "unknown flag exits 2" 2 "$?"
# Match any version rather than a literal, so a bump does not break the test.
out=$(bash "$S" --version 2>&1)
case $out in
	*[0-9].[0-9]*) ok "--version prints a version" ;;
	*) no "--version prints a version" "something like 1.2.3" "$out" ;;
esac

echo "== interactive prompts (pty) =="
# Piped stdin skips the [Y/n] prompts entirely, so drive a real terminal.
# open_url is stubbed so no browser actually launches.
python3 - "$S" "$TMP/pty.sh" <<'STUB'
import sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src).read()
i = s.index('open_url() {')
j = s.index('\n\treturn 1\n}\n', i) + len('\n\treturn 1\n}\n')
s = s[:i] + 'open_url() {\n\tprintf "STUBOPEN %s\\n" "$1" >&2\n\treturn 0\n}\n' + s[j:]
open(dst, 'w').write(s)
STUB
if [ -f "$TMP/pty.sh" ]; then
	out=$(REPLIES=$(printf 'n\037%s\037n' "$CB") python3 "$HERE/drive-pty.py" bash "$TMP/pty.sh" --manual 2>&1)
	hasnt "answering n does not launch a browser" 'STUBOPEN' "$out"
	has  "paste after declining still works" 'ACCESS TOKEN' "$out"
	out=$(REPLIES=$(printf 'y\037%s\037n' "$CB") python3 "$HERE/drive-pty.py" bash "$TMP/pty.sh" --manual 2>&1)
	has  "answering y launches the browser" 'STUBOPEN https://auth.tesla.com' "$out"
	has  "browser-launched confirmation" 'Browser launched' "$out"
else
	no "pty stub built" "a stubbed script" "none"
fi

echo "== automatic callback capture =="
if [ "$(uname -s)" = "Darwin" ] && [ -z "${TESLA_SKIP_AUTOCAPTURE:-}" ]; then
	LSR=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
	before=$("$LSR" -dump 2>/dev/null | grep -c 'claimed schemes:.*tesla:')
	bash "$S" --json --no-browser >"$TMP/auto.out" 2>"$TMP/auto.err" </dev/null &
	ap=$!
	for _ in $(seq 1 60); do grep -q 'waiting for the callback' "$TMP/auto.err" 2>/dev/null && break; sleep 0.25; done
	st=$(grep -o 'state=[0-9a-f]*' "$TMP/auto.err" | head -1 | cut -d= -f2)
	if [ -n "$st" ]; then
		open "tesla://auth/callback?code=AUTOCAP&state=$st&issuer=https%3A%2F%2Fauth.tesla.com%2Foauth2%2Fv3" 2>/dev/null
		wait $ap; rc=$?
		eq  "auto-capture exits 0" 0 "$rc"
		has "auto-capture got tokens" '"access_token"' "$(cat "$TMP/auto.out")"
		eq  "auto-captured code exchanged" 'AUTOCAP' "$(req_field code)"
		hasnt "state was not warned about" 'CSRF check skipped' "$(cat "$TMP/auto.err")"
	else
		no "auto-capture armed" "a state in the authorize URL" "none"
		kill $ap 2>/dev/null; wait $ap 2>/dev/null
	fi
	sleep 1
	after=$("$LSR" -dump 2>/dev/null | grep -c 'claimed schemes:.*tesla:')
	eq "handler unregistered afterwards" "$before" "$after"
	eq "no leftover bundle" 0 "$(leftover_bundles)"

	echo "== capture cleanup on SIGTERM =="
	bash "$S" --json --no-browser >/dev/null 2>"$TMP/k.err" </dev/null &
	kp=$!
	for _ in $(seq 1 60); do grep -q 'waiting for the callback' "$TMP/k.err" 2>/dev/null && break; sleep 0.25; done
	kill -TERM $kp 2>/dev/null
	waited=0
	while kill -0 $kp 2>/dev/null && [ $waited -lt 15 ]; do sleep 1; waited=$((waited + 1)); done
	if kill -0 $kp 2>/dev/null; then
		no "SIGTERM terminates the script" "exited" "still running after ${waited}s"
		kill -9 $kp 2>/dev/null
	else
		ok "SIGTERM terminates the script"
	fi
	wait $kp 2>/dev/null
	sleep 1
	eq "handler unregistered after SIGTERM" "$before" "$("$LSR" -dump 2>/dev/null | grep -c 'claimed schemes:.*tesla:')"
	eq "no leftover bundle after SIGTERM" 0 "$(leftover_bundles)"

	echo "== timeout falls back to manual capture =="
	sed 's/^CAPTURE_TIMEOUT=300$/CAPTURE_TIMEOUT=2/' "$S" > "$TMP/to.sh"
	out=$(printf '%s\n' "$CB" | bash "$TMP/to.sh" --json --no-browser 2>"$TMP/to.err")
	has "fell back to manual" 'Falling back to manual capture' "$(cat "$TMP/to.err")"
	has "still produced tokens" '"access_token"' "$out"
else
	echo "  skip (auto-capture e2e is macOS-only; set TESLA_SKIP_AUTOCAPTURE=1 to force skip)"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
