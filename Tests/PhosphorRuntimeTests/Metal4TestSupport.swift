import Dispatch
import Metal

/// Minimal synchronous Metal 4 submission helper for tests.
///
/// Owns an `MTL4CommandQueue` and submits one command buffer at a time,
/// blocking until the GPU finishes. The renderer applies its own per-command
/// buffer residency set; raw-encoder tests pass their resources via `resident`,
/// which this harness attaches to the queue.
struct Metal4Harness {
    let device: MTLDevice
    let queue: MTL4CommandQueue

    init(device: MTLDevice) throws {
        self.device = device
        guard let queue = try device.makeMTL4CommandQueue() else {
            throw HarnessError.commandQueueCreationFailed
        }
        self.queue = queue
    }

    enum HarnessError: Error {
        case commandQueueCreationFailed
        case commandBufferCreationFailed
    }

    /// Begins a command buffer, runs `encode`, then commits and waits.
    func run(_ encode: (MTL4CommandBuffer) throws -> Void) throws {
        try run(resident: [], encode)
    }

    /// Begins a command buffer, runs `encode`, then commits and waits.
    /// Allocations in `resident` are made resident on the queue for the submission.
    func run(resident: [MTLAllocation], _ encode: (MTL4CommandBuffer) throws -> Void) throws {
        let allocator = try device.makeCommandAllocator(descriptor: MTL4CommandAllocatorDescriptor())
        guard let commandBuffer = device.makeCommandBuffer() else {
            throw HarnessError.commandBufferCreationFailed
        }
        if !resident.isEmpty {
            let set = try device.makeResidencySet(descriptor: MTLResidencySetDescriptor())
            for allocation in resident { set.addAllocation(allocation) }
            set.commit()
            queue.addResidencySet(set)
        }
        commandBuffer.beginCommandBuffer(allocator: allocator)
        try encode(commandBuffer)
        commandBuffer.endCommandBuffer()

        let semaphore = DispatchSemaphore(value: 0)
        let options = MTL4CommitOptions()
        options.addFeedbackHandler { _ in semaphore.signal() }
        queue.commit([commandBuffer], options: options)
        semaphore.wait()
    }
}
