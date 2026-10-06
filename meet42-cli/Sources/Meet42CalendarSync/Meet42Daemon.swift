// Meet42Daemon.swift — daemonization + TCC re-key helper for meet42's
// long-lived modes (calendar `sync` daemon, `record`/`watch-mic` capture).
// (meet42-plugin-conversion, M1/s7).
//
// Ported from the flow42 `Record.swift` precedent: a two-step entry that keeps
// BOTH daemonization (setsid, so the daemon outlives the spawning shell) AND
// macOS TCC working for a CLI binary.
//
//   1. First call (no `--reexec`): we're a child of the spawning shell.
//      `setsid()` to become a session leader, then `execve` ourselves with
//      `--reexec` appended. The execve gives macOS a fresh process image to
//      key TCC against our OWN code-sign identity (not the parent terminal's).
//   2. Second call (with `--reexec`): skip setsid (already done); request the
//      TCC-gated resources (Calendar/Mic/Screen) and run the long-lived loop.
//
// ⚠️ NOT build-verifiable: the TCC re-key only has an effect when the binary is
// signed with a persistent Developer ID and carries the embedded Info.plist
// usage descriptions (see scripts/build-meet42.sh). Under a plain `swift build`
// (ad-hoc signature) the re-exec runs but TCC grants won't persist across
// rebuilds — validate on a real signed build.

import Darwin
import Foundation

public enum Meet42Daemon {

    /// Whether the current argv is already the re-exec phase.
    public static func isReexec(_ args: [String]) -> Bool {
        args.contains("--reexec")
    }

    /// Daemonize (step 1) + TCC re-key (execve with `--reexec`). On the first
    /// call this does not return (it execve's); on the re-exec call it returns
    /// immediately so the caller proceeds into its long-lived loop.
    ///
    /// - Parameter reexecArgv: the full argv to re-exec with — the verb prefix
    ///   + original args + `"--reexec"` (e.g. `["sync", "--daemon", "--reexec"]`).
    /// - Parameter isReexec: true when already in the re-exec phase (skips
    ///   setsid + execve).
    public static func daemonize(reexecArgv: [String], isReexec: Bool) {
        if !isReexec {
            // Detach from the parent's session so the daemon outlives the
            // spawning shell and any controlling tty.
            _ = setsid()
            chdir("/")
        }

        let skipReexec = ProcessInfo.processInfo.environment["MEET42_NO_REEXEC"] == "1"
        if !isReexec && !skipReexec {
            let exePath = currentExecutablePath()
            let cArgs = ([exePath] + reexecArgv).map { strdup($0) }
            defer { cArgs.forEach { free($0) } }
            var argvPtrs: [UnsafeMutablePointer<CChar>?] = cArgs + [nil]
            let env = ProcessInfo.processInfo.environment
            let cEnv = env.map { strdup("\($0.key)=\($0.value)") }
            defer { cEnv.forEach { free($0) } }
            var envPtrs: [UnsafeMutablePointer<CChar>?] = cEnv + [nil]
            _ = argvPtrs.withUnsafeMutableBufferPointer { argvBuf in
                envPtrs.withUnsafeMutableBufferPointer { envBuf in
                    execve(exePath, argvBuf.baseAddress, envBuf.baseAddress)
                }
            }
            // execve only returns on failure — fall through and run anyway
            // (TCC may not re-key, but the loop still runs).
            FileHandle.standardError.write(Data(
                "[meet42:daemon] execve failed (\(String(cString: strerror(errno)))) — continuing without re-exec\n".utf8
            ))
        }
    }

    /// Absolute path to the running executable (for the execve self-call).
    public static func currentExecutablePath() -> String {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        var buf = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buf, &size) == 0 else {
            return CommandLine.arguments.first ?? "meet42"
        }
        let raw = buf.withUnsafeBufferPointer { ptr in
            ptr.baseAddress.map { String(cString: $0) } ?? ""
        }
        return (raw as NSString).resolvingSymlinksInPath
    }
}
