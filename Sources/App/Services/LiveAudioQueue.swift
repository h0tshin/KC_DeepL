import AudioToolbox
import Foundation

enum LiveAudioQueueError: Error, LocalizedError {
    case coreAudio(String, OSStatus)

    var errorDescription: String? {
        switch self {
        case .coreAudio(let operation, let status):
            return "\(operation) 실패: OSStatus \(status)"
        }
    }
}

struct LiveAudioPlaybackProgress: Equatable {
    let playedFrames: Int64
    let enqueuedFrames: Int64
    let sampleRate: Int

    var playedDuration: TimeInterval {
        TimeInterval(playedFrames) / TimeInterval(sampleRate)
    }

    var enqueuedDuration: TimeInterval {
        TimeInterval(enqueuedFrames) / TimeInterval(sampleRate)
    }

    var bufferedDuration: TimeInterval {
        let bufferedFrames = max(0, enqueuedFrames - playedFrames)
        return TimeInterval(bufferedFrames) / TimeInterval(sampleRate)
    }

    var isDrained: Bool {
        enqueuedFrames > 0 && playedFrames >= enqueuedFrames
    }
}

final class LivePCMInputStream {
    private let device: LiveAudioDevice
    private let sampleRate: Int
    private let channelCount: Int
    private let chunkMilliseconds: Int
    private let onAudio: (Data) -> Void
    private var queue: AudioQueueRef?
    private var buffers: [AudioQueueBufferRef] = []
    private var isRunning = false
    private let stateLock = NSLock()

    init(
        device: LiveAudioDevice,
        sampleRate: Int,
        channelCount: Int = 1,
        chunkMilliseconds: Int = 100,
        onAudio: @escaping (Data) -> Void
    ) {
        self.device = device
        self.sampleRate = sampleRate
        self.channelCount = max(1, channelCount)
        self.chunkMilliseconds = max(20, chunkMilliseconds)
        self.onAudio = onAudio
    }

    deinit {
        stop()
    }

    func start() throws {
        stateLock.lock()
        if isRunning {
            stateLock.unlock()
            return
        }
        stateLock.unlock()

        var format = Self.pcmFormat(sampleRate: sampleRate, channelCount: channelCount)
        var newQueue: AudioQueueRef?
        let userData = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        var status = AudioQueueNewInput(&format, Self.inputCallback, userData, nil, nil, 0, &newQueue)
        try Self.check(status, "AudioQueueNewInput")
        guard let newQueue else {
            throw LiveAudioQueueError.coreAudio("AudioQueueNewInput", -1)
        }
        var ownsNewQueue = true
        defer {
            if ownsNewQueue {
                AudioQueueDispose(newQueue, true)
            }
        }

        try Self.setCurrentDevice(device, on: newQueue)

        let bytesPerFrame = Int(format.mBytesPerFrame)
        let framesPerBuffer = max(1, sampleRate * chunkMilliseconds / 1_000)
        let bufferByteSize = UInt32(framesPerBuffer * bytesPerFrame)
        var allocatedBuffers: [AudioQueueBufferRef] = []

        for _ in 0..<3 {
            var buffer: AudioQueueBufferRef?
            status = AudioQueueAllocateBuffer(newQueue, bufferByteSize, &buffer)
            try Self.check(status, "AudioQueueAllocateBuffer(input)")
            if let buffer {
                allocatedBuffers.append(buffer)
                status = AudioQueueEnqueueBuffer(newQueue, buffer, 0, nil)
                try Self.check(status, "AudioQueueEnqueueBuffer(input)")
            }
        }

        stateLock.lock()
        queue = newQueue
        buffers = allocatedBuffers
        isRunning = true
        stateLock.unlock()
        ownsNewQueue = false

        do {
            status = AudioQueueStart(newQueue, nil)
            try Self.check(status, "AudioQueueStart(input)")
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        stateLock.lock()
        let currentQueue = queue
        queue = nil
        buffers.removeAll()
        isRunning = false
        stateLock.unlock()

        if let currentQueue {
            AudioQueueStop(currentQueue, true)
            AudioQueueDispose(currentQueue, true)
        }
    }

    private func handleInputBuffer(_ queue: AudioQueueRef, buffer: AudioQueueBufferRef) {
        stateLock.lock()
        guard isRunning, self.queue == queue else {
            stateLock.unlock()
            return
        }

        let byteSize = Int(buffer.pointee.mAudioDataByteSize)
        if byteSize > 0 {
            let data = Data(bytes: buffer.pointee.mAudioData, count: byteSize)
            onAudio(data)
        }

        AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
        stateLock.unlock()
    }

    private static let inputCallback: AudioQueueInputCallback = { userData, queue, buffer, _, _, _ in
        guard let userData else {
            return
        }
        let stream = Unmanaged<LivePCMInputStream>.fromOpaque(userData).takeUnretainedValue()
        stream.handleInputBuffer(queue, buffer: buffer)
    }

    fileprivate static func pcmFormat(sampleRate: Int, channelCount: Int) -> AudioStreamBasicDescription {
        let channels = UInt32(max(1, channelCount))
        let bytesPerSample = UInt32(MemoryLayout<Int16>.size)
        return AudioStreamBasicDescription(
            mSampleRate: Float64(sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: channels * bytesPerSample,
            mFramesPerPacket: 1,
            mBytesPerFrame: channels * bytesPerSample,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 16,
            mReserved: 0
        )
    }

    fileprivate static func setCurrentDevice(_ device: LiveAudioDevice, on queue: AudioQueueRef) throws {
        guard let uid = device.uid else {
            return
        }

        var uidRef: CFString? = uid as CFString
        let status = withUnsafeBytes(of: &uidRef) { rawBuffer in
            AudioQueueSetProperty(
                queue,
                kAudioQueueProperty_CurrentDevice,
                rawBuffer.baseAddress!,
                UInt32(rawBuffer.count)
            )
        }
        try check(status, "AudioQueueSetProperty(CurrentDevice)")
    }

    fileprivate static func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else {
            throw LiveAudioQueueError.coreAudio(operation, status)
        }
    }
}

final class LivePCMOutputQueue {
    private struct BufferMetadata {
        let generation: UInt64
        let frameCount: Int64
    }

    private let device: LiveAudioDevice
    private let sampleRate: Int
    private let channelCount: Int
    private let bytesPerFrame: Int
    private let maximumBufferedFrames: Int64
    var onPlaybackProgress: ((LiveAudioPlaybackProgress) -> Void)?
    private var queue: AudioQueueRef?
    private var isRunning = false
    private var gain: Double
    private var enqueuedFrames: Int64 = 0
    private var playedFrames: Int64 = 0
    private var playbackGeneration: UInt64 = 0
    private var bufferMetadata: [UInt: BufferMetadata] = [:]
    private let stateLock = NSLock()
    private let queueOperationLock = NSLock()

    init(
        device: LiveAudioDevice,
        sampleRate: Int,
        channelCount: Int = 1,
        gain: Double = 1.0,
        maximumBufferedDuration: TimeInterval = 2.0
    ) {
        self.device = device
        self.sampleRate = max(1, sampleRate)
        self.channelCount = max(1, channelCount)
        self.bytesPerFrame = max(1, self.channelCount * MemoryLayout<Int16>.size)
        self.gain = Self.clampedGain(gain)
        self.maximumBufferedFrames = max(
            1,
            Int64(Double(self.sampleRate) * max(0.1, maximumBufferedDuration))
        )
    }

    deinit {
        stop()
    }

    func start() throws {
        stateLock.lock()
        if isRunning {
            stateLock.unlock()
            return
        }
        stateLock.unlock()

        var format = LivePCMInputStream.pcmFormat(sampleRate: sampleRate, channelCount: channelCount)
        var newQueue: AudioQueueRef?
        let userData = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        var status = AudioQueueNewOutput(&format, Self.outputCallback, userData, nil, nil, 0, &newQueue)
        try LivePCMInputStream.check(status, "AudioQueueNewOutput")
        guard let newQueue else {
            throw LiveAudioQueueError.coreAudio("AudioQueueNewOutput", -1)
        }
        var ownsNewQueue = true
        defer {
            if ownsNewQueue {
                AudioQueueDispose(newQueue, true)
            }
        }

        try LivePCMInputStream.setCurrentDevice(device, on: newQueue)
        status = AudioQueueSetParameter(newQueue, kAudioQueueParam_Volume, Float32(gain))
        try LivePCMInputStream.check(status, "AudioQueueSetParameter(volume)")

        stateLock.lock()
        queue = newQueue
        isRunning = true
        enqueuedFrames = 0
        playedFrames = 0
        playbackGeneration &+= 1
        bufferMetadata.removeAll()
        stateLock.unlock()
        ownsNewQueue = false

        do {
            status = AudioQueueStart(newQueue, nil)
            try LivePCMInputStream.check(status, "AudioQueueStart(output)")
        } catch {
            stop()
            throw error
        }
    }

    @discardableResult
    func enqueue(_ data: Data) -> Bool {
        guard !data.isEmpty,
              data.count.isMultiple(of: bytesPerFrame),
              data.count <= Int(UInt32.max)
        else {
            return false
        }

        let frameCount = Int64(data.count / bytesPerFrame)
        queueOperationLock.lock()
        defer { queueOperationLock.unlock() }

        stateLock.lock()
        let currentQueue = queue
        let shouldPlay = isRunning
        let generation = playbackGeneration
        let bufferedFrames = max(0, enqueuedFrames - playedFrames)
        let hasCapacity = bufferedFrames + frameCount <= maximumBufferedFrames
        stateLock.unlock()

        // Preserve already queued, contiguous speech and reject the newest
        // chunk when the latency/memory ceiling is reached.
        guard shouldPlay, hasCapacity, let currentQueue else {
            return false
        }

        var buffer: AudioQueueBufferRef?
        guard AudioQueueAllocateBuffer(currentQueue, UInt32(data.count), &buffer) == noErr,
              let buffer
        else {
            return false
        }

        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                return
            }
            memcpy(buffer.pointee.mAudioData, baseAddress, data.count)
        }
        buffer.pointee.mAudioDataByteSize = UInt32(data.count)

        let bufferID = Self.bufferID(buffer)
        stateLock.lock()
        guard isRunning,
              queue == currentQueue,
              playbackGeneration == generation
        else {
            stateLock.unlock()
            AudioQueueFreeBuffer(currentQueue, buffer)
            return false
        }

        bufferMetadata[bufferID] = BufferMetadata(
            generation: generation,
            frameCount: frameCount
        )
        let status = AudioQueueEnqueueBuffer(currentQueue, buffer, 0, nil)
        guard status == noErr else {
            bufferMetadata.removeValue(forKey: bufferID)
            stateLock.unlock()
            AudioQueueFreeBuffer(currentQueue, buffer)
            return false
        }

        enqueuedFrames += frameCount
        let progress = progressSnapshot()
        let callback = onPlaybackProgress
        stateLock.unlock()
        callback?(progress)
        return true
    }

    func setGain(_ gain: Double) {
        queueOperationLock.lock()
        defer { queueOperationLock.unlock() }

        let clamped = Self.clampedGain(gain)
        stateLock.lock()
        self.gain = clamped
        let currentQueue = queue
        stateLock.unlock()

        if let currentQueue {
            AudioQueueSetParameter(currentQueue, kAudioQueueParam_Volume, Float32(clamped))
        }
    }

    func reset() {
        queueOperationLock.lock()
        defer { queueOperationLock.unlock() }

        stateLock.lock()
        let currentQueue = queue
        playbackGeneration &+= 1
        enqueuedFrames = 0
        playedFrames = 0
        let progress = progressSnapshot()
        let callback = onPlaybackProgress
        stateLock.unlock()

        if let currentQueue {
            AudioQueueReset(currentQueue)
        }
        callback?(progress)
    }

    func stop() {
        queueOperationLock.lock()
        defer { queueOperationLock.unlock() }

        stateLock.lock()
        let currentQueue = queue
        queue = nil
        isRunning = false
        playbackGeneration &+= 1
        enqueuedFrames = 0
        playedFrames = 0
        stateLock.unlock()

        if let currentQueue {
            AudioQueueStop(currentQueue, true)
            AudioQueueDispose(currentQueue, true)
        }

        stateLock.lock()
        bufferMetadata.removeAll()
        stateLock.unlock()
    }

    private func handleOutputBuffer(_ queue: AudioQueueRef, buffer: AudioQueueBufferRef) {
        let bufferID = Self.bufferID(buffer)
        stateLock.lock()
        let metadata = bufferMetadata.removeValue(forKey: bufferID)
        let isCurrentBuffer = isRunning
            && metadata?.generation == playbackGeneration
        if let metadata, isCurrentBuffer {
            playedFrames += metadata.frameCount
        }
        let progress = isCurrentBuffer ? progressSnapshot() : nil
        let callback = isCurrentBuffer ? onPlaybackProgress : nil
        stateLock.unlock()

        AudioQueueFreeBuffer(queue, buffer)
        if let progress {
            callback?(progress)
        }
    }

    private func progressSnapshot() -> LiveAudioPlaybackProgress {
        LiveAudioPlaybackProgress(
            playedFrames: playedFrames,
            enqueuedFrames: enqueuedFrames,
            sampleRate: sampleRate
        )
    }

    private static let outputCallback: AudioQueueOutputCallback = { userData, queue, buffer in
        guard let userData else {
            AudioQueueFreeBuffer(queue, buffer)
            return
        }
        let output = Unmanaged<LivePCMOutputQueue>.fromOpaque(userData).takeUnretainedValue()
        output.handleOutputBuffer(queue, buffer: buffer)
    }

    private static func clampedGain(_ gain: Double) -> Double {
        min(1.0, max(0.0, gain))
    }

    private static func bufferID(_ buffer: AudioQueueBufferRef) -> UInt {
        UInt(bitPattern: UnsafeRawPointer(buffer))
    }
}

final class LiveBypassAudioStream {
    private let input: LivePCMInputStream
    private let output: LivePCMOutputQueue

    init(
        inputDevice: LiveAudioDevice,
        outputDevice: LiveAudioDevice,
        gain: Double = 1.0
    ) {
        let sampleRate = max(8_000, inputDevice.sampleRate)
        let output = LivePCMOutputQueue(
            device: outputDevice,
            sampleRate: sampleRate,
            channelCount: 1,
            gain: gain,
            maximumBufferedDuration: 0.5
        )
        self.output = output
        self.input = LivePCMInputStream(
            device: inputDevice,
            sampleRate: sampleRate,
            channelCount: 1,
            chunkMilliseconds: 20
        ) { data in
            _ = output.enqueue(data)
        }
    }

    func start() throws {
        try output.start()
        try input.start()
    }

    func setGain(_ gain: Double) {
        output.setGain(gain)
    }

    func stop() {
        input.stop()
        output.stop()
    }
}
