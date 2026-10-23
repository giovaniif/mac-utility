import AVFoundation
import ScreenCaptureKit
import os

/// Records a ScreenCaptureKit stream to an H.264 .mp4, with optional
/// microphone audio from AVCapture. Both sample callbacks and all writer calls
/// run on one serial queue, which is what makes the `@unchecked Sendable` safe.
final class ScreenRecording: NSObject, SCStreamOutput, SCStreamDelegate, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    let url: URL

    private let log = Logger(subsystem: "com.giovani.MacUtility", category: "capture")
    private let queue = DispatchQueue(label: "com.giovani.MacUtility.recording")
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput?
    private let stream: SCStream
    private let micSession: AVCaptureSession?
    private var startTime: CMTime?

    // Pausing drops samples and shifts later ones back by the paused time,
    // so the file plays straight through. Screen and mic timestamps are both
    // on the host clock, which is what the pause bookkeeping uses too.
    private var pausedAt: CMTime?
    private var resumedAt = CMTime.zero
    private var pausedTotal = CMTime.zero

    init(content: CaptureContent, microphone: Bool, url: URL) throws {
        self.url = url
        // H.264 needs even dimensions.
        let width = content.pixelWidth & ~1
        let height = content.pixelHeight & ~1

        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        if let sourceRect = content.sourceRect { config.sourceRect = sourceRect }
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = true
        config.queueDepth = 6

        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(width * height * 6, 2_000_000),
                AVVideoExpectedSourceFrameRateKey: 60,
            ],
        ])
        videoInput.expectsMediaDataInRealTime = true
        writer.add(videoInput)

        if microphone, let device = AVCaptureDevice.default(for: .audio) {
            let session = AVCaptureSession()
            let input = try AVCaptureDeviceInput(device: device)
            let output = AVCaptureAudioDataOutput()
            if session.canAddInput(input) { session.addInput(input) }
            if session.canAddOutput(output) { session.addOutput(output) }
            let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 128_000,
            ])
            audio.expectsMediaDataInRealTime = true
            writer.add(audio)
            micSession = session
            audioInput = audio
            stream = SCStream(filter: content.filter, configuration: config, delegate: nil)
            super.init()
            output.setSampleBufferDelegate(self, queue: queue)
        } else {
            micSession = nil
            audioInput = nil
            stream = SCStream(filter: content.filter, configuration: config, delegate: nil)
            super.init()
        }
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
    }

    func start() async throws {
        guard writer.startWriting() else { throw writer.error ?? CaptureError.nothingCaptured }
        micSession?.startRunning()
        try await stream.startCapture()
    }

    func pause() {
        queue.async { [self] in
            guard pausedAt == nil else { return }
            pausedAt = CMClockGetTime(CMClockGetHostTimeClock())
        }
    }

    func resume() {
        queue.async { [self] in
            guard let pausedAt else { return }
            let now = CMClockGetTime(CMClockGetHostTimeClock())
            pausedTotal = pausedTotal + (now - pausedAt)
            resumedAt = now
            self.pausedAt = nil
        }
    }

    /// Whether a sample captured at `time` belongs in the file: not while
    /// paused, and not one captured during a pause but delivered after it.
    private func keeps(_ time: CMTime) -> Bool {
        if let pausedAt { return time < pausedAt }
        return time >= resumedAt
    }

    private func shifted(_ sampleBuffer: CMSampleBuffer) -> CMSampleBuffer? {
        guard pausedTotal != .zero else { return sampleBuffer }
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: count, arrayToFill: &timing, entriesNeededOut: &count)
        for index in timing.indices {
            timing[index].presentationTimeStamp = timing[index].presentationTimeStamp - pausedTotal
            if timing[index].decodeTimeStamp.isValid {
                timing[index].decodeTimeStamp = timing[index].decodeTimeStamp - pausedTotal
            }
        }
        var copy: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sampleBuffer, sampleTimingEntryCount: count, sampleTimingArray: &timing, sampleBufferOut: &copy)
        return copy
    }

    /// Stops capturing and finishes the file. Returns false if nothing usable
    /// was written.
    func stop() async -> Bool {
        try? await stream.stopCapture()
        micSession?.stopRunning()
        return await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard startTime != nil else {
                    writer.cancelWriting()
                    continuation.resume(returning: false)
                    return
                }
                videoInput.markAsFinished()
                audioInput?.markAsFinished()
                writer.finishWriting { [self] in
                    if writer.status != .completed {
                        log.error("recording failed: \(self.writer.error?.localizedDescription ?? "unknown")")
                    }
                    continuation.resume(returning: writer.status == .completed)
                }
            }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid, Self.isCompleteFrame(sampleBuffer) else { return }
        guard writer.status == .writing, keeps(sampleBuffer.presentationTimeStamp),
              let sampleBuffer = shifted(sampleBuffer)
        else { return }
        if startTime == nil {
            let time = sampleBuffer.presentationTimeStamp
            writer.startSession(atSourceTime: time)
            startTime = time
        }
        if videoInput.isReadyForMoreMediaData {
            videoInput.append(sampleBuffer)
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let audioInput, let startTime, writer.status == .writing,
              keeps(sampleBuffer.presentationTimeStamp),
              let sampleBuffer = shifted(sampleBuffer),
              sampleBuffer.presentationTimeStamp >= startTime,
              audioInput.isReadyForMoreMediaData
        else { return }
        audioInput.append(sampleBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        log.error("stream stopped: \(error.localizedDescription)")
    }

    private static func isCompleteFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw)
        else { return false }
        return status == .complete
    }
}
