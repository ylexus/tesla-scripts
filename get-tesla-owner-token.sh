#!/usr/bin/env bash
#
# get-tesla-owner-token.sh - obtain a Tesla Owner API (legacy "ownerapi") access
# token and refresh token using the OAuth 2.0 authorization-code flow with PKCE.
#
# Protocol details follow adriankumpf/tesla_auth (see README.md). Unofficial;
# not affiliated with or endorsed by Tesla.
#
# Targets bash 3.2 (the version macOS ships), so: no associative arrays, no
# ${var,,}, no mapfile/readarray.

set -euo pipefail

VERSION="1.1.3"

# --- Constants (verified against tesla_auth/src/auth.rs) ----------------------

CLIENT_ID="ownerapi"
AUTHORIZE_URL="https://auth.tesla.com/oauth2/v3/authorize"
TOKEN_URL="https://auth.tesla.com/oauth2/v3/token"
TOKEN_URL_CN="https://auth.tesla.cn/oauth2/v3/token"
REDIRECT_URI="tesla://auth/callback"
SCOPE="openid email offline_access"
CURL_TIMEOUT=30

# --- Output helpers ----------------------------------------------------------

if [ -t 2 ]; then
	C_BOLD=$(printf '\033[1m')
	C_DIM=$(printf '\033[2m')
	C_RED=$(printf '\033[31m')
	C_YEL=$(printf '\033[33m')
	C_GRN=$(printf '\033[32m')
	C_OFF=$(printf '\033[0m')
else
	C_BOLD=""; C_DIM=""; C_RED=""; C_YEL=""; C_GRN=""; C_OFF=""
fi

# All human-facing chatter goes to stderr so that stdout carries only results.
msg()  { printf '%s\n' "$*" >&2; }
bold() { printf '%s%s%s\n' "$C_BOLD" "$*" "$C_OFF" >&2; }
warn() { printf '%swarning:%s %s\n' "$C_YEL" "$C_OFF" "$*" >&2; }
err()  { printf '%serror:%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; }
die()  { err "$*"; exit 1; }

usage() {
	cat <<'USAGE_EOF'
get-tesla-owner-token.sh - get a Tesla Owner API token via OAuth2 + PKCE

CALLBACK CAPTURE
  The login ends with a redirect to tesla://auth/callback?code=... By default
  this script registers a temporary handler for the tesla:// URL scheme, so the
  callback is captured automatically and you never touch DevTools. The handler
  is removed when the script exits. Use --manual to opt out; the script also
  falls back to manual capture on its own if the automatic route fails.

USAGE
  get-tesla-owner-token.sh                  Full interactive authorization flow
  get-tesla-owner-token.sh --refresh [TOK]  Exchange a refresh token for a new pair
  get-tesla-owner-token.sh --help

OPTIONS
  --refresh [TOKEN]  Refresh flow. See TOKEN INPUT below.
  --cn               Use the China endpoint (auth.tesla.cn) for --refresh.
                     The interactive flow picks this automatically from the
                     `issuer` parameter in the callback URL.
  --json             Machine-readable output: a single JSON object on stdout.
  --manual           Skip automatic callback capture and paste the callback
                     URL by hand (the DevTools method).
  --mint-with WHICH  TLS stack for the token exchange: curl, python or auto
                     (default). Which stack mints the token matters: tokens
                     minted over some handshakes are accepted by auth.tesla.com
                     and then refused by owner-api. auto uses curl everywhere
                     except when curl is a LibreSSL/SecureTransport build (the
                     macOS system curl), where it prefers python if available.
  --no-browser       Never try to launch a browser; just print the URL.
  --version          Print version and exit.
  --help             This help.

TOKEN INPUT
  Passing a token as a command-line argument leaves it in your shell history and
  in the process list. Prefer one of these instead:

    export TESLA_REFRESH_TOKEN=...   # then: get-tesla-owner-token.sh --refresh
    printf %s "$tok" | get-tesla-owner-token.sh --refresh -

  Resolution order: command-line argument, then stdin if `-` was given, then
  the environment variable, then stdin if it is not a terminal, then an
  interactive (non-echoing) prompt.

OUTPUT
  Both tokens are printed to stdout; everything else goes to stderr, so --json
  output pipes cleanly. Nothing is written to a file, and the script talks to
  nothing except auth.tesla.com or auth.tesla.cn.

EXIT STATUS
  0  success (also when the user cancels the login at Tesla's page)
  1  error
  2  usage error

REQUIREMENTS
  bash, curl, openssl. jq and python3 are used when present but not required.
USAGE_EOF
}

# --- Portability helpers -----------------------------------------------------

# Percent-encode a string per RFC 3986 unreserved set.
urlencode() {
	local LC_ALL=C
	local s=$1 out="" i=0 c len n
	len=${#s}
	while [ "$i" -lt "$len" ]; do
		c=${s:i:1}
		case $c in
			[A-Za-z0-9._~-]) out="$out$c" ;;
			*)
				# printf "'c" yields a *signed* byte, so 0xC3 arrives as -61 and
				# %02X printed it as FFFFFFFFFFFFFFC3. Mask back to 0-255.
				n=$(printf '%d' "'$c")
				out="$out$(printf '%%%02X' "$(( n & 255 ))")"
				;;
		esac
		i=$((i + 1))
	done
	printf '%s' "$out"
}

# Percent-decode a query-string component ('+' means space).
#
# Only well-formed %HH triples are decoded; a stray or malformed % is left
# alone. Blindly rewriting every % to \x made printf report "missing hex digit
# for \x" and either corrupt the value or silently truncate it ("a%b" -> "a").
urldecode() {
	local LC_ALL=C
	local s=$1 esc="" i=0 len c h
	s=${s//+/ }
	len=${#s}
	while [ "$i" -lt "$len" ]; do
		c=${s:i:1}
		if [ "$c" = "%" ] && [ $((i + 3)) -le "$len" ]; then
			h=${s:i+1:2}
			case $h in
				[0-9A-Fa-f][0-9A-Fa-f])
					esc="$esc\\x$h"
					i=$((i + 3))
					continue
					;;
				*) : ;;
			esac
		fi
		# Escape backslashes so the final %b does not eat them.
		case $c in
			\\) esc="$esc\\\\" ;;
			*) esc="$esc$c" ;;
		esac
		i=$((i + 1))
	done
	printf '%b' "$esc"
}

# Trim whitespace, a trailing CR (git-bash paste from Windows tools) and one
# layer of surrounding quotes.
trim_input() {
	local s=$1
	s=${s%$'\r'}
	s=${s#"${s%%[![:space:]]*}"}
	s=${s%"${s##*[![:space:]]}"}
	case $s in
		\"*\") s=${s#\"}; s=${s%\"} ;;
		\'*\') s=${s#\'}; s=${s%\'} ;;
	esac
	s=${s%$'\r'}
	s=${s#"${s%%[![:space:]]*}"}
	s=${s%"${s##*[![:space:]]}"}
	printf '%s' "$s"
}

# JSON-escape a string for our own output.
json_escape() {
	local s=$1
	s=${s//\\/\\\\}
	s=${s//\"/\\\"}
	printf '%s' "$s"
}

HAVE_JQ=0

# json_get <json> <key> -> value on stdout, empty if absent.
# Uses jq when available; otherwise a sed extractor good enough for the flat,
# string/number-only token responses Tesla returns.
json_get() {
	local json=$1 key=$2 val=""
	if [ "$HAVE_JQ" -eq 1 ]; then
		val=$(printf '%s' "$json" | jq -r --arg k "$key" \
			'if type=="object" and has($k) and (.[$k]!=null) then (.[$k]|tostring) else empty end' 2>/dev/null) || val=""
	else
		val=$(printf '%s' "$json" | tr -d '\n\r' |
			sed -n 's/.*"'"$key"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p') || val=""
		if [ -z "$val" ]; then
			val=$(printf '%s' "$json" | tr -d '\n\r' |
				sed -n 's/.*"'"$key"'"[[:space:]]*:[[:space:]]*\(-\{0,1\}[0-9][0-9]*\).*/\1/p') || val=""
		fi
	fi
	printf '%s' "$val"
}

# Parse a query string into QP_code / QP_state / QP_issuer / QP_error /
# QP_error_description.
QP_code=""; QP_state=""; QP_issuer=""; QP_error=""; QP_error_description=""
parse_query() {
	local q=$1 pair key val oldifs
	QP_code=""; QP_state=""; QP_issuer=""; QP_error=""; QP_error_description=""
	oldifs=$IFS
	IFS='&'
	set -f
	for pair in $q; do
		[ -n "$pair" ] || continue
		case $pair in
			*=*) key=${pair%%=*}; val=${pair#*=} ;;
			*)   key=$pair;       val="" ;;
		esac
		case $key in
			code)              QP_code=$(urldecode "$val") ;;
			state)             QP_state=$(urldecode "$val") ;;
			issuer)            QP_issuer=$(urldecode "$val") ;;
			error)             QP_error=$(urldecode "$val") ;;
			error_description) QP_error_description=$(urldecode "$val") ;;
			*) : ;;
		esac
	done
	set +f
	IFS=$oldifs
}

# Extract the host from a URL.
url_host() {
	local u=$1
	u=${u#*://}
	u=${u%%/*}
	u=${u%%\?*}
	u=${u##*@}
	u=${u%%:*}
	printf '%s' "$u"
}

# Human-readable local time for an epoch second, on GNU or BSD date.
fmt_epoch() {
	local ts=$1 out=""
	out=$(date -r "$ts" '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null) ||
		out=$(date -d "@$ts" '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null) || out=""
	printf '%s' "$out"
}

open_url() {
	local url=$1
	case $(uname -s) in
		Darwin)
			if command -v open >/dev/null 2>&1; then
				if open "$url" >/dev/null 2>&1; then return 0; fi
			fi
			;;
		CYGWIN*|MINGW*|MSYS*)
			# Never hand the URL to cmd.exe. There, `&` separates commands, and
			# Windows only auto-quotes arguments that contain spaces - an
			# authorize URL has none, so `cmd //c start "" "$url"` arrives
			# unquoted and is truncated at the first `&`, leaving just
			# ...authorize?response_type=code. The launchers below are started
			# with CreateProcess and receive the URL as a single argument.
			if command -v rundll32 >/dev/null 2>&1; then
				if MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' \
					rundll32 url.dll,FileProtocolHandler "$url" >/dev/null 2>&1; then return 0; fi
			fi
			# PowerShell would read `&` as its call operator, so pass the URL in
			# the environment and keep it off the command line entirely.
			if command -v powershell.exe >/dev/null 2>&1; then
				# shellcheck disable=SC2016  # $env: is PowerShell syntax, not shell
				if TESLA_AUTHORIZE_URL="$url" MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' \
					powershell.exe -NoProfile -NonInteractive \
					-Command 'Start-Process $env:TESLA_AUTHORIZE_URL' >/dev/null 2>&1; then return 0; fi
			fi
			if command -v explorer.exe >/dev/null 2>&1; then
				# explorer.exe returns a non-zero status even on success; ignore it.
				MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' explorer.exe "$url" >/dev/null 2>&1 || :
				return 0
			fi
			;;
		*)
			if command -v xdg-open >/dev/null 2>&1; then
				if xdg-open "$url" >/dev/null 2>&1; then return 0; fi
			fi
			if command -v gio >/dev/null 2>&1; then
				if gio open "$url" >/dev/null 2>&1; then return 0; fi
			fi
			;;
	esac
	return 1
}

# --- HTTP ---------------------------------------------------------------------

# curl wrapper. MSYS/git-bash rewrites arguments that look like POSIX paths,
# which can mangle URLs and the redirect_uri; curl never wants that conversion.
curl_run() {
	local MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'
	export MSYS_NO_PATHCONV MSYS2_ARG_CONV_EXCL
	curl "$@"
}

# Emit one line of a curl config file (`curl -K -`). Secrets are passed this way
# rather than on the command line, so they never appear in `ps` output.
curl_conf_line() {
	local k=$1 v=$2
	v=${v//\\/\\\\}
	v=${v//\"/\\\"}
	printf '%s = "%s"\n' "$k" "$v"
}

HTTP_CODE=""
HTTP_BODY=""

# Which TLS stack mints the token matters. A token minted over a handshake the
# Owner API dislikes authenticates fine at auth.tesla.com and is then refused
# with 403 on every owner-api call - the failure mode described in the
# TeslaMate/batpred reports. macOS ships curl against LibreSSL/SecureTransport;
# python is usually OpenSSL. Prefer whichever looks least likely to be flagged.
MINT_BACKEND="auto"

# Find a Python 3 built against OpenSSL. Windows rarely has "python3" on PATH:
# python.org installs "python" plus the "py" launcher, and only the Microsoft
# Store build provides "python3". So try all three spellings.
PY_CMD=()
NATIVE_TLS_FALLBACK=0

python_probe='import ssl,sys; sys.exit(0 if sys.version_info[0] == 3 and "openssl" in ssl.OPENSSL_VERSION.lower() else 1)'

detect_python() {
	if [ ${#PY_CMD[@]} -gt 0 ]; then return 0; fi
	local c
	for c in python3 python; do
		if command -v "$c" >/dev/null 2>&1; then
			if "$c" -c "$python_probe" >/dev/null 2>&1; then
				PY_CMD=("$c")
				return 0
			fi
		fi
	done
	if command -v py >/dev/null 2>&1; then
		if py -3 -c "$python_probe" >/dev/null 2>&1; then
			PY_CMD=(py -3)
			return 0
		fi
	fi
	return 1
}

# Decide once, at startup.
choose_mint_backend() {
	case $MINT_BACKEND in
		curl|python) return 0 ;;
		*) : ;;
	esac
	case $(curl_run --version 2>/dev/null | head -1 | tr '[:upper:]' '[:lower:]') in
		*libressl*|*securetransport*)
			# The only stack seen to mint tokens that auth.tesla.com issues and
			# the Owner API then refuses with 403: macOS's system curl. Git for
			# Windows curl on Schannel and Linux curl on OpenSSL or GnuTLS have
			# all been confirmed to mint working tokens, so leave them alone.
			if detect_python; then
				MINT_BACKEND="python"
			else
				MINT_BACKEND="curl"
				NATIVE_TLS_FALLBACK=1
			fi
			;;
		*)
			MINT_BACKEND="curl"
			;;
	esac
	return 0
}

# Same contract as post_form, over python's TLS stack.
post_form_python() {
	local url=$1
	shift
	if ! detect_python; then
		err "no Python 3 with OpenSSL found (tried python3, python, py -3)."
		return 1
	fi
	local rc=0 resp="" p
	set +e
	resp=$(
		{ for p in "$@"; do printf '%s\n' "$p"; done; } |
			MINT_URL="$url" "${PY_CMD[@]}" -c 'import os, sys, urllib.parse, urllib.request, urllib.error

class NoRedirect(urllib.request.HTTPRedirectHandler):
    # tesla_auth uses redirect::Policy::none() on the token call.
    def redirect_request(self, *a, **k):
        return None

fields = []
for line in sys.stdin.read().split("\n"):
    if not line:
        continue
    k, _, v = line.partition("=")
    fields.append((k, v))

data = urllib.parse.urlencode(fields).encode()
req = urllib.request.Request(
    os.environ["MINT_URL"], data=data,
    headers={"Content-Type": "application/x-www-form-urlencoded"})
opener = urllib.request.build_opener(NoRedirect)
try:
    with opener.open(req, timeout=30) as r:
        body, code = r.read().decode("utf8", "replace"), r.status
except urllib.error.HTTPError as e:
    body, code = e.read().decode("utf8", "replace"), e.code
except Exception as e:
    sys.stderr.write("python mint failed: %s\n" % e)
    sys.exit(1)
sys.stdout.write(body + "\n" + str(code))
'
	)
	rc=$?
	set -e
	HTTP_CODE=""
	HTTP_BODY=""
	if [ "$rc" -ne 0 ]; then
		err "python transport failed (exit $rc) talking to $url"
		return 1
	fi
	HTTP_CODE=${resp##*$'\n'}
	HTTP_BODY=${resp%$'\n'*}
	return 0
}

# post_form <url> <field=value>... -> sets HTTP_CODE and HTTP_BODY
# Dispatches to the chosen TLS stack.
post_form() {
	if [ "$MINT_BACKEND" = "python" ]; then
		post_form_python "$@"
		return $?
	fi
	post_form_curl "$@"
}

post_form_curl() {
	local url=$1
	shift
	local rc=0 resp="" p
	set +e
	resp=$(
		{
			curl_conf_line url "$url"
			for p in "$@"; do curl_conf_line data-urlencode "$p"; done
		} | curl_run -sS -K - --max-time "$CURL_TIMEOUT" \
			-w $'\n%{http_code}'
	)
	rc=$?
	set -e
	HTTP_CODE=""
	HTTP_BODY=""
	if [ "$rc" -ne 0 ]; then
		err "curl failed (exit $rc) talking to $url"
		return 1
	fi
	HTTP_CODE=${resp##*$'\n'}
	HTTP_BODY=${resp%$'\n'*}
	return 0
}

# --- PKCE ---------------------------------------------------------------------

# 43 random bytes as hex = an 86-character verifier made only of unreserved
# characters, inside RFC 7636's 43-128 range.
pkce_verifier() { openssl rand -hex 43; }

# base64url(SHA256(verifier)), unpadded. `openssl base64 -A` avoids the
# GNU (-w0) versus BSD (no -w) split in the base64 utility.
pkce_challenge() {
	printf '%s' "$1" |
		openssl dgst -sha256 -binary |
		openssl base64 -A |
		tr '+/' '-_' |
		tr -d '='
}

build_authorize_url() {
	local challenge=$1 state=$2
	printf '%s?response_type=code&client_id=%s&code_challenge=%s&code_challenge_method=S256&redirect_uri=%s&scope=%s&state=%s' \
		"$AUTHORIZE_URL" \
		"$(urlencode "$CLIENT_ID")" \
		"$(urlencode "$challenge")" \
		"$(urlencode "$REDIRECT_URI")" \
		"$(urlencode "$SCOPE")" \
		"$(urlencode "$state")"
}

# --- Token handling -----------------------------------------------------------

TOK_access=""
TOK_refresh=""
TOK_expires_in=""
TOK_type=""

# Pull the fields out of a token response, enforcing the same requirements as
# tesla_auth: access_token, refresh_token and expires_in must all be present.
read_token_response() {
	local body=$1 e ed
	TOK_access=$(json_get "$body" access_token)
	TOK_refresh=$(json_get "$body" refresh_token)
	TOK_expires_in=$(json_get "$body" expires_in)
	TOK_type=$(json_get "$body" token_type)
	[ -n "$TOK_type" ] || TOK_type="Bearer"

	e=$(json_get "$body" error)
	ed=$(json_get "$body" error_description)

	if [ -n "$e" ] || [ -n "$ed" ]; then
		err "token endpoint returned an error: ${e:-?}${ed:+ - $ed}"
		explain_redirect_uri_error "$e $ed"
		return 1
	fi
	if [ "$HTTP_CODE" != "200" ]; then
		err "token endpoint returned HTTP $HTTP_CODE"
		msg "$(printf '%s' "$body" | head -c 800)"
		explain_redirect_uri_error "$body"
		return 1
	fi
	if [ -z "$TOK_access" ]; then
		err "no access_token in the response"
		return 1
	fi
	if [ -z "$TOK_refresh" ]; then
		err "no refresh_token in the response (tesla_auth treats this as fatal too)"
		return 1
	fi
	if [ -z "$TOK_expires_in" ]; then
		err "no expires_in in the response (tesla_auth treats this as fatal too)"
		return 1
	fi
	return 0
}

explain_redirect_uri_error() {
	case $1 in
		*redirect_uri*|*redirect*URI*)
			msg ""
			bold "About that redirect_uri error"
			msg "  The only redirect URI registered for client_id=ownerapi is"
			msg "    $REDIRECT_URI"
			msg "  Older guides use https://auth.tesla.com/void/callback, which Tesla"
			msg "  retired. If you edited the authorize URL by hand, put the tesla://"
			msg "  form back. This does not mean the Owner API is gone."
			;;
		*) : ;;
	esac
}

emit_tokens() {
	local now expires_at when
	now=$(date +%s)
	expires_at=$((now + TOK_expires_in))
	when=$(fmt_epoch "$expires_at")

	if [ "$JSON" -eq 1 ]; then
		printf '{"access_token":"%s","refresh_token":"%s","token_type":"%s","expires_in":%s,"expires_at":%s,"region":"%s"}\n' \
			"$(json_escape "$TOK_access")" \
			"$(json_escape "$TOK_refresh")" \
			"$(json_escape "$TOK_type")" \
			"$TOK_expires_in" \
			"$expires_at" \
			"$REGION"
		return 0
	fi

	msg ""
	printf '%sACCESS TOKEN%s\n' "$C_BOLD" "$C_OFF" >&2
	printf '%s\n' "$TOK_access"
	msg ""
	printf '%sREFRESH TOKEN%s\n' "$C_BOLD" "$C_OFF" >&2
	printf '%s\n' "$TOK_refresh"
	msg ""
	msg "token_type: $TOK_type"
	msg "expires_in: ${TOK_expires_in}s${when:+ (at $when)}"
	msg "region:     $REGION"
	msg ""
	msg "${C_DIM}Keep the refresh token. Access tokens are short-lived; refresh with:"
	msg "  export TESLA_REFRESH_TOKEN=...  &&  $PROG --refresh${C_OFF}"
}

# --- Automatic callback capture -----------------------------------------------
#
# tesla_auth captures the tesla://auth/callback redirect because it *is* a native
# app registered for that URL scheme. A shell script can borrow the same trick:
# register a throwaway handler for the run, let the OS hand us the callback, and
# unregister on the way out. Each platform needs its own mechanism, and all of
# them are best-effort - any failure just falls back to the manual DevTools
# capture, which always works.

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
CAPTURE_TIMEOUT=300

CAPTURE_KIND=""
CAPTURE_DIR=""
CAPTURE_FILE=""
CAPTURE_APP=""
CAPTURE_DESKTOP=""
CAPTURE_PREV_DEFAULT=""
CAPTURE_REGBACKUP=""
CAPTURE_REG_WRITTEN=0
CAPTURE_DESKTOP_BASE=""
CAPTURE_ARMED=0
CAPTURE_INTERRUPTED=0
CAPTURED=""

platform() {
	case $(uname -s) in
		Darwin) printf 'macos' ;;
		CYGWIN*|MINGW*|MSYS*) printf 'windows' ;;
		*) printf 'linux' ;;
	esac
}

# reg.exe and cygpath need MSYS path conversion out of the way.
win_run() {
	local MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'
	export MSYS_NO_PATHCONV MSYS2_ARG_CONV_EXCL
	"$@"
}

capture_arm_macos() {
	local plist src
	command -v osacompile >/dev/null 2>&1 || return 1
	[ -x "$LSREGISTER" ] || return 1

	# LaunchServices ignores bundles under /tmp; ~/Library/Caches is indexed.
	CAPTURE_DIR=$(mktemp -d "$HOME/Library/Caches/tesla-scripts.XXXXXX") || return 1
	CAPTURE_FILE="$CAPTURE_DIR/callback.txt"
	CAPTURE_APP="$CAPTURE_DIR/TeslaCallback.app"
	src="$CAPTURE_DIR/handler.applescript"

	cat > "$src" <<APPLESCRIPT
on open location this_URL
	try
		set f to open for access POSIX file "$CAPTURE_FILE" with write permission
		set eof f to 0
		write this_URL to f
		close access f
	end try
	tell me to quit
end open location

on run
	tell me to quit
end run
APPLESCRIPT

	osacompile -o "$CAPTURE_APP" "$src" >/dev/null 2>&1 || return 1
	plist="$CAPTURE_APP/Contents/Info.plist"
	/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes array" "$plist" >/dev/null 2>&1 || return 1
	/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:0 dict" "$plist" >/dev/null 2>&1 || return 1
	/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:0:CFBundleURLName string TeslaAuthCallback" "$plist" >/dev/null 2>&1 || return 1
	/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:0:CFBundleURLSchemes array" "$plist" >/dev/null 2>&1 || return 1
	/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:0:CFBundleURLSchemes:0 string tesla" "$plist" >/dev/null 2>&1 || return 1
	/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier local.tesla-scripts.callback" "$plist" >/dev/null 2>&1 || :
	"$LSREGISTER" -R -f "$CAPTURE_APP" >/dev/null 2>&1 || return 1
	return 0
}

capture_disarm_macos() {
	if [ -n "$CAPTURE_APP" ] && [ -x "$LSREGISTER" ]; then
		"$LSREGISTER" -u "$CAPTURE_APP" >/dev/null 2>&1 || :
	fi
}

capture_arm_windows() {
	local cmdfile winout wincmd
	command -v reg >/dev/null 2>&1 || return 1
	command -v cygpath >/dev/null 2>&1 || return 1

	CAPTURE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/tesla-scripts.XXXXXX") || return 1
	CAPTURE_FILE="$CAPTURE_DIR/callback.txt"
	cmdfile="$CAPTURE_DIR/tesla-callback.cmd"
	winout=$(cygpath -w "$CAPTURE_FILE") || return 1

	# CRLF throughout: cmd.exe is unreliable with LF-only batch files.
	# Delayed expansion (!u!) keeps the & in the query string from being parsed.
	{
		printf '@echo off\r\n'
		printf 'setlocal enabledelayedexpansion\r\n'
		printf 'set "u=%%~1"\r\n'
		printf '> "%s" echo(!u!\r\n' "$winout"
		printf 'endlocal\r\n'
	} > "$cmdfile" || return 1

	wincmd=$(cygpath -w "$cmdfile") || return 1

	# Preserve an existing tesla:// handler so we can put it back. If it cannot
	# be backed up, leave it alone entirely rather than overwrite something we
	# would not be able to restore.
	if win_run reg query "HKCU\\Software\\Classes\\tesla" >/dev/null 2>&1; then
		CAPTURE_REGBACKUP="$CAPTURE_DIR/tesla-key.reg"
		if ! win_run reg export "HKCU\\Software\\Classes\\tesla" \
			"$(cygpath -w "$CAPTURE_REGBACKUP")" /y >/dev/null 2>&1; then
			CAPTURE_REGBACKUP=""
			return 1
		fi
	fi

	# From here on a key may exist that we put there, so cleanup must remove it
	# even if one of the writes below fails part-way.
	CAPTURE_REG_WRITTEN=1
	win_run reg add "HKCU\\Software\\Classes\\tesla" /ve /t REG_SZ \
		/d "URL:Tesla Auth Callback" /f >/dev/null 2>&1 || return 1
	win_run reg add "HKCU\\Software\\Classes\\tesla" /v "URL Protocol" /t REG_SZ \
		/d "" /f >/dev/null 2>&1 || return 1
	win_run reg add "HKCU\\Software\\Classes\\tesla\\shell\\open\\command" /ve /t REG_SZ \
		/d "\"$wincmd\" \"%1\"" /f >/dev/null 2>&1 || return 1
	return 0
}

capture_disarm_windows() {
	# Never delete a key we did not write: arming can fail after `reg` is found
	# but before anything is registered, and blindly deleting would take a real
	# application's tesla:// registration with it.
	if [ "$CAPTURE_REG_WRITTEN" -eq 1 ]; then
		win_run reg delete "HKCU\\Software\\Classes\\tesla" /f >/dev/null 2>&1 || :
		if [ -n "$CAPTURE_REGBACKUP" ] && [ -f "$CAPTURE_REGBACKUP" ]; then
			win_run reg import "$(cygpath -w "$CAPTURE_REGBACKUP")" >/dev/null 2>&1 || :
		fi
	fi
	CAPTURE_REG_WRITTEN=0
}

capture_arm_linux() {
	local appsdir helper base
	command -v xdg-mime >/dev/null 2>&1 || return 1

	CAPTURE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/tesla-scripts.XXXXXX") || return 1
	CAPTURE_FILE="$CAPTURE_DIR/callback.txt"
	helper="$CAPTURE_DIR/tesla-callback.sh"
	appsdir="$HOME/.local/share/applications"
	mkdir -p "$appsdir" || return 1

	cat > "$helper" <<HELPER
#!/bin/sh
printf '%s' "\$1" > "$CAPTURE_FILE"
HELPER
	chmod +x "$helper" || return 1

	base="tesla-scripts-callback-$$.desktop"
	CAPTURE_DESKTOP_BASE=$base
	CAPTURE_DESKTOP="$appsdir/$base"
	cat > "$CAPTURE_DESKTOP" <<DESKTOP
[Desktop Entry]
Type=Application
Name=Tesla Auth Callback (temporary)
Exec=$helper %u
NoDisplay=true
Terminal=false
MimeType=x-scheme-handler/tesla;
DESKTOP

	CAPTURE_PREV_DEFAULT=$(xdg-mime query default x-scheme-handler/tesla 2>/dev/null) || CAPTURE_PREV_DEFAULT=""
	command -v update-desktop-database >/dev/null 2>&1 &&
		update-desktop-database "$appsdir" >/dev/null 2>&1 || :
	xdg-mime default "$base" x-scheme-handler/tesla >/dev/null 2>&1 || return 1
	return 0
}

capture_disarm_linux() {
	local appsdir="$HOME/.local/share/applications"
	local mimeapps tmp
	if [ -n "$CAPTURE_DESKTOP" ] && [ -f "$CAPTURE_DESKTOP" ]; then
		rm -f "$CAPTURE_DESKTOP" || :
	fi
	if [ -n "$CAPTURE_PREV_DEFAULT" ]; then
		xdg-mime default "$CAPTURE_PREV_DEFAULT" x-scheme-handler/tesla >/dev/null 2>&1 || :
	elif [ -n "$CAPTURE_DESKTOP_BASE" ]; then
		# Nothing claimed tesla:// before us and xdg-mime cannot unset a
		# default, so drop the line by hand. Leaving it would point at the
		# .desktop file just deleted - a permanent dangling association.
		for mimeapps in "${XDG_CONFIG_HOME:-$HOME/.config}/mimeapps.list" \
			"$appsdir/mimeapps.list"; do
			[ -f "$mimeapps" ] || continue
			tmp="$mimeapps.tesla-scripts.$$"
			grep -v "^x-scheme-handler/tesla=$CAPTURE_DESKTOP_BASE\$" \
				"$mimeapps" > "$tmp" 2>/dev/null || :
			if [ -f "$tmp" ]; then
				mv "$tmp" "$mimeapps" 2>/dev/null || rm -f "$tmp"
			fi
		done
	fi
	if command -v update-desktop-database >/dev/null 2>&1; then
		update-desktop-database "$appsdir" >/dev/null 2>&1 || :
	fi
}

capture_arm() {
	CAPTURE_KIND=$(platform)
	case $CAPTURE_KIND in
		macos)   capture_arm_macos   || { capture_cleanup; return 1; } ;;
		windows) capture_arm_windows || { capture_cleanup; return 1; } ;;
		linux)   capture_arm_linux   || { capture_cleanup; return 1; } ;;
		*) return 1 ;;
	esac
	CAPTURE_ARMED=1
	return 0
}

# Idempotent, and safe to run from a trap.
capture_cleanup() {
	case $CAPTURE_KIND in
		macos)   capture_disarm_macos ;;
		windows) capture_disarm_windows ;;
		linux)   capture_disarm_linux ;;
		*) : ;;
	esac
	if [ -n "$CAPTURE_DIR" ] && [ -d "$CAPTURE_DIR" ]; then
		rm -rf "$CAPTURE_DIR" || :
	fi
	CAPTURE_DIR=""
	CAPTURE_APP=""
	CAPTURE_DESKTOP=""
	CAPTURE_DESKTOP_BASE=""
	CAPTURE_KIND=""
	CAPTURE_ARMED=0
}

# Poll for the captured callback. Ctrl-C drops out to manual capture rather than
# killing the script.
capture_wait() {
	local waited=0 idx=0 spin='|/-' ch
	CAPTURE_INTERRUPTED=0
	trap 'CAPTURE_INTERRUPTED=1' INT
	while [ "$waited" -lt "$CAPTURE_TIMEOUT" ]; do
		if [ -s "$CAPTURE_FILE" ]; then break; fi
		if [ "$CAPTURE_INTERRUPTED" -eq 1 ]; then break; fi
		if [ -t 2 ]; then
			idx=$(( (idx + 1) % 3 ))
			ch=$(printf '%s' "$spin" | cut -c $((idx + 1)))
			printf '\r  %s  waiting for the callback (%ss elapsed) - Ctrl-C for manual capture  ' \
				"$ch" "$waited" >&2
		fi
		sleep 1
		waited=$((waited + 1))
	done
	trap 'capture_cleanup; exit 130' INT
	if [ -t 2 ]; then printf '\r%*s\r' 76 '' >&2; fi
	if [ -s "$CAPTURE_FILE" ]; then
		CAPTURED=$(cat "$CAPTURE_FILE")
		return 0
	fi
	return 1
}

# --- Flows --------------------------------------------------------------------

# Split a pasted value into query parameters. Returns 0 if it looked like a URL
# or query string, 1 if it was treated as a bare code.
extract_callback() {
	local input=$1 q
	case $input in
		*\?*) q=${input#*\?} ;;
		code=*|*\&code=*|*=*\&*) q=$input ;;
		*)
			parse_query ""
			QP_code=$input
			return 1
			;;
	esac
	q=${q%%#*}
	parse_query "$q"
	return 0
}

print_prelogin_instructions() {
	bold "Step 1 - set your browser up BEFORE you log in"
	msg ""
	msg "  Logging in ends with a redirect to ${C_BOLD}$REDIRECT_URI${C_OFF}, which no"
	msg "  browser can open. You have to read that redirect out of DevTools, and it is"
	msg "  only recorded if you prepare first:"
	msg ""
	msg "    1. Open DevTools: ${C_BOLD}F12${C_OFF} (${C_BOLD}Cmd-Opt-I${C_OFF} on macOS)."
	msg "    2. Switch to the ${C_BOLD}Network${C_OFF} tab."
	msg "    3. Tick ${C_BOLD}Preserve log${C_OFF}."
	msg ""
	msg "  ${C_DIM}Without Preserve log the browser throws the redirect away the moment it"
	msg "  navigates on, and you have to start the whole login again.${C_OFF}"
	msg ""
}

print_postlogin_instructions() {
	bold "Step 3 - copy the callback URL out of DevTools"
	msg ""
	msg "  Log in as usual. Handle 2FA / captcha as normal."
	msg ""
	msg "  When the login finishes the browser will refuse to open"
	msg "  ${C_BOLD}$REDIRECT_URI${C_OFF}, or ask which application should handle"
	msg "  it. ${C_BOLD}That is what success looks like.${C_OFF} Dismiss the dialog."
	msg ""
	msg "  In the ${C_BOLD}Network${C_OFF} tab find the last auth.tesla.com request with status"
	msg "  ${C_BOLD}302${C_OFF}. Open it, look at Response Headers, and copy the whole"
	msg "  ${C_BOLD}Location${C_OFF} value. It starts with ${REDIRECT_URI}?code="
	msg ""
	msg "  ${C_DIM}Firefox: right-click the 302 row and Copy > Copy Location if the"
	msg "  headers pane hides it. Safari: enable the Develop menu first.${C_OFF}"
	msg ""
}

browser_gate() {
	local url=$1 ans=""
	if [ "$NO_BROWSER" -eq 1 ] || [ ! -t 0 ]; then return 0; fi
	printf 'Open the login page in your default browser now? [Y/n] ' >&2
	IFS= read -r ans || :
	case $(printf '%s' "$ans" | tr '[:upper:]' '[:lower:]') in
		n|no) : ;;
		*)
			if open_url "$url"; then
				msg "Browser launched."
			else
				warn "could not launch a browser; copy the URL above by hand."
			fi
			;;
	esac
	msg ""
	return 0
}

prompt_paste() {
	local line=""
	while :; do
		printf 'Paste the tesla://auth/callback URL (or a bare code): ' >&2
		# A pasted URL with no trailing newline makes read return non-zero with
		# the value already in `line`. Only give up when nothing arrived.
		if ! IFS= read -r line && [ -z "$line" ]; then
			msg ""
			die "no input received"
		fi
		line=$(trim_input "$line")
		if [ -n "$line" ]; then break; fi
	done
	printf '%s' "$line"
}

do_interactive() {
	local verifier challenge state url parsed token_url host code_in

	verifier=$(pkce_verifier)
	challenge=$(pkce_challenge "$verifier")
	state=$(openssl rand -hex 16)
	url=$(build_authorize_url "$challenge" "$state")

	if [ "$MANUAL" -eq 0 ]; then
		capture_arm || :
	fi

	if [ "$CAPTURE_ARMED" -eq 1 ]; then
		bold "Step 1 - log in to your Tesla account"
		msg ""
		msg "$url"
		msg ""
		msg "  ${C_DIM}A handler for tesla:// is registered for this run only, so the callback"
		msg "  is picked up automatically - no DevTools needed. It is removed again when"
		msg "  this script exits. Your browser will probably ask for permission to open"
		msg "  it; allow that.${C_OFF}"
		msg ""
		browser_gate "$url"

		bold "Step 2 - waiting for the callback"
		msg ""
		if capture_wait; then
			msg "${C_GRN}Callback captured automatically.${C_OFF}"
			code_in=$(trim_input "$CAPTURED")
		else
			warn "the callback was not captured automatically."
			msg ""
			msg "  Falling back to manual capture. You will have to log in again with"
			msg "  DevTools open. The login URL below is still valid:"
			msg ""
			msg "$url"
			msg ""
			capture_cleanup
			print_prelogin_instructions
			print_postlogin_instructions
			code_in=$(prompt_paste)
		fi
	else
		# The instructions come first on purpose. The instinct on seeing a login URL
		# is to open it and log straight in, which loses the redirect.
		print_prelogin_instructions

		bold "Step 2 - log in to your Tesla account"
		msg ""
		msg "$url"
		msg ""
		if [ "$NO_BROWSER" -eq 0 ] && [ -t 0 ]; then
			msg "  ${C_DIM}The browser opens as soon as you answer, so finish step 1 first.${C_OFF}"
		fi
		browser_gate "$url"

		print_postlogin_instructions
		code_in=$(prompt_paste)
	fi

	parsed=0
	extract_callback "$code_in" || parsed=1

	if [ -n "$QP_error" ]; then
		case $QP_error in
			login_cancelled)
				msg ""
				msg "Login cancelled at Tesla's page. No token was issued."
				exit 0
				;;
			*)
				die "authorization failed: $QP_error${QP_error_description:+ - $QP_error_description}"
				;;
		esac
	fi

	[ -n "$QP_code" ] || die "no authorization code found in what you pasted"

	if [ "$parsed" -eq 1 ]; then
		warn "that looked like a bare code, so the CSRF state check was skipped."
	elif [ -z "$QP_state" ]; then
		warn "the callback URL had no state parameter; CSRF check skipped."
	elif [ "$QP_state" != "$state" ]; then
		err "state mismatch - this callback does not belong to this run."
		msg "  expected: $state"
		msg "  received: $QP_state"
		die "aborting; start again and paste the callback from this run's browser tab"
	fi

	token_url=$TOKEN_URL
	REGION="global"
	if [ "$CN" -eq 1 ]; then
		token_url=$TOKEN_URL_CN
		REGION="china"
	elif [ -n "$QP_issuer" ]; then
		host=$(url_host "$QP_issuer")
		if [ "$host" = "auth.tesla.cn" ]; then
			token_url=$TOKEN_URL_CN
			REGION="china"
		fi
	elif [ "$parsed" -eq 0 ]; then
		warn "no issuer parameter in the callback; assuming the global endpoint."
	fi

	msg ""
	bold "Step 4 - exchanging the code for tokens (${REGION})"
	post_form "$token_url" \
		"grant_type=authorization_code" \
		"client_id=$CLIENT_ID" \
		"code=$QP_code" \
		"code_verifier=$verifier" \
		"redirect_uri=$REDIRECT_URI" || exit 1
	read_token_response "$HTTP_BODY" || exit 1

	emit_tokens
}

do_refresh() {
	local tok token_url
	tok=$(resolve_token "$ARG_TOKEN" TESLA_REFRESH_TOKEN "refresh token")
	[ -n "$tok" ] || die "no refresh token given (see --help for how to pass one)"

	token_url=$TOKEN_URL
	REGION="global"
	if [ "$CN" -eq 1 ]; then
		token_url=$TOKEN_URL_CN
		REGION="china"
	fi

	post_form "$token_url" \
		"grant_type=refresh_token" \
		"client_id=$CLIENT_ID" \
		"refresh_token=$tok" \
		"scope=$SCOPE" || exit 1
	read_token_response "$HTTP_BODY" || exit 1

	msg "Refreshed. ${C_BOLD}Tesla issues a new refresh token every time - store this" \
		"one and discard the old one.${C_OFF}"
	emit_tokens
}

# resolve_token <arg> <ENV_NAME> <label>
resolve_token() {
	local arg=$1 envname=$2 label=$3 tok="" envval=""
	envval=${!envname:-}
	# `read` returns non-zero when the input ends without a newline, but it has
	# still filled the variable. `|| tok=""` would discard exactly what was
	# read - which broke the documented `printf %s "$tok" | ... --refresh -`.
	if [ -n "$arg" ] && [ "$arg" != "-" ]; then
		tok=$arg
	elif [ "$arg" = "-" ]; then
		# Explicit request for stdin.
		IFS= read -r tok || :
	elif [ -n "$envval" ]; then
		tok=$envval
	elif [ ! -t 0 ]; then
		# Piped in, no env var: read whatever is on stdin.
		IFS= read -r tok || :
	else
		printf 'Paste the %s (not echoed): ' "$label" >&2
		IFS= read -r -s tok || :
		printf '\n' >&2
	fi
	trim_input "$tok"
}

# --- Startup ------------------------------------------------------------------

check_deps() {
	local missing=""
	command -v curl >/dev/null 2>&1 || missing="$missing curl"
	command -v openssl >/dev/null 2>&1 || missing="$missing openssl"
	if [ -n "$missing" ]; then
		err "missing required command(s):$missing"
		case $(uname -s) in
			Darwin) msg "  Install with: brew install${missing}" ;;
			CYGWIN*|MINGW*|MSYS*)
				msg "  Git for Windows ships both. Reinstall Git Bash, or install them"
				msg "  from an MSYS2 shell: pacman -S${missing}"
				;;
			*) msg "  Install with your package manager, e.g. sudo apt install${missing}" ;;
		esac
		exit 1
	fi
	# jq is optional. Confirm it actually runs rather than merely existing, so a
	# broken install falls back to the sed extractor instead of silently
	# returning nothing.
	if command -v jq >/dev/null 2>&1 && printf '{"a":1}' | jq -e . >/dev/null 2>&1; then
		HAVE_JQ=1
	else
		HAVE_JQ=0
	fi
}

PROG=$(basename -- "$0")
MODE="interactive"
JSON=0
CN=0
NO_BROWSER=0
MANUAL=0
ARG_TOKEN=""
REGION="global"

main() {
	while [ $# -gt 0 ]; do
		case $1 in
			-h|--help) usage; exit 0 ;;
			--version) printf '%s %s\n' "$PROG" "$VERSION"; exit 0 ;;
			--refresh)
				MODE="refresh"
				if [ $# -ge 2 ] && [ "${2#--}" = "$2" ]; then ARG_TOKEN=$2; shift; fi
				;;
			--refresh=*) MODE="refresh"; ARG_TOKEN=${1#*=} ;;
			--cn) CN=1 ;;
			--json) JSON=1 ;;
			--no-browser) NO_BROWSER=1 ;;
			--manual) MANUAL=1 ;;
			--mint-with)
				if [ $# -lt 2 ]; then err "--mint-with needs curl, python or auto"; exit 2; fi
				case $2 in
					curl|python|auto) MINT_BACKEND=$2 ;;
					*) err "--mint-with must be curl, python or auto"; exit 2 ;;
				esac
				shift
				;;
			--mint-with=*)
				case ${1#*=} in
					curl|python|auto) MINT_BACKEND=${1#*=} ;;
					*) err "--mint-with must be curl, python or auto"; exit 2 ;;
				esac
				;;
			--) shift; break ;;
			*)
				err "unknown argument: $1"
				msg "Run '$PROG --help' for usage."
				exit 2
				;;
		esac
		shift
	done
	if [ $# -gt 0 ]; then
		err "unexpected argument: $1"
		exit 2
	fi

	check_deps

	# Never leave a tesla:// handler registered behind us. The signal traps have to
	# exit as well as clean up: a bare `trap cleanup TERM` cleans up and then
	# carries on running, which is not what a TERM means.
	trap 'capture_cleanup; exit 130' INT
	trap 'capture_cleanup; exit 143' TERM
	trap 'capture_cleanup; exit 129' HUP
	trap capture_cleanup EXIT

	choose_mint_backend
	if [ "$NATIVE_TLS_FALLBACK" -eq 1 ]; then
		warn "this curl is a LibreSSL/SecureTransport build, which is known to mint"
		msg "  tokens that auth.tesla.com issues and the Owner API then refuses. No"
		msg "  Python 3 with OpenSSL was found to mint with instead (tried python3,"
		msg "  python, py -3). If your client rejects these tokens, install Python 3."
	fi

	case $MODE in
		interactive) do_interactive ;;
		refresh)     do_refresh ;;
	esac
}

main "$@"
