// Permission.swift — local, trimmed permissions catalog for Meet42Capture.
//
// The capture engine (ported from Flow42Core / Work42App) checked TCC and
// on-device speech-model availability through Flow42Core's `Permission` enum.
// This standalone package has NO dependency on Flow42Core, so this file
// reproduces ONLY the surface the ported capture code actually touches:
//
//   • Permission.microphone.preflight()        (RecordingCore)
//   • Permission.screenRecording.preflight()   (RecordingCore)
//   • Permission.speechModel.status            (MeetingTranscriptionEngine)
//   • Permission.ensureLocaleReserved(_:logPrefix:)
//   • Locale.isEquivalent(to:)                 (BCP-47 identifier compare)
//
// The multi-permission catalog (calendar / accessibility / input-monitoring /
// notifications) is intentionally omitted — the capture engine never reads it.

import AVFoundation
import CoreGraphics
import Foundation
import Speech

// MARK: - PermissionPreflight

/// Result of a preflight: granted, or denied with user-facing guidance.
public enum PermissionPreflight: Sendable, Equatable {
    case granted
    case denied(message: String)
}

// MARK: - PermissionStatus

/// A normalized authorization status across TCC-backed permissions.
public enum PermissionStatus: String, Sendable, Equatable, CaseIterable {
    case authorized
    case denied
    case notDetermined
    case restricted
    case unknown
}

// MARK: - Locale equivalence

extension Locale {
    /// `Locale`'s `Equatable` conformance compares more than the printable
    /// identifier — `Locale.current` can carry hidden overrides pulled from
    /// System Settings that a plain `Locale` (e.g. one from
    /// `SpeechTranscriber.installedLocales`) does not, so two locales with the
    /// same BCP-47 identifier can still fail `==`. Compare by BCP-47 instead.
    public func isEquivalent(to other: Locale) -> Bool {
        identifier(.bcp47) == other.identifier(.bcp47)
    }
}

// MARK: - Permission

/// The subset of macOS privacy / capability checks the capture engine needs.
public enum Permission: String, Sendable, Equatable {
    case microphone
    case screenRecording
    case speechModel

    // MARK: - Status

    public nonisolated var status: PermissionStatus {
        switch self {
        case .microphone:
            return Self.map(AVCaptureDevice.authorizationStatus(for: .audio))

        case .screenRecording:
            // CG has no notDetermined; true→authorized, false→denied.
            return CGPreflightScreenCaptureAccess() ? .authorized : .denied

        case .speechModel:
            if #available(macOS 26, *) {
                return SpeechTranscriber.isAvailable ? .authorized : .notDetermined
            }
            // Pre-macOS-26: the on-device model API doesn't exist.
            return .notDetermined
        }
    }

    // MARK: - Request

    /// Present the system prompt (when applicable) and return the resulting
    /// status. Best-effort; never throws.
    public func request() async -> PermissionStatus {
        switch self {
        case .microphone:
            let granted = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                AVCaptureDevice.requestAccess(for: .audio) { cont.resume(returning: $0) }
            }
            Log.info("[Permission] microphone request → granted=\(granted)")

        case .screenRecording:
            let prompted = CGRequestScreenCaptureAccess()
            Log.info("[Permission] screenRecording request → prompted=\(prompted)")

        case .speechModel:
            await Self.requestSpeechModel()
        }
        return status
    }

    // MARK: - Preflight

    /// Check (and, when never-asked, request) this permission.
    public func preflight() async -> PermissionPreflight {
        switch status {
        case .authorized:
            return .granted
        case .notDetermined, .unknown:
            return await request() == .authorized ? .granted : .denied(message: deniedMessage)
        case .denied, .restricted:
            return .denied(message: deniedMessage)
        }
    }

    // MARK: - Denied guidance

    public var deniedMessage: String {
        switch self {
        case .microphone:
            return "Microphone access is required to record meeting audio. "
                + "Grant it under System Settings → Privacy & Security → "
                + "Microphone, then try again."
        case .screenRecording:
            return "Screen Recording access is required to capture system "
                + "audio. Grant it under System Settings → Privacy & Security "
                + "→ Screen Recording, then try again."
        case .speechModel:
            return "On-device speech recognition is unavailable. Live "
                + "transcription requires macOS 26+ with a supported Neural "
                + "Engine and the on-device speech model installed. Check "
                + "System Settings → General → Language & Region → Speech "
                + "Recognition."
        }
    }

    // MARK: - Speech model helpers

    private static func requestSpeechModel() async {
        if #available(macOS 26, *) {
            guard SpeechTranscriber.isAvailable else {
                Log.info("[Permission] speechModel unsupported on this device")
                return
            }
            let locale = Locale.current
            let installedLocales = await SpeechTranscriber.installedLocales
            guard installedLocales.contains(where: { $0.isEquivalent(to: locale) }) else {
                Log.info("[Permission] speechModel not installed — triggering background download")
                let probe = SpeechTranscriber(locale: locale, preset: .transcription)
                do {
                    if let request = try await AssetInventory.assetInstallationRequest(supporting: [probe]) {
                        Task {
                            do {
                                try await request.downloadAndInstall()
                                Log.info("[Permission] speechModel download complete")
                            } catch {
                                Log.info("[Permission] speechModel download failed: \(error.localizedDescription)")
                            }
                        }
                    }
                } catch {
                    Log.info("[Permission] speechModel assetInstallationRequest error: \(error.localizedDescription)")
                }
                return
            }
            Log.info("[Permission] speechModel installed")
            await Self.ensureLocaleReserved(locale, logPrefix: "[Permission]")
            return
        }
        Log.info("[Permission] speechModel requires macOS 26+ — no-op")
    }

    /// Reserve `locale` if it isn't already (releasing a stale reservation
    /// first when at `AssetInventory.maximumReservedLocales`) so a genuinely
    /// installed model keeps reporting installed instead of lapsing after
    /// idle. Best-effort: a reserve failure doesn't block the caller.
    @available(macOS 26, *)
    public static func ensureLocaleReserved(_ locale: Locale, logPrefix: String) async {
        let reserved = await AssetInventory.reservedLocales
        guard !reserved.contains(where: { $0.isEquivalent(to: locale) }) else { return }
        if reserved.count >= AssetInventory.maximumReservedLocales, let stale = reserved.first {
            _ = await AssetInventory.release(reservedLocale: stale)
            Log.info("\(logPrefix) released stale reservation for \(stale.identifier) to make room")
        }
        do {
            try await AssetInventory.reserve(locale: locale)
            Log.info("\(logPrefix) reserved locale \(locale.identifier)")
        } catch {
            Log.info("\(logPrefix) reserve(locale:) failed: \(error.localizedDescription) — proceeding anyway (already installed)")
        }
    }

    // MARK: - Status mapping

    nonisolated static func map(_ status: AVAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .authorized:    return .authorized
        case .denied:        return .denied
        case .restricted:    return .restricted
        case .notDetermined: return .notDetermined
        @unknown default:    return .unknown
        }
    }
}
