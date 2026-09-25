// Thin launcher -- all real logic lives in HammerdeckKit (so the integration
// tests can import it; executable targets cannot be cleanly imported).
import HammerdeckKit

// First, before any AppKit setup: `run_process` re-runs this binary as a
// trampoline that replaces itself with a command (DisclaimedExec). That mode
// never returns.
DisclaimedExec.runIfRequested()
hammerdeckMain()
