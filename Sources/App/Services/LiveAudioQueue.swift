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
        let shouldContinue = isRunning
        stateLock.unlock()

        guard shouldContinue else {
            return
        }

        let byteSize = Int(buffer.pointee.mAudioDataByteSize)
        if byteSize > 0 {
            let data = Data(bytes: buffer.pointee.mAudioData, count: byteSize)
            onAudio(data)
        }

        AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
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
    private let device: LiveAudioDevice
    private let sampleRate: Int
    private let channelCount: Int
    private let bytesPerFrame: Int
    var onPlaybackProgress: ((LiveAudioPlaybackProgress) -> Void)?
    private var queue: AudioQueueRef?
    private var isRunning = false
    private var gain: Double
    private var enqueuedFrames: Int64 = 0
    private var playedFrames: Int64 = 0
    private let stateLock = NSLock()

    init(device: LiveAudioDevice, sampleRate: Int, channelCount: Int = 1, gain: Double = 1.0) {
        self.device = device
        self.sampleRate = sampleRate
        self.channelCount = max(1, channelCount)
        self.bytesPerFrame = max(1, self.channelCount * MemoryLayout<Int16>.size)
        self.gain = Self.clampedGain(gain)
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

        try LivePCMInputStream.setCurrentDevice(device, on: newQueue)
        status = AudioQueueSetParameter(newQueue, kAudioQueueParam_Volume, Float32(gain))
        try LivePCMInputStream.check(status, "AudioQueueSetParameter(volume)")

        stateLock.lock()
        queue = newQueue
        isRunning = true
        enqueuedFrames = 0
        playedFrames = 0
        stateLock.unlock()

        do {
            status = AudioQueueStart(newQueue, nil)
            try LivePCMInputStream.check(status, "AudioQueueStart(output)")
        } catch {
            stop()
            throw error
        }
    }

    func enqueue(_ data: Data) {
        guard !data.isEmpty else {
            return
        }

        stateLock.lock()
        let currentQueue = queue
        let shouldPlay = isRunning
        stateLock.unlock()

        guard shouldPlay, let currentQueue else {
            return
        }

        var buffer: AudioQueueBufferRef?
        guard AudioQueueAllocateBuffer(currentQueue, UInt32(data.count), &buffer) == noErr,
              let buffer
        else {
            return
        }

        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                return
            }
            memcpy(buffer.pointee.mAudioData, baseAddress, data.count)
        }
        buffer.pointee.mAudioDataByteSize = UInt32(data.count)
        let status = AudioQueueEnqueueBuffer(currentQueue, buffer, 0, nil)
        guard status == noErr else {
            AudioQueueFreeBuffer(currentQueue, buffer)
            return
        }

        let frameCount = Int64(data.count / bytesPerFrame)
        stateLock.lock()
        enqueuedFrames += frameCount
        let progress = progressSnapshot()
        let callback = onPlaybackProgress
        stateLock.unlock()
        callback?(progress)
    }

    func setGain(_ gain: Double) {
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
        stateLock.lock()
        let currentQueue = queue
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
        stateLock.lock()
        let currentQueue = queue
        queue = nil
        isRunning = false
        enqueuedFrames = 0
        playedFrames = 0
        stateLock.unlock()

        if let currentQueue {
            AudioQueueStop(currentQueue, true)
            AudioQueueDispose(currentQueue, true)
        }
    }

    private func handleOutputBuffer(_ queue: AudioQueueRef, buffer: AudioQueueBufferRef) {
        let byteSize = Int(buffer.pointee.mAudioDataByteSize)
        let frameCount = Int64(byteSize / bytesPerFrame)

        stateLock.lock()
        playedFrames += frameCount
        let progress = progressSnapshot()
        let callback = onPlaybackProgress
        stateLock.unlock()

        AudioQueueFreeBuffer(queue, buffer)
        callback?(progress)
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
        let output = LivePCMOutputQueue(device: outputDevice, sampleRate: sampleRate, channelCount: 1, gain: gain)
        self.output = output
        self.input = LivePCMInputStream(device: inputDevice, sampleRate: sampleRate, channelCount: 1) { data in
            output.enqueue(data)
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
