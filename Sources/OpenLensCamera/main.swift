import CoreMediaIO
import Foundation
import os.log

let logger = Logger(subsystem: OpenLensID.extensionBundleID, category: "extension")

logger.info("OpenLens camera extension starting")

let providerSource = OpenLensProviderSource(clientQueue: nil)
CMIOExtensionProvider.startService(provider: providerSource.provider)

CFRunLoopRun()
