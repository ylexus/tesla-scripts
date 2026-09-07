#!/usr/bin/env bash
# Unit tests for get-tesla-owner-token.sh.
#
# Sources the script with main() suppressed so the individual functions can be
# exercised directly. Run via tests/run-tests.sh, or on its own:
#
#   bash tests/unit.sh [path-to-script]
#
# The functions and QP_* variables under test come from the sourced script,
# which shellcheck cannot follow from here.
# The stubs below are called by the sourced script, not from here (SC2329).
# The Windows-handler tests deliberately run in subshells so PATH and the fake
# reg.exe controls stay local; that isolation is the point (SC2030/SC2031).
# shellcheck disable=SC1091,SC2154,SC2034,SC2329,SC2016,SC2030,SC2031
set -uo pipefail
HERE=$(unset CDPATH; cd -- "$(dirname -- "$0")" && pwd)
SRC=${1:-$HERE/../get-tesla-owner-token.sh}
[ -f "$SRC" ] || { echo "no such script: $SRC" >&2; exit 2; }
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
sed 's/^main "\$@"$/:/' "$SRC" > "$TMP/lib.sh"
# shellcheck disable=SC1090
. "$TMP/lib.sh"
set +e   # the sourced script turns on errexit; tests need it off

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
no()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n     expected: [%s]\n     actual:   [%s]\n' "$1" "$2" "$3"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "$2" "$3"; fi; }

echo "== PKCE (RFC 7636 appendix B) =="
V='dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk'
eq "S256 challenge" 'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM' "$(pkce_challenge "$V")"
gen=$(pkce_verifier)
eq "verifier length 86" 86 "${#gen}"
case $gen in *[!A-Za-z0-9._~-]*) no "verifier unreserved-only" "unreserved" "$gen";; *) ok "verifier unreserved-only";; esac

echo "== urlencode =="
eq "redirect_uri encoding" 'tesla%3A%2F%2Fauth%2Fcallback' "$(urlencode 'tesla://auth/callback')"
eq "scope encoding" 'openid%20email%20offline_access' "$(urlencode 'openid email offline_access')"
eq "unreserved untouched" 'aZ0-._~' "$(urlencode 'aZ0-._~')"
eq "reserved encoded" '%26%3D%3F%2B%25%23' "$(urlencode '&=?+%#')"

echo "== urldecode =="
eq "decode issuer" 'https://auth.tesla.cn/oauth2/v3' "$(urldecode 'https%3A%2F%2Fauth.tesla.cn%2Foauth2%2Fv3')"
eq "decode plus as space" 'a b' "$(urldecode 'a+b')"
eq "decode backslash safe" 'a\nb' "$(urldecode 'a%5Cnb')"

echo "== urldecode: malformed percent-escapes (regression) =="
# A stray % made printf %b emit "missing hex digit for \x" on stderr and
# corrupt or silently truncate the value.
dec() { urldecode "$1" 2>/dev/null; }
eq "trailing bare %"        'abc%'   "$(dec 'abc%')"
eq "invalid hex %zz"        'a%zz'   "$(dec 'a%zz')"
eq "lone % mid-string"      'a%b'    "$(dec 'a%b')"
eq "doubled %%"             'a%%b'   "$(dec 'a%%b')"
eq "% at very end alone"    '%'      "$(dec '%')"
eq "valid escapes still ok" 'AB'     "$(dec '%41%42')"
eq "valid slash"            '/'      "$(dec '%2F')"
eq "lowercase hex"          '/'      "$(dec '%2f')"
eq "mixed valid+invalid"    'a b%zz' "$(dec 'a%20b%zz')"
err_out=$(urldecode 'abc%' 2>&1 >/dev/null)
eq "no stderr noise on malformed input" '' "$err_out"

echo "== urlencode: non-ASCII bytes (regression) =="
# printf "'$c" yields a signed byte, so %02X of 0xC3 printed as FFFFFFFFFFFFFFC3.
eq "utf-8 e-acute" 'caf%C3%A9' "$(urlencode 'café')"
eq "utf-8 euro"    '%E2%82%AC' "$(urlencode '€')"

echo "== authorize URL =="
U=$(build_authorize_url 'CHAL' 'STATE123')
eq "authorize URL byte-exact" \
  'https://auth.tesla.com/oauth2/v3/authorize?response_type=code&client_id=ownerapi&code_challenge=CHAL&code_challenge_method=S256&redirect_uri=tesla%3A%2F%2Fauth%2Fcallback&scope=openid%20email%20offline_access&state=STATE123' "$U"
case $U in *'void/callback'*) no "no void/callback" "absent" "present";; *) ok "no void/callback";; esac

echo "== trim_input =="
eq "trailing CR"      'abc' "$(trim_input $'abc\r')"
eq "surrounding ws"   'abc' "$(trim_input '   abc  ')"
eq "double quotes"    'abc' "$(trim_input '"abc"')"
eq "single quotes"    'abc' "$(trim_input "'abc'")"
eq "quotes+CR+ws"     'tesla://auth/callback?code=x' "$(trim_input $'  "tesla://auth/callback?code=x"\r ')"

echo "== url_host =="
eq "host .com"        'auth.tesla.com' "$(url_host 'https://auth.tesla.com/oauth2/v3')"
eq "host .cn"         'auth.tesla.cn'  "$(url_host 'https://auth.tesla.cn/oauth2/v3')"
eq "host with port"   'auth.tesla.cn'  "$(url_host 'https://auth.tesla.cn:443/oauth2/v3?a=b')"
eq "not substring cn" 'auth.tesla.com' "$(url_host 'https://auth.tesla.com/x?i=auth.tesla.cn')"

echo "== callback parsing =="
CB='tesla://auth/callback?code=ABC123&state=STATE123&issuer=https%3A%2F%2Fauth.tesla.com%2Foauth2%2Fv3'
extract_callback "$CB"; r=$?
eq "normal: parsed as URL" 0 "$r"
eq "normal: code"   'ABC123'   "$QP_code"
eq "normal: state"  'STATE123' "$QP_state"
eq "normal: issuer" 'https://auth.tesla.com/oauth2/v3' "$QP_issuer"
eq "normal: no error" '' "$QP_error"

extract_callback 'tesla://auth/callback?error=login_cancelled&error_description=User%20cancelled'
eq "cancel: error" 'login_cancelled' "$QP_error"
eq "cancel: description" 'User cancelled' "$QP_error_description"
eq "cancel: no code" '' "$QP_code"

extract_callback 'tesla://auth/callback?code=X&state=WRONG&issuer=https%3A%2F%2Fauth.tesla.com%2Foauth2%2Fv3'
if [ "$QP_state" != "STATE123" ]; then ok "mismatched state detected"; else no "mismatched state detected" "differs" "same"; fi

extract_callback 'tesla://auth/callback?code=CN1&state=S&issuer=https%3A%2F%2Fauth.tesla.cn%2Foauth2%2Fv3'
eq "cn: issuer host" 'auth.tesla.cn' "$(url_host "$QP_issuer")"

extract_callback "$(trim_input $'tesla://auth/callback?code=CR1&state=S&issuer=https%3A%2F%2Fauth.tesla.com%2Foauth2%2Fv3\r')"
eq "trailing CR: code"   'CR1' "$QP_code"
eq "trailing CR: issuer" 'https://auth.tesla.com/oauth2/v3' "$QP_issuer"

extract_callback 'bare-code-abcdef0123456789'; r=$?
eq "bare code: signalled" 1 "$r"
eq "bare code: code" 'bare-code-abcdef0123456789' "$QP_code"
eq "bare code: no state" '' "$QP_state"

extract_callback 'code=QS1&state=S2&issuer=https%3A%2F%2Fauth.tesla.com%2Foauth2%2Fv3'; r=$?
eq "bare query string: parsed" 0 "$r"
eq "bare query string: code" 'QS1' "$QP_code"

extract_callback 'tesla://auth/callback?code=FRAG&state=S#zzz'
eq "fragment stripped" 'S' "$QP_state"

echo "== JSON extraction: fallback vs jq =="
SAMPLE='{"access_token":"eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.abc-_123","refresh_token":"eyJrZXkiOiJ2YWwifQ.xyz_-9","id_token":"idtok","expires_in":28800,"state":"of the union","token_type":"Bearer"}'
if command -v jq >/dev/null 2>&1; then
for k in access_token refresh_token expires_in token_type state id_token missing_key; do
  HAVE_JQ=1; a=$(json_get "$SAMPLE" "$k")
  HAVE_JQ=0; b=$(json_get "$SAMPLE" "$k")
  eq "json_get $k (jq==fallback)" "$a" "$b"
done
else echo "  skip (jq not installed): jq-vs-fallback comparisons"; fi
if command -v jq >/dev/null 2>&1; then HAVE_JQ=1; eq "jq expires_in" 28800 "$(json_get "$SAMPLE" expires_in)"; fi
HAVE_JQ=0; eq "fallback expires_in" 28800 "$(json_get "$SAMPLE" expires_in)"
HAVE_JQ=0; eq "fallback access_token" 'eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.abc-_123' "$(json_get "$SAMPLE" access_token)"
ERRJSON='{"error":"invalid_request","error_description":"The redirect_uri supplied is not registered"}'
HAVE_JQ=0; b=$(json_get "$ERRJSON" error_description)
if command -v jq >/dev/null 2>&1; then
  HAVE_JQ=1; a=$(json_get "$ERRJSON" error_description)
  eq "error_description (jq==fallback)" "$a" "$b"
fi
eq "error_description value" 'The redirect_uri supplied is not registered' "$b"
PRETTY=$(printf '{\n  "access_token" : "AAA",\n  "expires_in" : 300,\n  "refresh_token": "RRR"\n}')
HAVE_JQ=0
eq "fallback pretty access_token" 'AAA' "$(json_get "$PRETTY" access_token)"
eq "fallback pretty expires_in"   '300' "$(json_get "$PRETTY" expires_in)"
eq "fallback pretty refresh_token" 'RRR' "$(json_get "$PRETTY" refresh_token)"

echo "== windows handler registration/cleanup (regression) =="
# Fake reg.exe and cygpath so the Windows arming path can run off-Windows.
mkdir -p "$TMP/winbin"
cat > "$TMP/winbin/cygpath" <<'FAKE'
#!/bin/sh
printf 'C:\\fake\\path\n'
FAKE
cat > "$TMP/winbin/reg" <<'FAKE'
#!/bin/sh
printf '%s\n' "$*" >> "$REG_LOG"
[ "$1" = "${REG_FAIL_OP:-none}" ] && exit 1
[ "$1" = query ] && { [ "${REG_KEY_EXISTS:-1}" -eq 1 ] || exit 1; }
exit 0
FAKE
chmod +x "$TMP/winbin/cygpath" "$TMP/winbin/reg"
export REG_LOG="$TMP/reg.log"

# A pre-existing tesla:// handler must never be deleted when we never wrote one.
: > "$REG_LOG"
CAPTURE_REG_WRITTEN=0 CAPTURE_REGBACKUP="" CAPTURE_DIR=""
( PATH="$TMP/winbin:$PATH"; capture_disarm_windows ) >/dev/null 2>&1
if grep -q delete "$REG_LOG"; then
  no "disarm without arming deletes nothing" "no reg delete" "$(tr '\n' ';' < "$REG_LOG")"
else
  ok "disarm without arming deletes nothing"
fi

# If the backup export fails, arming must abort before overwriting the key.
: > "$REG_LOG"
( export REG_FAIL_OP=export REG_KEY_EXISTS=1
  PATH="$TMP/winbin:$PATH"; capture_arm_windows ) >/dev/null 2>&1
rc=$?
eq "failed backup aborts arming" 1 "$rc"
if grep -q '^add' "$REG_LOG"; then
  no "failed backup writes no key" "no reg add" "$(tr '\n' ';' < "$REG_LOG")"
else
  ok "failed backup writes no key"
fi

# With no pre-existing key, arming should still register.
: > "$REG_LOG"
( export REG_FAIL_OP=none REG_KEY_EXISTS=0
  PATH="$TMP/winbin:$PATH"; capture_arm_windows ) >/dev/null 2>&1
rc=$?
eq "arming succeeds with no prior key" 0 "$rc"
if grep -q '^add' "$REG_LOG"; then ok "arming writes the key"; else no "arming writes the key" "reg add" "none"; fi

# Once we did write it, disarm must delete it.
: > "$REG_LOG"
CAPTURE_REG_WRITTEN=1 CAPTURE_REGBACKUP="" CAPTURE_DIR=""
( PATH="$TMP/winbin:$PATH"; capture_disarm_windows ) >/dev/null 2>&1
if grep -q delete "$REG_LOG"; then ok "disarm after arming deletes the key"; else no "disarm after arming deletes the key" "reg delete" "none"; fi
unset REG_LOG

echo "== linux handler cleanup (regression) =="
# With no previous default, the mimeapps association must not be left dangling
# pointing at the .desktop file we just deleted.
lhome=$TMP/lhome
mkdir -p "$lhome/.config" "$lhome/.local/share/applications"
printf '[Default Applications]\nx-scheme-handler/tesla=tesla-scripts-callback-123.desktop\n' \
  > "$lhome/.config/mimeapps.list"
CAPTURE_DESKTOP="$lhome/.local/share/applications/tesla-scripts-callback-123.desktop"
touch "$CAPTURE_DESKTOP"
CAPTURE_DESKTOP_BASE="tesla-scripts-callback-123.desktop"
CAPTURE_PREV_DEFAULT=""
( HOME="$lhome"; XDG_CONFIG_HOME="$lhome/.config"; capture_disarm_linux ) >/dev/null 2>&1
if grep -q 'x-scheme-handler/tesla' "$lhome/.config/mimeapps.list" 2>/dev/null; then
  no "no dangling scheme association left" "association removed" "$(grep 'tesla' "$lhome/.config/mimeapps.list")"
else
  ok "no dangling scheme association left"
fi
CAPTURE_DESKTOP="" CAPTURE_DESKTOP_BASE="" CAPTURE_PREV_DEFAULT=""

echo "== windows browser launch (regression: & truncation) =="
# cmd.exe splits an unquoted URL at the first &, which silently reduced the
# authorize URL to "...authorize?response_type=code" on Git Bash.
# Strip comments first: the branch explains *why* it avoids cmd.exe.
win_branch=$(sed -n '/^open_url() {/,/^}/p' "$SRC" | grep -v '^[[:space:]]*#')
case $win_branch in
  *"cmd.exe"*) no "no cmd.exe in the Windows launcher" "absent" "present" ;;
  *) ok "no cmd.exe in the Windows launcher" ;;
esac
case $win_branch in
  *"rundll32"*) ok "uses rundll32 FileProtocolHandler" ;;
  *) no "uses rundll32 FileProtocolHandler" "present" "absent" ;;
esac
case $win_branch in
  *'Start-Process $env:TESLA_AUTHORIZE_URL'*) ok "PowerShell takes the URL from the environment" ;;
  *) no "PowerShell takes the URL from the environment" "env var" "command line" ;;
esac

echo "== mint backend selection =="
# Stub the two inputs choose_mint_backend reads.
_curl_ver=""
curl_run() { printf '%s\n' "$_curl_ver"; }
_py_found=0
detect_python() { PY_CMD=(python3); return $(( _py_found ? 0 : 1 )); }

pick() { MINT_BACKEND=auto; NATIVE_TLS_FALLBACK=0; choose_mint_backend; }

_curl_ver='curl 8.7.1 (x86_64-apple-darwin25.0) libcurl/8.7.1 (SecureTransport) LibreSSL/3.3.6'
_py_found=1; pick
eq "macOS LibreSSL curl + python  -> python" python "$MINT_BACKEND"
eq "  and no warning"                        0 "$NATIVE_TLS_FALLBACK"
_py_found=0; pick
eq "macOS LibreSSL curl, no python -> curl"  curl "$MINT_BACKEND"
eq "  and warns"                             1 "$NATIVE_TLS_FALLBACK"

# Confirmed in the field: Git for Windows curl on Schannel mints tokens the
# Owner API accepts, so it must not be diverted to python or warned about.
_curl_ver='curl 8.21.0 (aarch64-w64-mingw32) libcurl/8.21.0 Schannel zlib/1.3.2'
_py_found=1; pick
eq "Windows Schannel + python -> curl"   curl "$MINT_BACKEND"
eq "  and no warning"                    0 "$NATIVE_TLS_FALLBACK"
_py_found=0; pick
eq "Windows Schannel, no python -> curl" curl "$MINT_BACKEND"
eq "  and no warning"                    0 "$NATIVE_TLS_FALLBACK"

_curl_ver='curl 8.5.0 (x86_64-pc-linux-gnu) libcurl/8.5.0 OpenSSL/3.0.13 zlib/1.3'
_py_found=1; pick
eq "Linux OpenSSL curl -> curl" curl "$MINT_BACKEND"
eq "  and no warning"           0 "$NATIVE_TLS_FALLBACK"
_curl_ver='curl 8.5.0 (x86_64-pc-linux-gnu) libcurl/8.5.0 GnuTLS/3.8.3'
_py_found=0; pick
eq "GnuTLS curl -> curl" curl "$MINT_BACKEND"
eq "  and no warning"    0 "$NATIVE_TLS_FALLBACK"

MINT_BACKEND=curl;   choose_mint_backend; eq "explicit curl respected"   curl   "$MINT_BACKEND"
MINT_BACKEND=python; choose_mint_backend; eq "explicit python respected" python "$MINT_BACKEND"
unset -f curl_run detect_python

echo "== curl config escaping =="
eq "conf line" 'header = "Authorization: Bearer abc"' "$(curl_conf_line header 'Authorization: Bearer abc')"
eq "conf escapes" 'url = "a\"b\\c"' "$(curl_conf_line url 'a"b\c')"

echo "== json_escape =="
eq "json_escape" 'a\"b\\c' "$(json_escape 'a"b\c')"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
