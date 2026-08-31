import AppKit
@preconcurrency import NetworkExtension
@preconcurrency import SystemExtensions
import TrafficCtrlFilterHostCore

private let filterExtensionIdentifier = "com.stealthfactory.trafficctrl.filter-extension"

@MainActor
final class FilterHostDelegate: NSObject, NSApplicationDelegate, @preconcurrency OSSystemExtensionRequestDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var repository: FilterRuleRepository?
    private var server: FilterSocketServer?
    private var status = "Checking filter…" {
        didSet { rebuildMenu() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem.button?.title = "Traffic Ctrl"
        rebuildMenu()
        loadFilterStatus()
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        let statusLine = NSMenuItem(title: status, action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Install or enable network filter", action: #selector(enable), keyEquivalent: "e").target = self
        menu.addItem(withTitle: "Disable network filter", action: #selector(disable), keyEquivalent: "d").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Traffic Ctrl Filter", action: #selector(quit), keyEquivalent: "q").target = self
        statusItem.menu = menu
    }

    @objc private func enable() {
        status = "Requesting system-extension approval…"
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: filterExtensionIdentifier,
            queue: .main
        )
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    @objc private func disable() {
        let manager = NEFilterManager.shared()
        manager.loadFromPreferences { [weak self] error in
            guard error == nil else {
                Task { @MainActor in self?.status = "Could not load filter: \(error!.localizedDescription)" }
                return
            }
            manager.isEnabled = false
            manager.saveToPreferences { saveError in
                Task { @MainActor in
                    self?.repository?.removeAllRules()
                    self?.stopBroker()
                    self?.status = saveError.map { "Could not disable filter: \($0.localizedDescription)" }
                        ?? "Network filter disabled (fail-open)"
                }
            }
        }
    }

    @objc private func quit() {
        stopBroker()
        NSApp.terminate(nil)
    }

    private func loadFilterStatus() {
        let manager = NEFilterManager.shared()
        manager.loadFromPreferences { [weak self] error in
            Task { @MainActor in
                if let error {
                    self?.status = "Filter unavailable: \(error.localizedDescription)"
                } else if manager.isEnabled {
                    self?.startBroker()
                } else {
                    self?.status = "Network filter not enabled"
                }
            }
        }
    }

    private func configureAndEnableFilter() {
        let manager = NEFilterManager.shared()
        manager.loadFromPreferences { [weak self] error in
            guard error == nil else {
                Task { @MainActor in self?.status = "Could not load filter: \(error!.localizedDescription)" }
                return
            }
            let configuration = NEFilterProviderConfiguration()
            configuration.filterSockets = true
            configuration.filterPackets = false
            configuration.filterDataProviderBundleIdentifier = filterExtensionIdentifier
            manager.providerConfiguration = configuration
            manager.localizedDescription = "Traffic Ctrl Network Filter"
            manager.isEnabled = true
            manager.saveToPreferences { saveError in
                Task { @MainActor in
                    if let saveError {
                        self?.status = "Could not enable filter: \(saveError.localizedDescription)"
                    } else {
                        self?.startBroker()
                    }
                }
            }
        }
    }

    private func startBroker() {
        stopBroker()
        do {
            let repository = try FilterRuleRepository()
            let server = FilterSocketServer(repository: repository)
            try server.start()
            self.repository = repository
            self.server = server
            status = "Network filter ready"
        } catch {
            status = "Filter enabled; control service failed: \(error.localizedDescription)"
        }
    }

    private func stopBroker() {
        server?.stop()
        server = nil
        repository = nil
    }

    func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension ext: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        status = "Approve Traffic Ctrl in System Settings → Privacy & Security"
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        status = "System extension installed; enabling filter…"
        configureAndEnableFilter()
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        status = "System extension failed: \(error.localizedDescription)"
    }
}

let application = NSApplication.shared
let delegate = FilterHostDelegate()
application.delegate = delegate
application.run()
