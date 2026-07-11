# Security Policy

## Reporting a vulnerability

Please **do not** open a public issue for security problems. Instead, report it
privately via GitHub's [private vulnerability reporting][gh] (the repository's
**Security** tab -> "Report a vulnerability").

[gh]: https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing-information-about-vulnerabilities/privately-reporting-a-security-vulnerability

I'll acknowledge the report and, once a fix ships, credit you in the release
notes unless you'd prefer to stay anonymous.

## Scope

Hammerdeck runs locally as a macOS menubar app and requests no network
permissions by default. The most sensitive surfaces are the **Accessibility**
grant (window control) and the login **Keychain** (feature secrets, e.g. API
keys). Reports touching those are especially appreciated.
