#if DEBUG
import Foundation

// DEV-ONLY (compiled out of release builds via #if DEBUG): seed local secrets
// from a gitignored `.env` at the repo root so `swift run` doesn't make you
// paste the OpenAI key on every launch. The key still lands in the login
// Keychain (never UserDefaults) -- `.env` is just the convenience SOURCE, the
// same storage a manual Settings entry uses. No-op without a `.env` / key.
enum DevEnv {
    /// Repo-root `.env`, derived from this file's location (robust to the launch
    /// working directory, like defaultLuaDir/makeDockIcon).
    private static var dotEnvURL: URL {
        URL(fileURLWithPath: #filePath)        // .../Sources/HammerdeckKit/DevEnv.swift
            .deletingLastPathComponent()        // .../Sources/HammerdeckKit
            .deletingLastPathComponent()        // .../Sources
            .deletingLastPathComponent()        // repo root
            .appendingPathComponent(".env")
    }

    /// Parse simple KEY=VALUE lines (ignores blanks and `#` comments; strips
    /// surrounding quotes). Pure, so it's unit-testable without a file.
    static func parse(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            var val = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if val.count >= 2,
               (val.first == "\"" && val.last == "\"") || (val.first == "'" && val.last == "'") {
                val = String(val.dropFirst().dropLast())
            }
            if !key.isEmpty { out[key] = val }
        }
        return out
    }

    /// Seed text_actions' OpenAI key from `.env` (OPENAI_KEY) into the Keychain
    /// if it isn't set yet, then validate it once (real /v1/models) so the model
    /// dropdown populates and the AI actions ungray without a manual Validate
    /// click. Skips the network when a prior run already validated this key.
    @MainActor
    static func seed(_ store: SettingsStore) {
        // Just trigger validation so the model dropdown populates and the AI
        // actions ungray -- the key itself is served straight from `.env` via
        // cachedSecret (below), NOT written to the Keychain. See that note for why.
        guard cachedSecret("hammerdeck.opt.text_actions.openaiKey") != nil else { return }

        store.refresh()
        guard !store.isValidated("text_actions", "openaiKey"),
              let opt = store.features.first(where: { $0.id == "text_actions" })?
                  .options.first(where: { $0.key == "openaiKey" }) else { return }
        store.validate("text_actions", opt)   // async; unlocks the AI actions when it returns
    }

    /// DEBUG dev-secret cache: account -> value, sourced from `.env`. Consulted by
    /// BOTH secret read paths (the Lua seam `keychainGet` and the Swift
    /// `KeychainStore.get`) BEFORE the system Keychain, so dev never round-trips a
    /// secret through the login Keychain.
    ///
    /// Why bypass the Keychain in dev: macOS ties Keychain access to the binary's
    /// code identity. For a self-signed (non-Apple-anchored) `swift build` binary,
    /// the login-Keychain ACL pins the per-build *cdhash*, NOT the stable cert
    /// designated requirement -- so every rebuild looks like a new app and re-prompts,
    /// and even "Always Allow" only sticks for that one cdhash. Reading from `.env`
    /// sidesteps the ACL entirely. Release builds compile this out and use the
    /// Keychain normally (a Developer ID `.app` has an Apple-anchored, stable identity).
    private static let accountForEnvKey = ["OPENAI_KEY": "hammerdeck.opt.text_actions.openaiKey"]
    nonisolated(unsafe) private static var secretCache: [String: String]?

    static func cachedSecret(_ account: String) -> String? {
        if secretCache == nil {
            var m: [String: String] = [:]
            if let text = try? String(contentsOf: dotEnvURL, encoding: .utf8) {
                let env = parse(text)
                for (envKey, acct) in accountForEnvKey where !(env[envKey] ?? "").isEmpty {
                    m[acct] = env[envKey]
                }
            }
            secretCache = m
        }
        return secretCache?[account]
    }
}
#endif
