# Stable dev code-signing (stop the repeated Keychain prompt)

## Why

Hammerdeck stores secrets (e.g. the OpenAI key) in the login Keychain under
`com.hammerdeck.secrets`. macOS ties "Always Allow" to the app's **code
signature**. `swift build` ad-hoc-signs the binary with a signature that
**changes on every rebuild**, so each launch looks like a different app and the
Keychain re-prompts -- "Always Allow" never sticks.

Signing every build with one **stable** self-signed identity fixes this without
weakening security: the signature is constant, so the Keychain trust persists,
and only Hammerdeck-signed binaries can read the secrets.

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

The **first** signed launch still prompts once (the existing Keychain item was
trusted to the old ad-hoc signature) -- click **Always Allow**, and because the
signature is now stable, it won't ask again across rebuilds.

## Notes

- A shipped `.app` signed with a Developer ID has a stable signature already, so
  it never had this problem -- this is purely a `swift run`/`swift build` dev
  artifact.
- If you ever rename the cert, set `HAMMERDECK_SIGN_IDENTITY="<name>"` in the
  environment before running the scripts.
