import Foundation

actor VMShutdownCoordinator {
    private var activeName: String?
    private var cleanupStarted = false
    private var deregister: (@Sendable () async -> Void)?
    private let destroyer: VMDestroyer
    private let logger: Logger

    init(destroyer: VMDestroyer, logger: Logger) {
        self.destroyer = destroyer
        self.logger = logger
    }

    func activate(name: String) {
        activeName = name
        cleanupStarted = false
        deregister = nil
        logger.info("shutdown coordinator activated for VM \(name)")
    }

    func setDeregistration(_ action: @escaping @Sendable () async -> Void) {
        deregister = action
    }

    func cleanup(reason: String? = nil) async {
        let reasonLabel = reason ?? "unspecified"
        guard !cleanupStarted, let name = activeName else {
            if cleanupStarted {
                logger.debug("cleanup skipped: already started (reason: \(reasonLabel))")
            } else {
                logger.debug("cleanup skipped: no active VM (reason: \(reasonLabel))")
            }
            return
        }
        cleanupStarted = true
        logger.info("cleanup start for VM \(name) (reason: \(reasonLabel))")
        try? await destroyer.destroy(name: name)
        if let deregister {
            await deregister()
        }
        deregister = nil
        logger.info("cleanup complete for VM \(name)")
        activeName = nil
    }
}
