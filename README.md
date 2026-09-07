# tesla-scripts

## get-tesla-owner-token.sh

Gets a Tesla **Owner API** access token and refresh token from the command line,
using the OAuth 2.0 authorization-code flow with PKCE — the protocol
[`adriankumpf/tesla_auth`](https://github.com/adriankumpf/tesla_auth) implements,
as one portable bash script with no build step and no binary to trust.

You log in in your own browser, so two-factor and captcha work normally and the
script never sees your password. The `tesla://auth/callback` redirect that ends
the flow is captured automatically, so there is no digging through DevTools.

### Run it

```sh
bash <(curl -fsSL https://raw.githubusercontent.com/ylexus/tesla-scripts/main/get-tesla-owner-token.sh)
```

> Not `curl … | bash` — the script reads from stdin, and a pipe would swallow
> it. If your shell has no process substitution, download the file first and run
> it.

### Requirements

* **Platforms** — macOS, Linux, Windows (Git Bash)
* **Required** — `bash` 3.2+ (macOS ships 3.2), `curl`, `openssl`
* **Optional** — `jq`, used if present; `python3` / `python` / `py -3`, see
  [`--mint-with`](#which-tls-stack-mints-the-token)

### Usage

```
get-tesla-owner-token.sh                  Full interactive authorization flow
get-tesla-owner-token.sh --refresh [TOK]  Exchange a refresh token for a new pair
get-tesla-owner-token.sh --help
```

| Option | Effect |
|---|---|
| `--refresh [TOKEN]` | Refresh flow. See [Passing tokens safely](#passing-tokens-safely). |
| `--cn` | Use `auth.tesla.cn` for `--refresh`. The interactive flow detects this from the callback's `issuer`. |
| `--json` | One JSON object on stdout instead of prose. |
| `--manual` | Skip automatic capture; paste the callback URL by hand. |
| `--mint-with curl\|python\|auto` | TLS stack for the token exchange. See [below](#which-tls-stack-mints-the-token). |
| `--no-browser` | Never launch a browser; just print the URL. |

Both tokens go to stdout and everything else to stderr, so `--json` pipes
cleanly. Nothing is written to a file, and the script contacts only
`auth.tesla.com` or `auth.tesla.cn`.

### How the callback is captured

The login ends by redirecting to `tesla://auth/callback?code=…`. No browser can
open a custom scheme like that, which is what makes this flow awkward outside a
native app. `tesla_auth` solves it by *being* an app registered for the scheme;
this script registers a throwaway handler for the length of the run and removes
it on the way out.

| Platform | Handler | Registered in |
|---|---|---|
| macOS | AppleScript applet declaring `CFBundleURLSchemes`, via `lsregister` | `~/Library/Caches/tesla-scripts.XXXXXX` |
| Windows | `HKCU\Software\Classes\tesla` → a one-line `.cmd` shim | Per-user registry |
| Linux | `NoDisplay` `.desktop` with `MimeType=x-scheme-handler/tesla`, via `xdg-mime` | `~/.local/share/applications` |

It is all per-user, needs no admin rights, and is undone by a shell trap on
exit, `Ctrl-C`, `SIGTERM` and `SIGHUP`. An existing `tesla://` handler is left
intact: on Windows it is backed up and restored, and if it cannot be backed up
the script refuses to replace it.

Your browser will ask permission the first time — *"Open Tesla Auth Callback?"*.
Allow it. That prompt is the browser, not the script.

### Manual capture

Used with `--manual`, or automatically if the handler cannot be registered or
nothing arrives within five minutes.

1. **Before logging in**, open DevTools, go to **Network**, and tick **Preserve
   log** — without it the browser discards the redirect as it navigates away.
2. Log in. The browser then refuses to open `tesla://auth/callback`, or offers
   to open an application. That is what success looks like.
3. Find the entry whose URL starts with `tesla://` — or the last
   `auth.tesla.com` request with status **302**, whose `Location` header holds
   it — and paste it at the prompt. A bare `code=` value is also accepted, with
   a warning that the CSRF `state` check was skipped.

⚠️ **Safari collapses redirect chains** and often will not show the 302 or its
headers at all. Use Firefox or a Chromium browser if you must capture by hand.

### Refreshing

Access tokens last 8 hours.

```sh
export TESLA_REFRESH_TOKEN=…
get-tesla-owner-token.sh --refresh
```

**Tesla issues a new refresh token every time.** Store the new one and discard
the old.

### Passing tokens safely

A token in a command-line argument lands in your shell history. `--refresh`
takes one four ways, in this order:

```sh
get-tesla-owner-token.sh --refresh "$TOKEN"                 # argument (least private)
printf %s "$TOKEN" | get-tesla-owner-token.sh --refresh -   # explicit stdin
TESLA_REFRESH_TOKEN=… get-tesla-owner-token.sh --refresh    # environment
get-tesla-owner-token.sh --refresh                          # non-echoing prompt
```

Secrets reach curl through a config file on stdin, and python over a pipe, so
they never appear in the process list.

### Which TLS stack mints the token

A token minted over a TLS handshake Tesla dislikes is issued happily by
`auth.tesla.com` and then refused with `403` by `owner-api.teslamotors.com`.
This is reported against several clients
([TeslaMate #5384](https://github.com/teslamate-org/teslamate/issues/5384)) and
was reproduced here: minted with macOS's system curl (LibreSSL/SecureTransport)
the token was refused; minted with python (OpenSSL), same account and script
minutes later, it worked.

It is not the protocol version — that curl already negotiates TLS 1.3. It is the
stack. Git for Windows curl (Schannel) and Linux curl (OpenSSL) both mint
working tokens.

| `--mint-with` | Behaviour |
|---|---|
| `auto` (default) | curl, except on a LibreSSL/SecureTransport build — the macOS system curl — where python is preferred if available |
| `curl` | always curl |
| `python` | always python (`urllib`, so OpenSSL) |

If a client rejects your tokens, mint with the other backend and compare.

### Troubleshooting

**`The 'redirect_uri' supplied is not registered for this 'client_id'`** — the
only registered URI for `client_id=ownerapi` is `tesla://auth/callback`. Older
guides use `https://auth.tesla.com/void/callback`, which Tesla retired. You will
only see this if you edited the authorize URL by hand.

**`403` from the Owner API** — that endpoint returns `401` for a token it
rejects, so a `403` means the token authenticated and was then denied for some
other reason. Try the other `--mint-with` backend. The script deliberately does
not "verify" tokens itself; your client is the real test.

**Commands fail but reads work** — vehicles from roughly 2021 on enforce Tesla's
Vehicle Command Protocol and reject legacy REST *commands* car-side. Reads are
expected to keep working. No token changes this.

### Tests

```sh
bash tests/run-tests.sh
```

No Tesla account needed. Runs `shellcheck`, a bash 3.2 and bash 5 syntax check,
unit tests (RFC 7636 PKCE vector, URL encoding, callback parsing, `jq`-versus-
fallback parity, handler cleanup against a fake registry and `HOME`) and
end-to-end tests driving the real flows against a local fake token endpoint. On
macOS it also arms the real URL handler and asserts it is unregistered
afterwards, including after a `SIGTERM`; `TESLA_SKIP_AUTOCAPTURE=1` skips that.

### Credits

Protocol details — the `ownerapi` client id, the `tesla://auth/callback`
redirect URI, scopes, `issuer`-based endpoint selection and the token-response
requirements — come from
[**adriankumpf/tesla_auth**](https://github.com/adriankumpf/tesla_auth), the
reference implementation of this flow.

### Disclaimer

Unofficial, and **not affiliated with, authorised or endorsed by Tesla, Inc.**
It uses Tesla's undocumented legacy Owner API, which may change or disappear
without notice. Intended for use with your own account and vehicle. No warranty
— see [LICENSE](LICENSE).

## License

[MIT](LICENSE)
