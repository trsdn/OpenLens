import Foundation
import IOSurface
import os.log
import SystemExtensions

/// Installs and updates the camera system extension.
///
/// macOS only activates an extension that lives inside an app in `/Applications`,
/// and it needs a one-time approval in System Settings, so the surfaced state is
/// deliberately explicit rather than a bare success/failure.
final class SystemExtensionInstaller: NSObject, ObservableObject {
    enum State: Equatable {
        case unknown
        case installing
        case needsApproval
        case needsReboot
        case installed
        case failed(String)
    }

    @Published private(set) var state: State = .unknown

    private let log = Logger(subsystem: OpenLensID.appBundleID, category: "sysext")

    func activate() {
        guard Bundle.main.bundlePath.hasPrefix("/Applications") else {
            state = .failed(
                "Move OpenLens to your Applications folder — macOS refuses to install a "
                    + "camera extension from anywhere else."
            )
            return
        }
        state = .installing
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: OpenLensID.extensionBundleID,
            queue: .main
        )
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func deactivate() {
        let request = OSSystemExtensionRequest.deactivationRequest(
            forExtensionWithIdentifier: OpenLensID.extensionBundleID,
            queue: .main
        )
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }
}

extension SystemExtensionInstaller: OSSystemExtensionRequestDelegate {
    func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension replacement: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        log.info(
            """
            Replacing extension \(existing.bundleVersion, privacy: .public) with \
            \(replacement.bundleVersion, privacy: .public)
            """
        )
        return .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        state = .needsApproval
    }

    func request(
        _ request: OSSystemExtensionRequest,
        didFinishWithResult result: OSSystemExtensionRequest.Result
    ) {
        state = result == .willCompleteAfterReboot ? .needsReboot : .installed
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        log.error("Activation failed: \(error.localizedDescription, privacy: .public)")
        state = .failed(error.localizedDescription)
    }
}
