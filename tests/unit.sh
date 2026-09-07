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
# shellcheck disable=SC1091,SC2154,SC2034
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

echo "== curl config escaping =="
eq "conf line" 'header = "Authorization: Bearer abc"' "$(curl_conf_line header 'Authorization: Bearer abc')"
eq "conf escapes" 'url = "a\"b\\c"' "$(curl_conf_line url 'a"b\c')"

echo "== json_escape =="
eq "json_escape" 'a\"b\\c' "$(json_escape 'a"b\c')"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
