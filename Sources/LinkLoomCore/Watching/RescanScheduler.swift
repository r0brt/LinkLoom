import Foundation

public actor RescanScheduler: SourceWatchScheduling {
    public nonisolated let changes: AsyncStream<DirectoryChange>
    private nonisolated let changeContinuation: AsyncStream<DirectoryChange>.Continuation
    private let watcher: any DirectoryWatching
    private let rescanner: any SourceRescanning
    private let debounceDuration: Duration
    private var streamTasks: [UUID: Task<Void, Never>] = [:]
    private var streamGenerations: [UUID: UUID] = [:]
    private var debounceTasks: [UUID: Task<Void, Never>] = [:]
    private var debounceGenerations: [UUID: UUID] = [:]

    public init(
        watcher: any DirectoryWatching,
        rescanner: any SourceRescanning
    ) {
        let changeStream = AsyncStream<DirectoryChange>.makeStream()
        changes = changeStream.stream
        changeContinuation = changeStream.continuation
        self.watcher = watcher
        self.rescanner = rescanner
        debounceDuration = .milliseconds(500)
    }

    init(
        watcher: any DirectoryWatching,
        rescanner: any SourceRescanning,
        debounceDuration: Duration
    ) {
        let changeStream = AsyncStream<DirectoryChange>.makeStream()
        changes = changeStream.stream
        changeContinuation = changeStream.continuation
        self.watcher = watcher
        self.rescanner = rescanner
        self.debounceDuration = debounceDuration
    }

    public func start(source: SourceRootRecord) {
        start(source: source, url: URL(fileURLWithPath: source.pathHint))
    }

    public func start(source: SourceRootRecord, url: URL) {
        stop(sourceID: source.id)
        let generation = UUID()
        streamGenerations[source.id] = generation
        let watcher = self.watcher
        streamTasks[source.id] = Task { [weak self] in
            var endedUnexpectedly = true
            do {
                for try await change in watcher.events(for: source.id, url: url) {
                    guard !Task.isCancelled else {
                        endedUnexpectedly = false
                        break
                    }
                    await self?.receive(
                        change,
                        source: source,
                        generation: generation
                    )
                }
            } catch is CancellationError {
                // Source-specific stop is an expected lifecycle event.
                endedUnexpectedly = false
            } catch {
                // The lifecycle event below allows the app to surface and retry it.
            }
            await self?.streamDidEnd(
                sourceID: source.id,
                generation: generation,
                reportUnavailable: endedUnexpectedly
            )
        }
    }

    public func stop(sourceID: UUID) {
        streamTasks.removeValue(forKey: sourceID)?.cancel()
        streamGenerations[sourceID] = nil
        debounceTasks.removeValue(forKey: sourceID)?.cancel()
        debounceGenerations[sourceID] = nil
    }

    public func isWatching(sourceID: UUID) -> Bool {
        streamTasks[sourceID] != nil
    }

    public func stopAll() {
        for task in streamTasks.values {
            task.cancel()
        }
        for task in debounceTasks.values {
            task.cancel()
        }
        streamTasks.removeAll()
        streamGenerations.removeAll()
        debounceTasks.removeAll()
        debounceGenerations.removeAll()
    }

    private func receive(
        _ change: DirectoryChange,
        source: SourceRootRecord,
        generation: UUID
    ) {
        guard change.sourceRootID == source.id,
              streamGenerations[source.id] == generation,
              streamTasks[source.id] != nil
        else {
            return
        }
        changeContinuation.yield(change)
        switch change.kind {
        case .contentChanged, .rootAvailable:
            scheduleRescan(source: source)
        case .rootUnavailable:
            debounceTasks.removeValue(forKey: source.id)?.cancel()
            debounceGenerations[source.id] = nil
        }
    }

    private func scheduleRescan(source: SourceRootRecord) {
        debounceTasks.removeValue(forKey: source.id)?.cancel()
        let generation = UUID()
        debounceGenerations[source.id] = generation
        let duration = debounceDuration
        let rescanner = self.rescanner
        debounceTasks[source.id] = Task { [weak self] in
            do {
                try await ContinuousClock().sleep(for: duration)
                try Task.checkCancellation()
                await rescanner.rescan(source: source)
                await self?.debounceDidEnd(
                    sourceID: source.id,
                    generation: generation
                )
            } catch {
                await self?.debounceDidEnd(
                    sourceID: source.id,
                    generation: generation
                )
            }
        }
    }

    private func streamDidEnd(
        sourceID: UUID,
        generation: UUID,
        reportUnavailable: Bool
    ) {
        guard streamGenerations[sourceID] == generation else { return }
        streamTasks[sourceID] = nil
        streamGenerations[sourceID] = nil
        debounceTasks.removeValue(forKey: sourceID)?.cancel()
        debounceGenerations[sourceID] = nil
        if reportUnavailable {
            changeContinuation.yield(DirectoryChange(
                sourceRootID: sourceID,
                kind: .rootUnavailable
            ))
        }
    }

    private func debounceDidEnd(sourceID: UUID, generation: UUID) {
        guard debounceGenerations[sourceID] == generation else { return }
        debounceTasks[sourceID] = nil
        debounceGenerations[sourceID] = nil
    }
}
