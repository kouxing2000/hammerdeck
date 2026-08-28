# Security Policy

## Reporting a vulnerability

Please **do not** open a public issue for security problems. Instead, report it
privately via GitHub's [private vulnerability reporting][gh] (the repository's
**Security** tab -> "Report a vulnerability").

[gh]: https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing-information-about-vulnerabilities/privately-reporting-a-security-vulnerability

I'll acknowledge the report and, once a fix ships, credit you in the release
notes unless you'd prefer to stay anonymous.

Only the **latest release** receives fixes. Hammerdeck auto-updates through a
signed Sparkle feed, so there is no supported older line.

## What Hammerdeck can reach

This is a menubar automation tool, **not a sandboxed app** -- it cannot be one
and still do its job (Mac App Store distribution is ruled out for the same
reason). Being blunt about the surface is more useful than a short list:

| Surface | Why it's needed | When it's asked for |
|---|---|---|
| **Accessibility** | reading and moving other apps' windows (AXUIElement) | on first use of a window feature |
| **Input Monitoring** | Caps->Hyper remapping and two-step chords | on first use of those triggers |
| **Automation (per browser)** | listing Chrome/Safari tabs for the tab and site switchers | lazily, the first time a switcher runs |
| **Login Keychain** | storing a feature's API key (today: OpenAI) | only if you enter one |
| **Subprocesses** | the `exec` capability, available to user extensions only | never for a built-in feature |

Everything runs as your user. A bug here is a bug with your whole account's
reach, which is why reports touching the seam are especially appreciated.

## Trust model

**Built-in features are first-party code compiled into the release.** There is no
third-party plugin marketplace and no sandbox between a feature and the app --
the catalog is curated precisely because that boundary does not exist.

**Capability declarations are auditability, not a sandbox.** Each feature
declares in its `feature.json` what it may reach (`network`, `input`, `power`,
`browser`, `files`, `apps`, `commands`), and `ctx` withholds the matching methods
if it did not. A feature could simply declare everything; the value is that the
claim is greppable, machine-checked in both directions by the test suite, and
visible in the UI. It stops accidents and makes review tractable. It does not
contain hostile code, and `load()` defeats any static scan.

**User extensions are your own code, and they are the one place `exec` lives.**
An extension you drop in the extensions folder gets the same runtime capability
gate but none of our CI guards. A child process can do anything you can, so a
first-party feature is forbidden from declaring `exec` -- a built-in that needs OS
surface grows it in the seam, where the call is one reviewed named thing.

**The debug eval channel is `#if DEBUG` only** and compiles to a no-op in the
released build. The shipping MCP endpoint deliberately has **no eval tool**:
arbitrary Lua arriving at runtime would be invisible to the capability scanner
and make its verdicts meaningless.

## Network

Hammerdeck has no telemetry, no analytics, no crash reporting, and no account.
Nothing is sent anywhere on a schedule. It makes exactly **four** kinds of
outbound request, all of them consequences of something you turned on or did:

1. **Update checks** -- Sparkle polls the appcast at `hammerdeck.peach-studio.com`
   and downloads a release you approve. Every update is EdDSA-signed against a
   key baked into the build; a feed that cannot produce a valid signature cannot
   install anything.
2. **Bing Daily Wallpaper** (feature, off by default) -- fetches the picture of
   the day from `bing.com`. It is the entire point of the feature.
3. **Text Actions -> AI entries** (feature, off by default, and the AI half stays
   hidden until you enter and validate a key) -- posts the text you selected to
   `api.openai.com` with your own key, which is stored in the login Keychain.
   This is the only feature that sends your content anywhere, it only fires on
   an action you invoke, and it does nothing without a key you supplied.
4. **Favicons** -- Tab Switcher and Quick Sites show a site's icon. They first ask
   your local Chrome icon database; only for a domain that answers nothing do
   they fetch `https://<that-domain>/favicon.ico`, once, cached to disk
   thereafter. The domain is one you were already opening in a browser. No
   third-party service is involved and nothing about you is transmitted.

## The MCP endpoint

Settings > General > Agent Access can expose a local MCP server so a coding agent
can help author extensions. It ships in release builds and is gated three ways:
**off by default** (`hammerdeck.mcp.enabled`), bound to **loopback only**
(127.0.0.1, enforced at the listener, not by a check), and requiring a **bearer
token** minted on first enable, plus an Origin check. Its tools are reflective --
list features, describe the API surface, reload, validate an extension's
declarations, enable and run one, tail the log. It grows an agent's visibility,
never its reach.

## Logs and stored data

Everything stays on the machine, in
`~/Library/Application Support/Hammerdeck/` -- plain-text daily logs (14-day
retention), feature data such as clipboard history and usage CSVs, and cached
favicons. Settings live in the `Hammerdeck` defaults domain. Clipboard History
never records entries copied from a password manager.
