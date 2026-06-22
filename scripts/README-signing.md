# Stable dev code-signing

> **The Keychain re-prompt is NOT fixed by signing -- see the warning below.**
> In dev, secrets are read straight from `.env` and never touch the Keychain
> (`DevEnv.cachedSecret`, DEBUG-only). This doc is now only about giving the dev
> binary a *stable code identity* for other identity-keyed grants (e.g. TCC /
> Accessibility persisting across rebuilds).

## Why a stable signature is NOT enough for the Keychain

macOS ties Keychain access to the binary's **code identity**. A bare `swift build`
ad-hoc-signs with a signature that changes every rebuild, so the login Keychain
re-prompts each launch. The obvious fix -- a stable self-signed `Hammerdeck Dev`
cert -- gives a constant *designated requirement* (`certificate leaf = H"..."`),
**but that does not stop the prompt**: for a generic-password item whose signing
cert is **not Apple-anchored** (every self-signed cert), the login-Keychain ACL
pins the per-build **cdhash**, not the stable DR. So each rebuild still looks like
a new app, and even **Always Allow** only sticks for that one cdhash. Only a
**Developer ID** (Apple-anchored) signature gets a stable DR-based Keychain trust
-- which a shipped `.app` has, but `swift build` cannot.

That is why the dev build sidesteps the Keychain entirely (reads `.env`); see
`Sources/HammerdeckKit/DevEnv.swift`.

## One-time: create the signing certificate

Do this once in **Keychain Access**:

1. Open **Keychain Access** -> menu **Certificate Assistant** ->
   **Create a Certificate...**
2. Name: **`Hammerdeck Dev`** (must match exactly; override with
   `HAMMERDECK_SIGN_IDENTITY` if you use another name).
3. Identity Type: **Self Signed Root**
4. Certificate Type: **Code Signing**
5. Create it (accept the defaults). It lands in your **login** keychain.

(Equivalent CLI exists but is fiddly -- the GUI assistant is the reliable path.)

## Use it

Launch through the helper scripts (NOT bare `swift run`, which rebuilds and runs
in one step with no chance to sign in between):

```bash
scripts/restart.sh     # stop + rebuild + SIGN + relaunch
scripts/start.sh       # rebuild + SIGN + launch
```

`scripts/app.sh` signs the freshly built binary with `Hammerdeck Dev` when the
identity exists (it prints "signed with 'Hammerdeck Dev'"); without the cert it
prints a hint and continues unsigned.

A stable identity keeps identity-keyed system grants (e.g. TCC / Accessibility,
which `window_switcher` needs) from resetting on every rebuild. It does **not**
affect the Keychain prompt -- dev reads secrets from `.env`, so the Keychain is
never touched in DEBUG (see the warning at the top).

## Notes

- A shipped `.app` signed with a Developer ID has an Apple-anchored, stable
  signature, so its Keychain trust is DR-based and persists -- self-signed dev
  certs do not get this. The `.env` bypass is the dev-time answer.
- If you ever rename the cert, set `HAMMERDECK_SIGN_IDENTITY="<name>"` in the
  environment before running the scripts.
