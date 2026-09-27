import Foundation

/// The ordered queue of offload frames and the one task that drains it into the Backfiller. Frames are
/// appended synchronously (delegate order) and drained sequentially in small slices, so START / data / END
/// chunk assembly is never reordered while the UI still gets time to paint.
@MainActor
final class BackfillDrain {
    private var queue: [[UInt8]] = []
    /// True while the drain task is running (prevents a second drain task from launching).
    private var draining = false
    private let batchSize: Int
    private let ingest: ([UInt8]) async -> Void
    /// Called after every ingest; false ends the drain and drops what is still queued (the session ended).
    private let afterIngest: () -> Bool

    init(batchSize: Int, ingest: @escaping ([UInt8]) async -> Void, afterIngest: @escaping () -> Bool) {
        self.batchSize = batchSize
        self.ingest = ingest
        self.afterIngest = afterIngest
    }

    func route(_ frame: [UInt8]) {
        queue.append(frame)
        guard !draining else { return }
        draining = true
        Task { @MainActor in await drain() }
    }

    /// The offload session ended: drop what is queued.
    func dropQueued() {
        queue.removeAll()
    }

    /// The link ended.
    func linkEnded() {
        queue.removeAll()
        draining = false
    }

    private func drain() async {
        while !queue.isEmpty {
            let count = min(batchSize, queue.count)
            let batch = Array(queue.prefix(count))
            queue.removeFirst(count)

            for f in batch {
                await ingest(f)
                if !afterIngest() {
                    queue.removeAll(keepingCapacity: true)
                    break
                }
            }

            if !queue.isEmpty {
                await Task.yield()
            }
        }
        draining = false
    }
}
