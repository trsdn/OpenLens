import Foundation

/// Tells the app whether a conferencing app currently has the virtual camera open.
///
/// A CoreMediaIO extension only gets to vend the one mach service the DAL
/// assistant asks for, so a private `NSXPCListener` is not an option, and the
/// extension runs as root so its app-group container is not the same directory
/// the app sees. What is left — and what fits a single bit of state — is Darwin
/// notifications, which are system-wide and free.
///
/// Sandboxed processes may only use notification names prefixed with their app
/// group, hence the naming. State is carried by *which* name is posted, so no
/// shared storage is needed. A newly launched app posts `query` and the
/// extension answers, which covers the "app started mid-call" case.
public enum StreamingStateChannel {
    private static let onName = "\(OpenLensID.appGroup).streaming.on"
    private static let offName = "\(OpenLensID.appGroup).streaming.off"
    private static let queryName = "\(OpenLensID.appGroup).streaming.query"

    private static func post(_ name: String) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name as CFString),
            nil,
            nil,
            true
        )
    }

    private static func addObserver(
        _ name: String,
        _ observer: DarwinObserver,
        _ callback: @escaping CFNotificationCallback
    ) {
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(observer).toOpaque(),
            callback,
            name as CFString,
            nil,
            .deliverImmediately
        )
    }

    // MARK: - Extension side

    /// Called by the extension when its source stream starts or stops.
    public static func publish(_ isStreaming: Bool) {
        post(isStreaming ? onName : offName)
    }

    /// Answers `query` posts from a freshly launched app.
    public static func answerQueries(_ currentValue: @escaping () -> Bool) -> DarwinObserver {
        let observer = DarwinObserver { publish(currentValue()) }
        addObserver(queryName, observer) { _, raw, _, _, _ in
            guard let raw else { return }
            Unmanaged<DarwinObserver>.fromOpaque(raw).takeUnretainedValue().fire()
        }
        return observer
    }

    // MARK: - App side

    /// Observes streaming state and immediately asks the extension for the
    /// current value. Call ``cancel(_:)`` to stop observing.
    public static func observe(
        queue: DispatchQueue,
        handler: @escaping (Bool) -> Void
    ) -> DarwinObserver {
        let observer = DarwinObserver(queue: queue, handler: handler)
        addObserver(onName, observer) { _, raw, _, _, _ in
            guard let raw else { return }
            Unmanaged<DarwinObserver>.fromOpaque(raw).takeUnretainedValue().fire(true)
        }
        addObserver(offName, observer) { _, raw, _, _, _ in
            guard let raw else { return }
            Unmanaged<DarwinObserver>.fromOpaque(raw).takeUnretainedValue().fire(false)
        }
        post(queryName)
        return observer
    }

    public static func cancel(_ observer: DarwinObserver?) {
        guard let observer else { return }
        CFNotificationCenterRemoveEveryObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(observer).toOpaque()
        )
    }
}

/// Keeps a callback alive for as long as the Darwin observation is registered.
public final class DarwinObserver {
    private let queue: DispatchQueue?
    private let valueHandler: ((Bool) -> Void)?
    private let plainHandler: (() -> Void)?

    init(queue: DispatchQueue, handler: @escaping (Bool) -> Void) {
        self.queue = queue
        self.valueHandler = handler
        self.plainHandler = nil
    }

    init(_ handler: @escaping () -> Void) {
        self.queue = nil
        self.valueHandler = nil
        self.plainHandler = handler
    }

    func fire() {
        plainHandler?()
    }

    func fire(_ value: Bool) {
        guard let valueHandler else { return }
        if let queue {
            queue.async { valueHandler(value) }
        } else {
            valueHandler(value)
        }
    }
}
