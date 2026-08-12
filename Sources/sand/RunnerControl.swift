import Foundation

actor RunnerControl {
    private var provisioningHandle: ProcessHandle?
    private var healthCheckTask: Task<Void, Never>?

    func setProvisioningHandle(_ handle: ProcessHandle) {
        provisioningHandle = handle
    }

    func clearProvisioningHandle(_ handle: ProcessHandle) {
        if provisioningHandle === handle {
            provisioningHandle = nil
        }
    }

    func terminateProvisioning() async {
        let handle = provisioningHandle
        provisioningHandle = nil
        if let handle {
            await handle.terminate()
        }
    }

    func setHealthCheckTask(_ task: Task<Void, Never>) {
        healthCheckTask = task
    }

    func clearHealthCheckTask() {
        healthCheckTask = nil
    }

    func cancelHealthCheck() {
        let task = healthCheckTask
        healthCheckTask = nil
        task?.cancel()
    }

    private var offlineMonitorTask: Task<Void, Never>?

    func setOfflineMonitorTask(_ task: Task<Void, Never>) {
        offlineMonitorTask = task
    }

    func takeOfflineMonitorTask() -> Task<Void, Never>? {
        let task = offlineMonitorTask
        offlineMonitorTask = nil
        return task
    }

    func cancelOfflineMonitor() async {
        let task = offlineMonitorTask
        offlineMonitorTask = nil
        task?.cancel()
        // Await the task out even on the signal path: cleanup runs
        // concurrently there, and a poll past its cancellation check must not
        // race it (spec: cancellation alone is not sufficient).
        if let task {
            await task.value
        }
    }
}
