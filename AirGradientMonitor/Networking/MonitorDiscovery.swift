import Foundation
import Network
import Observation

/// Finds AirGradient monitors on the local network over Bonjour.
///
/// Firmware 3.0.10+ advertises `_airgradient._tcp`, and also answers to
/// `airgradient_<serial>.local` over plain `_http._tcp`. Older firmware does
/// neither, which is why manual entry by IP is a first-class path in `AddMonitorView`
/// rather than a fallback buried in a menu.
///
/// Browsing requires `NSLocalNetworkUsageDescription` and the matching
/// `NSBonjourServices` entries in Info.plist — without them the browser fails
/// silently with no callback at all, which reads exactly like "no devices here".
@MainActor
@Observable
final class MonitorDiscovery {
    struct Found: Identifiable, Hashable {
        var id: String { serviceName }
        /// e.g. `airgradient_ecda3b1a2b3c`
        let serviceName: String
        /// e.g. `airgradient_ecda3b1a2b3c.local`
        var host: String { serviceName.hasSuffix(".local") ? serviceName : serviceName + ".local" }
        /// Serial number carved out of the service name, when it looks like one.
        var serial: String? {
            let s = serviceName.replacingOccurrences(of: ".local", with: "")
            guard let r = s.range(of: "airgradient_") else { return nil }
            let tail = String(s[r.upperBound...])
            return tail.isEmpty ? nil : tail
        }
    }

    private(set) var found: [Found] = []
    private(set) var isBrowsing = false
    private(set) var failure: String?

    private var browsers: [NWBrowser] = []

    /// Both service types, because which one a monitor answers on depends on
    /// its firmware, and a monitor seen twice is deduplicated by service name.
    private static let serviceTypes = ["_airgradient._tcp", "_http._tcp"]

    func start() {
        guard browsers.isEmpty else { return }
        found = []
        failure = nil
        isBrowsing = true

        let params = NWParameters()
        params.includePeerToPeer = false

        for type in Self.serviceTypes {
            let browser = NWBrowser(for: .bonjour(type: type, domain: "local."), using: params)
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                Task { @MainActor in self?.absorb(results) }
            }
            browser.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    if case .failed(let error) = state {
                        // One browser failing (usually: no local-network
                        // permission) should say so rather than look empty.
                        self?.failure = error.localizedDescription
                    }
                }
            }
            browser.start(queue: .main)
            browsers.append(browser)
        }
    }

    func stop() {
        browsers.forEach { $0.cancel() }
        browsers = []
        isBrowsing = false
    }

    private func absorb(_ results: Set<NWBrowser.Result>) {
        for result in results {
            guard case .service(let name, _, _, _) = result.endpoint else { continue }
            // `_http._tcp` is a crowded namespace — printers, NAS boxes, other
            // people's projects. Only AirGradient's own naming gets in.
            guard name.lowercased().hasPrefix("airgradient") else { continue }
            guard !found.contains(where: { $0.serviceName == name }) else { continue }
            found.append(Found(serviceName: name))
        }
        found.sort { $0.serviceName.localizedStandardCompare($1.serviceName) == .orderedAscending }
    }
}
