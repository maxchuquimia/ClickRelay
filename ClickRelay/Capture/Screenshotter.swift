import CoreGraphics
import Foundation
import ImageIO
import os
import ScreenCaptureKit
import UniformTypeIdentifiers

nonisolated enum CaptureFormat: String, Sendable {
    case png, jpeg

    var mimeType: String { self == .png ? "image/png" : "image/jpeg" }
    var utType: UTType { self == .png ? .png : .jpeg }
}

/// A captured image and the geometry that maps its pixels back to points:
/// `point = origin + pixel / scale`, in global screen points.
nonisolated struct CaptureResult: Sendable {
    let data: Data
    let format: CaptureFormat
    let pixelWidth: Int
    let pixelHeight: Int
    /// Image pixels per point.
    let scale: Double
    /// Global screen point at the image's top-left.
    let origin: CGPoint
    /// The window captured, or nil for a display capture.
    let windowID: CGWindowID?
    /// Allowed windows visible in a display capture, with their rects in
    /// image pixels, so the agent can pick a `window_id` for what it sees.
    let windows: [VisibleWindow]
    /// A small JPEG for the activity feed and audit log.
    let thumbnail: Data?

    struct VisibleWindow: Sendable {
        let id: CGWindowID
        let app: String
        let title: String
        let pixelRect: CGRect
    }
}

nonisolated enum CaptureError: Error, Equatable {
    case noPermission
    case windowNotFound(CGWindowID)
    case windowNotAllowed(app: String)
    case noAllowedAppsOnScreen
    case noDisplay
    /// macOS's own "allow this app to keep capturing your screen" prompt
    /// (shown on the first capture and again from time to time, and after the
    /// app's signature changes) wasn't answered with Allow. ScreenCaptureKit
    /// calls this "the user declined TCCs"; TCC is macOS's privacy database.
    case declined
    case failed(String)

    /// From whatever ScreenCaptureKit threw.
    init(_ error: any Error) {
        let ns = error as NSError
        if ns.domain == SCStreamErrorDomain, ns.code == SCStreamError.Code.userDeclined.rawValue {
            self = .declined
        } else {
            self = .failed(error.localizedDescription)
        }
    }

    var message: String {
        switch self {
        case .noPermission:
            "ClickRelay doesn't have Screen Recording permission. Ask the user to grant it in ClickRelay's window."
        case .declined:
            "Screenshots are blocked: macOS asked the user to confirm ClickRelay can keep capturing the screen, "
                + "and it wasn't allowed. Only the user can fix this, so stop: don't retry screenshots or carry on "
                + "without them. Call clickrelay_notify with status needs_you, asking them to open ClickRelay, press "
                + "Take Test Screenshot and choose Allow, then wait until they tell you it's fixed."
        case .windowNotFound(let id):
            "Window \(id) isn't on screen (closed, minimised or on another Space). Call clickrelay_list_windows for current windows."
        case .windowNotAllowed(let app):
            "That window belongs to \(app), which isn't allowed. Ask the user to allow \(app) if you need it."
        case .noAllowedAppsOnScreen:
            "None of the allowed apps have windows on the main display. Open one with clickrelay_launch_app, or ask the user to bring it on screen."
        case .noDisplay:
            "ClickRelay couldn't find the main display."
        case .failed(let reason):
            "The screenshot failed: \(reason)"
        }
    }
}

/// Screenshots through ScreenCaptureKit (never the deprecated
/// `CGWindowListCreateImage`), filtered to the lease's allowed apps.
nonisolated enum Screenshotter {
    static let thumbnailEdge = 400

    /// Only the window's own pixels: overlapping windows from other apps
    /// don't appear.
    static func captureWindow(id: CGWindowID, policy: AccessPolicy, maxEdge: Int,
                              format: CaptureFormat) async throws(CaptureError) -> CaptureResult {
        guard CGPreflightScreenCaptureAccess() else { throw .noPermission }
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        } catch {
            throw CaptureError(error)
        }
        guard let window = content.windows.first(where: { $0.windowID == id }) else {
            throw .windowNotFound(id)
        }
        guard let app = window.owningApplication, policy.allows(bundleID: app.bundleIdentifier),
              app.processID != getpid() else {
            throw .windowNotAllowed(app: window.owningApplication?.applicationName ?? "another app")
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        let size = window.frame.size
        let scale = targetScale(points: size, backing: Double(filter.pointPixelScale), maxEdge: maxEdge)
        configuration.width = max(1, Int((size.width * scale).rounded()))
        configuration.height = max(1, Int((size.height * scale).rounded()))
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        configuration.captureResolution = .best
        let image = try await capture(filter, configuration)
        return try encode(image, format: format, pointWidth: size.width, origin: window.frame.origin,
                          windowID: id, windows: [])
    }

    /// The main display with only the allowed apps in it. Everything else,
    /// ClickRelay's own windows and overlay included, is left out.
    ///
    /// `excludingPIDs` are apps the user is working in for a hand-off: left
    /// out like apps that aren't allowed.
    static func captureDisplay(policy: AccessPolicy, maxEdge: Int, format: CaptureFormat,
                               windowTitles: [CGWindowID: String] = [:],
                               excludingPIDs: Set<pid_t> = []) async throws(CaptureError) -> CaptureResult {
        guard CGPreflightScreenCaptureAccess() else { throw .noPermission }
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        } catch {
            throw CaptureError(error)
        }
        let mainID = CGMainDisplayID()
        guard let display = content.displays.first(where: { $0.displayID == mainID })
                ?? content.displays.first else { throw .noDisplay }
        let me = getpid()
        let apps = content.applications.filter {
            policy.allows(bundleID: $0.bundleIdentifier) && $0.processID != me
                && !excludingPIDs.contains($0.processID)
        }
        let allowedPIDs = Set(apps.map(\.processID))
        let visible = content.windows.filter { window in
            guard let pid = window.owningApplication?.processID, allowedPIDs.contains(pid) else { return false }
            return window.isOnScreen && window.windowLayer < 20 && window.frame.intersects(display.frame)
                && window.frame.width >= 2 && window.frame.height >= 2
        }
        guard !apps.isEmpty, !visible.isEmpty else { throw .noAllowedAppsOnScreen }

        let filter = SCContentFilter(display: display, including: apps, exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        let size = display.frame.size
        let scale = targetScale(points: size, backing: Double(filter.pointPixelScale), maxEdge: maxEdge)
        configuration.width = max(1, Int((size.width * scale).rounded()))
        configuration.height = max(1, Int((size.height * scale).rounded()))
        configuration.showsCursor = false
        configuration.captureResolution = .best
        let image = try await capture(filter, configuration)

        let origin = display.frame.origin
        let windows = visible.map { window in
            CaptureResult.VisibleWindow(
                id: window.windowID,
                app: window.owningApplication?.applicationName ?? "",
                title: windowTitles[window.windowID] ?? window.title ?? "",
                pixelRect: CGRect(x: (window.frame.minX - origin.x) * scale,
                                  y: (window.frame.minY - origin.y) * scale,
                                  width: window.frame.width * scale,
                                  height: window.frame.height * scale))
        }
        return try encode(image, format: format, pointWidth: size.width, origin: origin, windowID: nil,
                          windows: windows)
    }

    /// A tiny capture of ClickRelay's own windows and nothing else, taken
    /// during setup. On macOS 15 and later the first ScreenCaptureKit capture
    /// shows a second prompt ("bypass the system private window picker"),
    /// separate from the Screen Recording grant; this makes it appear while
    /// the user is setting up rather than in the middle of an agent's call.
    /// The first attempt usually fails at once while that prompt is still on
    /// screen, so this keeps trying until the user answers or `timeout`
    /// passes. Returns nil on success, else the last error's description.
    static func probeDirectCapture(timeout: Duration = .seconds(30)) async -> String? {
        guard CGPreflightScreenCaptureAccess() else { return "Screen Recording isn't granted" }
        let deadline = ContinuousClock.now + timeout
        var lastError = "unknown error"
        repeat {
            do {
                try await captureOwnWindows()
                return nil
            } catch {
                lastError = CaptureError(error) == .declined
                    ? "macOS's screen recording prompt wasn't answered with Allow"
                    : "\(error.localizedDescription) (\((error as NSError).domain) \((error as NSError).code))"
                probeLog.error("Test capture failed: \(lastError, privacy: .public)")
            }
            try? await Task.sleep(for: .seconds(1))
        } while ContinuousClock.now < deadline && !Task.isCancelled
        return lastError
    }

    private static let probeLog = Logger(subsystem: "io.mergeable.ClickRelay", category: "capture")

    private static func captureOwnWindows() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let me = getpid()
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() })
                ?? content.displays.first else {
            throw NSError(domain: "ClickRelay", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "no display found"])
        }
        let own = content.applications.filter { $0.processID == me }
        let filter = SCContentFilter(display: display, including: own, exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = 64
        configuration.height = 40
        configuration.showsCursor = false
        _ = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }

    /// Pixels per point: the display's own backing scale, reduced so the long
    /// edge fits `maxEdge`.
    static func targetScale(points: CGSize, backing: Double, maxEdge: Int) -> Double {
        let longest = max(points.width, points.height)
        guard longest > 0 else { return 1 }
        let backing = backing > 0 ? backing : 1
        return min(backing, Double(max(64, maxEdge)) / Double(longest))
    }

    private static func capture(_ filter: SCContentFilter,
                                _ configuration: SCStreamConfiguration) async throws(CaptureError) -> CGImage {
        do {
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        } catch {
            throw CaptureError(error)
        }
    }

    private static func encode(_ image: CGImage, format: CaptureFormat, pointWidth: CGFloat, origin: CGPoint,
                               windowID: CGWindowID?,
                               windows: [CaptureResult.VisibleWindow]) throws(CaptureError) -> CaptureResult {
        guard let data = encodeImage(image, as: format, quality: 0.85) else {
            throw .failed("couldn't encode the image")
        }
        // The scale actually delivered, in case the capture size was rounded.
        let delivered = Double(image.width) / max(1, Double(pointWidth))
        return CaptureResult(data: data, format: format, pixelWidth: image.width,
                             pixelHeight: image.height, scale: delivered, origin: origin,
                             windowID: windowID, windows: windows,
                             thumbnail: thumbnail(of: image))
    }

    static func encodeImage(_ image: CGImage, as format: CaptureFormat, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, format.utType.identifier as CFString, 1, nil) else { return nil }
        let properties: [CFString: Any] = format == .jpeg
            ? [kCGImageDestinationLossyCompressionQuality: quality] : [:]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// A 400 px JPEG, for the activity feed and the audit log.
    static func thumbnail(of image: CGImage) -> Data? {
        let longest = max(image.width, image.height)
        let factor = min(1, Double(thumbnailEdge) / Double(max(1, longest)))
        let width = max(1, Int(Double(image.width) * factor))
        let height = max(1, Int(Double(image.height) * factor))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let small = context.makeImage() else { return nil }
        return encodeImage(small, as: .jpeg, quality: 0.7)
    }
}
