# Security Policy

## Reporting a vulnerability

Please **do not** open a public issue for security problems. Instead, report it
privately via GitHub's [private vulnerability reporting][gh] (the repository's
**Security** tab -> "Report a vulnerability").

[gh]: https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing-information-about-vulnerabilities/privately-reporting-a-security-vulnerability

The same form takes [Code of Conduct](CODE_OF_CONDUCT.md) reports; start the
title with "Code of Conduct" so it is not triaged as a vulnerability.

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
| **Accessibility** | reading and moving other apps' windows (AXUIElement); synthesizing keystrokes (paste-as-plain-text, insert date/time, paste from clipboard history, and locking the screen -- which posts the system ctrl-cmd-Q shortcut); and the Caps->Hyper remap, which is an event tap that REWRITES keys | on first use of a feature that needs it |
| **Automation (per browser)** | listing Chrome/Safari tabs for the tab and site switchers | lazily, the first time a switcher runs |
| **Automation (System Events)** | the rules engine's dark/light appearance effect -- System Events is the only public way to change the system appearance | the first time a rule fires it |
| **Login Keychain** | storing a feature's API key (today: OpenAI) | only if you enter one |
| **Subprocesses** | two different things. The seam spawns a small set of **fixed, named** commands with arguments it builds itself -- sleeping the machine, starting the screensaver, speaking text, running a Shortcut, scripting a browser. Some sit behind a capability; some are reachable only from the rules engine and have no capability of their own. Separately, the `exec` capability runs an **arbitrary** command line, and that one is for user extensions only (`grep -rn 'runCommand(\|runProcessCore(\|runJXA(' app/platform/swift/` enumerates the fixed set -- a list written out here would go stale) | the fixed ones with whatever invokes them; `exec` never for a built-in feature |

Two-step chords are deliberately absent from that list: the prefix and each
follow key are ordinary Carbon hotkeys, so a chord needs no permission at all.

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
surface grows it in the seam, where the call is one reviewed named thing. Read
that as "no built-in runs a command *you* supplied", not as "no built-in spawns a
process": several of those reviewed seam calls are themselves fixed command
lines, listed in the surface table above.

**The debug eval channel is `#if DEBUG` only** and compiles to a no-op in the
released build. The shipping MCP endpoint deliberately has **no eval tool**:
arbitrary Lua arriving at runtime would be invisible to the capability scanner
and make its verdicts meaningless.

## Network

Hammerdeck has no telemetry, no analytics, no crash reporting, and no account.
Nothing *about you* is ever transmitted -- but two of the four requests below do
run unprompted on a timer, so "nothing happens on a schedule" would be wrong: the
update check polls the feed, and Bing Daily Wallpaper fetches on the schedule you
set it. It makes exactly **four** kinds of outbound request, all of them
consequences of something you turned on or did:

1. **Update checks** -- Sparkle polls the appcast at `hammerdeck.peach-studio.com`
   and, for a release you approve, downloads the archive from this repository's
   GitHub Releases (`github.com`, which redirects to
   `release-assets.githubusercontent.com`). The feed and the archive are on
   different hosts on purpose, and only the feed is polled unprompted. Every
   update is EdDSA-signed against a key baked into the build, and the signature
   is over the archive's bytes rather than over where they came from -- so a
   download host that served the wrong file cannot install anything, and neither
   can a feed that cannot produce a valid signature.
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
   thereafter. The domain is one you were already opening in a browser, and no
   third-party service is involved -- but it is still a request you did not type,
   so that site learns your IP and the time, as any HTTP request does. Nothing
   identifying you is *sent*; a connection is a connection.

All four are what the **built-in** catalog does. A user extension you install
declares `network` and can then reach anything -- the list above describes code
that ships with the app, not a limit the app imposes on your own.

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

Everything stays on the machine. It is in more than one place, so here is each:

- `~/Library/Application Support/Hammerdeck/` -- plain-text daily logs, and
  feature data such as clipboard history.
- `~/Library/Caches/` -- downloaded favicons. The OS may purge this at will,
  which is why nothing durable lives here.
- **Wherever the feature is configured to write.** Usage Stats defaults to
  `~/.computer-usage`, outside Application Support entirely, and that folder is a
  setting you can change. A feature that writes outside the app's own data
  directory needs the `files` capability to do it.
- **Preferences** go to the app's own defaults domain -- `com.peach-studio.hammerdeck`
  for a packaged build. (Running from source it is `Hammerdeck`, the executable
  name; that is the one `defaults read Hammerdeck` reaches during development.)

**Log retention keeps the newest 14 log FILES, not 14 days.** One file is written
per day the app runs, so on daily use those coincide -- but a machine used
occasionally keeps logs going back much further than a fortnight. Delete the
folder if that matters to you.

**Clipboard History skips entries marked as secrets, which is not the same as
recognizing password managers.** It reads the [nspasteboard.org][nsp] convention:
a clip carrying a concealed/transient marker is never recorded. Password managers
set that marker, and so does Hammerdeck's own Password Generator for the
passwords it mints. An application that copies a secret WITHOUT marking it is
indistinguishable from one copying ordinary text, and its clip is recorded like
any other.

[nsp]: http://nspasteboard.org
