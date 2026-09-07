# tesla-scripts

Small, dependency-light shell tools for talking to Tesla's legacy **Owner API**.

Currently one script: [`get-tesla-owner-token.sh`](get-tesla-owner-token.sh).

---

## get-tesla-owner-token.sh

Obtains a Tesla **Owner API** access token and refresh token using the OAuth 2.0
authorization-code flow with PKCE — the same protocol
[`adriankumpf/tesla_auth`](https://github.com/adriankumpf/tesla_auth) implements,
in a single portable bash script with no build step and no binaries to trust.

It prints two things:

* an **access token** — short-lived (8 hours), used as `Authorization: Bearer …`
* a **refresh token** — long-lived, used to mint new access tokens

That is the pair every Owner API client asks for.

You log in in your own browser, so two-factor and captcha work normally, and the
script never sees your password. The `tesla://auth/callback` redirect that ends
the flow is **captured automatically** — the script registers a temporary handler
for the `tesla://` URL scheme for the duration of the run, so there is no
copying URLs out of DevTools. See
[How the callback is captured](#how-the-callback-is-captured).

### Run it

```sh
bash <(curl -fsSL https://raw.githubusercontent.com/ylexus/tesla-scripts/main/get-tesla-owner-token.sh)
```

Works as-is in macOS Terminal, Linux and Git Bash on Windows.

> **Do not** use `curl … | bash`. The script reads from standard input (the
> browser prompt, and the manual paste fallback), and a pipe would consume it.
> The `<(…)` form above keeps stdin free. If your shell lacks process
> substitution, download first:
>
> ```sh
> curl -fsSL -o get-tesla-owner-token.sh https://raw.githubusercontent.com/ylexus/tesla-scripts/main/get-tesla-owner-token.sh
> bash get-tesla-owner-token.sh
> ```

### Requirements

* **Platforms** — Windows (Git Bash), Linux, macOS
* **Shell** — `bash` 3.2 or newer (macOS ships 3.2; the script targets it)
* **Required** — `curl`, `openssl`
* **Optional** — `jq`, used if present, with a built-in fallback parser if not
* **Optional** — `python3` / `python` / `py -3`, used for the token exchange when
  curl's TLS stack is a poor bet (see [`--mint-with`](#which-tls-stack-mints-the-token))

### Usage

```
get-tesla-owner-token.sh                  Full interactive authorization flow
get-tesla-owner-token.sh --refresh [TOK]  Exchange a refresh token for a new pair
get-tesla-owner-token.sh --help
```

| Option | Effect |
|---|---|
| `--refresh [TOKEN]` | Refresh flow. See [Passing tokens safely](#passing-tokens-safely). |
| `--cn` | Use the China endpoint (`auth.tesla.cn`) for `--refresh`. The interactive flow detects this automatically from the callback's `issuer`. |
| `--json` | Emit a single JSON object on stdout instead of prose. |
| `--manual` | Skip automatic capture; paste the callback URL by hand. |
| `--mint-with curl\|python\|auto` | Which TLS stack performs the token exchange. See [Which TLS stack mints the token](#which-tls-stack-mints-the-token). |
| `--no-browser` | Never launch a browser; just print the URL. |

### How the callback is captured

The login ends with a redirect to `tesla://auth/callback?code=…`. That is a
custom URL scheme, so no browser can open it — which is the whole difficulty of
doing this flow outside a native app.

`tesla_auth` solves it by *being* a native app registered for the `tesla://`
scheme. This script borrows the same trick, temporarily: for the duration of the
run it registers a throwaway handler for `tesla://`, lets the operating system
hand it the callback, and unregisters it on the way out. You log in and the
script simply continues — no DevTools, no copying, no leaving your default
browser.

| Platform | Mechanism | Registered in |
|---|---|---|
| macOS | An AppleScript applet declaring `CFBundleURLSchemes`, registered with `lsregister` | `~/Library/Caches/tesla-scripts.XXXXXX` (deleted on exit) |
| Windows | `HKCU\Software\Classes\tesla` pointing at a one-line `.cmd` shim | Per-user registry (deleted on exit; a pre-existing key is backed up and restored) |
| Linux | A `NoDisplay` `.desktop` entry with `MimeType=x-scheme-handler/tesla;`, selected via `xdg-mime` | `~/.local/share/applications` (deleted on exit; the previous default is restored) |

Cleanup runs from a shell trap on normal exit, `Ctrl-C`, `SIGTERM` and `SIGHUP`.

Worth knowing:

* Your browser will usually ask permission the first time — *"Open Tesla Auth
  Callback?"*. Allow it. That prompt is the browser, not the script.
* While the handler is registered (a couple of minutes at most), any local
  application could in principle fire a `tesla://` URL at it. The `state`
  parameter is still checked, so a bogus callback is rejected.
* Nothing is installed permanently and nothing needs admin rights — it is all
  per-user.
* If any of this fails, or you pass `--manual`, the script falls back to the
  manual capture below. Nothing is lost.

### Walk-through

**1.** Run the script. It prints the authorize URL and offers to open it:

```
Step 1 - log in to your Tesla account

https://auth.tesla.com/oauth2/v3/authorize?response_type=code&client_id=ownerapi&code_challenge=jT59…

  A handler for tesla:// is registered for this run only, so the callback
  is picked up automatically - no DevTools needed. It is removed again when
  this script exits. Your browser will probably ask for permission to open
  it; allow that.

Open the login page in your default browser now? [Y/n]
```

**2.** Log in. Two-factor prompts and captchas all work as usual.

**3.** When the login finishes, your browser asks whether to open the handler —
allow it. The terminal picks the callback up by itself:

```
Step 2 - waiting for the callback

Callback captured automatically.

Step 4 - exchanging the code for tokens (global)

ACCESS TOKEN
eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.<...>

REFRESH TOKEN
eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.<...>

token_type: Bearer
expires_in: 28800s (at 2026-09-08 01:42:00 BST)
region:     global
```

That is the whole flow. If the callback does not arrive within five minutes, or
you press `Ctrl-C` while it waits, the script drops through to manual capture
instead of giving up.

### Manual capture (fallback)

Used when you pass `--manual`, or when automatic capture is unavailable. Here you
read the redirect out of the browser's developer tools yourself.

**1.** *Before logging in*, open DevTools — <kbd>F12</kbd>, or
<kbd>⌘</kbd><kbd>⌥</kbd><kbd>I</kbd> on macOS — switch to the **Network** tab, and
tick **Preserve log**. Without Preserve log the browser discards the redirect at
the moment it navigates away, and you have to log in all over again. The script
prints this instruction *before* it offers to open the browser, for exactly that
reason.

**2.** Log in as usual.

**3.** The browser refuses to open `tesla://auth/callback`, or shows an
*"Open with…"* dialog, or an error page. **That is what success looks like.**

**4.** In the Network list, find the entry whose URL starts with `tesla://` — or
the last `auth.tesla.com` request with status **302**, whose `Location` response
header holds it:

```
Location: tesla://auth/callback?code=eyJhbGciOi…&state=9647390002352da19f89d50867e7d8fe&issuer=https%3A%2F%2Fauth.tesla.com%2Foauth2%2Fv3
```

* **Firefox** — right-click the 302 row → *Copy* → *Copy Location*.
* **Chrome/Edge** — the redirect row often looks greyed out; it is still selectable.
* **Safari** — ⚠️ Safari's Web Inspector collapses redirect chains into a single
  entry and frequently will not show you the intermediate 302 or its headers at
  all. If you must capture manually, use Firefox or a Chromium browser. This is
  the main reason automatic capture is the default.

**5.** Paste it at the prompt. If all you managed to copy was the `code=` value
itself, paste just that — the script accepts a bare code, and warns that it
skipped the CSRF `state` check.

### Refreshing

Access tokens last 8 hours. Refresh with the refresh token:

```sh
export TESLA_REFRESH_TOKEN=…
get-tesla-owner-token.sh --refresh
```

**Tesla issues a new refresh token on every refresh.** Store the new one and
discard the old.

### Passing tokens safely

A token given as a command-line argument ends up in your shell history and in
`ps` output. `--refresh` therefore accepts a token four ways, in
this order:

```sh
get-tesla-owner-token.sh --refresh "$TOKEN"                 # 1. argument (least private)
printf %s "$TOKEN" | get-tesla-owner-token.sh --refresh -   # 2. explicit stdin
TESLA_REFRESH_TOKEN=… get-tesla-owner-token.sh --refresh    # 3. environment variable
get-tesla-owner-token.sh --refresh                          # 4. non-echoing prompt
```

Internally the script hands secrets to curl through a config file on stdin
(`curl -K -`), or to python over a pipe, so tokens never appear in the process
list even in the argument form.

### Which TLS stack mints the token

<a id="which-tls-stack-mints-the-token"></a>

A token minted over a TLS handshake Tesla dislikes is accepted by
`auth.tesla.com` and then refused with `403` by `owner-api.teslamotors.com` —
the same token, valid, simply denied. This is reported against several clients
([TeslaMate #5384](https://github.com/teslamate-org/teslamate/issues/5384),
[#5390](https://github.com/teslamate-org/teslamate/issues/5390),
[#5391](https://github.com/teslamate-org/teslamate/issues/5391),
[batpred #3965](https://github.com/springfall2008/batpred/issues/3965)), and it
was reproduced and then fixed during this script's development:

* Minted with **macOS system curl** (LibreSSL 3.3.6 / SecureTransport) — the
  token authenticated fine and every Owner API call returned
  `403 {"error":"forbidden, see https://developer.tesla.com/docs/fleet-api"}`.
* Minted with **python3** (OpenSSL 3.6.3), same account, same script, minutes
  later — the token works.
* Minted with **Git for Windows curl** (Schannel) — the token works.

**It is not the protocol version.** macOS system curl already negotiates TLS 1.3
here and was still refused, and forcing TLS 1.2 changed nothing. Nor is it the
*calling* client's stack: the failing token was refused identically by LibreSSL
curl and OpenSSL python. It is the stack that performs the **token exchange**.

Ruled out along the way, all empirically: the `User-Agent`, HTTP/1.1 versus
HTTP/2, the token format (the legacy `qts-…` Owner API Token exchange now
returns `unsupported_grant_type`), and the age of the authorization grant.

So `--mint-with` chooses which stack performs the token exchange:

| Value | Behaviour |
|---|---|
| `auto` (default) | Use `curl`, except when curl is a LibreSSL/SecureTransport build — the macOS system curl — where `python` is preferred if available. |
| `curl` | Always curl. |
| `python` | Always python (`urllib`, so OpenSSL). |

Both paths send an identical request and are covered by the test suite.

**Git for Windows ships curl built against Schannel**, and that has been
confirmed to mint working tokens — so `auto` leaves it alone. Being a
platform-native stack is not itself the problem; only the macOS LibreSSL build
has actually produced tokens the Owner API refuses.

Where python *is* preferred (macOS), all three interpreter spellings are tried,
because Windows rarely has `python3` on `PATH`: python.org installs `python`
plus the `py` launcher, and only the Microsoft Store build provides `python3`.

If your tokens are rejected by a client that should accept them, mint with the
other backend and compare.

### Troubleshooting

#### `The 'redirect_uri' supplied is not registered for this 'client_id'`

The only redirect URI registered for `client_id=ownerapi` is the custom scheme
**`tesla://auth/callback`**. Many older guides still use
`https://auth.tesla.com/void/callback`, which Tesla retired. This script uses
the correct one; you will only see this error if you edited the authorize URL by
hand. It does **not** mean the Owner API has been shut down.

#### The script does not check your tokens

It mints tokens and prints them; it deliberately does not call the Owner API to
"verify" them. An earlier version did, and it was worse than useless: a `403`
from `owner-api.teslamotors.com` says almost nothing about whether the token is
good — the endpoint returns `401` for a token it rejects, so a `403` means the
token *authenticated* and was then denied for some other reason. Reporting that
as a token failure sends you chasing the wrong problem.

The real test is your client. Paste both tokens into whatever consumes them.

#### Commands fail but reads work

Vehicles from roughly 2021 onward enforce Tesla's **Vehicle Command Protocol**
and reject legacy REST *commands* in the car itself. Reads — vehicle list, state,
charge and climate data — are expected to keep working. No token can change this;
it is a car-side restriction, not an authentication problem.

### Notes on behaviour

* `state` is compared against the value generated for that run; a mismatch aborts.
* `issuer` selects the token endpoint by **host**: `auth.tesla.cn` → the China
  endpoint, anything else → the global one.
* A response missing `refresh_token` or `expires_in` is treated as a hard error,
  matching `tesla_auth`.
* Redirects are not followed on the token call.
* `error=login_cancelled` exits 0 without printing a token.
* The script contacts only `auth.tesla.com` / `auth.tesla.cn`. It never calls
  the Owner API.
* The temporary `tesla://` handler is removed on exit, `Ctrl-C`, `SIGTERM` and
  `SIGHUP`; on Windows and Linux a pre-existing handler is restored.
* Tokens go to stdout; everything else goes to stderr, so `--json` output pipes
  cleanly. Nothing is ever written to a file, and the script talks to nothing
  except `auth.tesla.com` and `auth.tesla.cn`.

### Tests

Everything that can be checked without a Tesla account is in [`tests/`](tests):

```sh
bash tests/run-tests.sh
```

That runs `shellcheck`, a bash 3.2 and bash 5 syntax check, unit tests for the
PKCE, URL-encoding, callback-parsing and JSON code, and end-to-end tests that
drive the real flows against a local fake of Tesla's token endpoint. The unit
tests include the RFC 7636 appendix B PKCE vector and check that the built-in
JSON parser agrees with `jq` field for field; the end-to-end tests check that
both `--mint-with` backends send an identical request and produce identical
output.

On macOS the end-to-end run also exercises automatic capture for real: it arms
the handler, fires a `tesla://` URL at it, and asserts that the handler is
unregistered afterwards — including after a `SIGTERM`. Set
`TESLA_SKIP_AUTOCAPTURE=1` to skip that part.

### Credits

Protocol details — the `ownerapi` client id, the `tesla://auth/callback` redirect
URI, scopes, the `issuer`-based endpoint selection and the token-response
requirements — were taken from
[**adriankumpf/tesla_auth**](https://github.com/adriankumpf/tesla_auth), which is
the reference implementation of this flow. If you would rather use a native app
that captures the callback for you, use that.

### Disclaimer

Unofficial. This project is **not affiliated with, authorised, endorsed by, or in
any way connected to Tesla, Inc.** It uses Tesla's undocumented legacy Owner API,
which Tesla may change or withdraw without notice. Intended for use with your own
account and your own vehicle. No warranty — see [LICENSE](LICENSE).

## License

[MIT](LICENSE)
