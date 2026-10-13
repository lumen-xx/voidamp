import AppKit
import AVFoundation
import ScreenCaptureKit
import VideoToolbox
// Records one window (the demo Suite) onto Voidamp's night-sky background with a headline, as a 1920×1080 H.264 video.
// Only that window is captured: no desktop, other windows or pointer. Sends SIGUSR1 to <pid> when recording starts,
// which starts the demo's timeline (`--demo-play`).
// While a window is recorded, macOS draws a sharing badge over its window buttons; [patch.png], a screenshot of the
// window taken just before (`screencapture -o -l`), covers that unchanging corner again.
// Usage: swift scripts/demo-video.swift <pid> <window number> <seconds> <out.mp4> <headline> <subtitle> <icon.png> [patch.png]
let arguments = CommandLine.arguments
let pid = pid_t(arguments[1])!, windowNumber = CGWindowID(arguments[2])!, seconds = Double(arguments[3])!
let output = URL(fileURLWithPath: arguments[4])
let headline = arguments[5], subtitle = arguments[6]
let icon = NSImage(contentsOf: URL(fileURLWithPath: arguments[7]))
let patch: CGImage? = arguments.count > 8 ? NSImage(contentsOf: URL(fileURLWithPath: arguments[8]))?.cgImage(forProposedRect: nil, context: nil, hints: nil)?
    .cropping(to: CGRect(x: 0, y: 0, width: 110, height: 52)) : nil
let width = 1920, height = 1080, fps: Int32 = 30

// MARK: Background

func background() -> CGImage {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let w = CGFloat(width), h = CGFloat(height)
    NSGradient(colors: [NSColor(calibratedRed: 0.09, green: 0.16, blue: 0.36, alpha: 1), NSColor(calibratedRed: 0.01, green: 0.02, blue: 0.07, alpha: 1)])!
        .draw(in: NSRect(x: 0, y: 0, width: w, height: h), angle: -70)
    NSGradient(colors: [NSColor(calibratedRed: 0.35, green: 0.55, blue: 1, alpha: 0.18), .clear])!
        .draw(fromCenter: NSPoint(x: w / 2, y: h * 0.42), radius: 0, toCenter: NSPoint(x: w / 2, y: h * 0.42), radius: w * 0.55, options: [])
    var seed: UInt64 = 7
    func next() -> CGFloat { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return CGFloat(seed >> 33) / CGFloat(UInt64(1) << 31) }
    for _ in 0..<Int(w * h / 2600) {
        let size = 0.6 + next() * 1.6
        NSColor.white.withAlphaComponent(0.15 + next() * 0.55).setFill()
        NSBezierPath(ovalIn: NSRect(x: next() * w, y: next() * h, width: size, height: size)).fill()
    }
    let center = NSMutableParagraphStyle()
    center.alignment = .center
    let title = NSAttributedString(string: headline, attributes: [.font: NSFont.systemFont(ofSize: 50, weight: .bold), .foregroundColor: NSColor.white])
    let titleSize = title.size()
    let iconSide: CGFloat = 56, gap: CGFloat = 16
    let lineX = (w - titleSize.width - (icon == nil ? 0 : iconSide + gap)) / 2, titleY = h - 22 - titleSize.height
    icon?.draw(in: NSRect(x: lineX, y: titleY + (titleSize.height - iconSide) / 2 - 2, width: iconSide, height: iconSide))
    title.draw(at: NSPoint(x: lineX + (icon == nil ? 0 : iconSide + gap), y: titleY))
    NSAttributedString(string: subtitle, attributes: [.font: NSFont.systemFont(ofSize: 26, weight: .regular),
                                                      .foregroundColor: NSColor.white.withAlphaComponent(0.72), .paragraphStyle: center])
        .draw(in: NSRect(x: 60, y: titleY - 44, width: w - 120, height: 36))
    NSGraphicsContext.restoreGraphicsState()
    return rep.cgImage!
}

// MARK: Capture and encode

final class Recorder: NSObject, SCStreamOutput, @unchecked Sendable {
    private let lock = NSLock()
    private var latest: CGImage?
    private var started = false
    private let backdrop = background()
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let queue = DispatchQueue(label: "frames")
    private var timer: DispatchSourceTimer?
    private var frame: Int64 = 0
    private let total: Int64
    let done = DispatchSemaphore(value: 0)

    override init() {
        try? FileManager.default.removeItem(at: output)
        writer = try! AVAssetWriter(outputURL: output, fileType: .mp4)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 14_000_000, AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel],
        ])
        input.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        total = Int64(seconds * Double(fps))
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let pixels = buffer.imageBuffer else { return }
        // Frames whose content didn't change carry no image.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let status = attachments.first?[.status] as? Int, status != SCFrameStatus.complete.rawValue { return }
        var image: CGImage?
        VTCreateCGImageFromCVPixelBuffer(pixels, options: nil, imageOut: &image)
        guard let image else { return }
        lock.withLock { latest = image }
        let first = lock.withLock { () -> Bool in defer { started = true }; return !started }
        if first { begin() }
    }

    /// Starts the demo's timeline and writes a frame every 1/30 s from the latest capture, so the video has an even
    /// frame rate although the window only sends frames when something changes.
    private func begin() {
        kill(pid, SIGUSR1)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1.0 / Double(fps))
        timer.setEventHandler { [self] in writeFrame() }
        timer.resume()
        self.timer = timer
    }

    private func writeFrame() {
        guard frame < total else {
            timer?.cancel()
            input.markAsFinished()
            writer.finishWriting { self.done.signal() }
            return
        }
        guard input.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool, let window = lock.withLock({ latest }) else { return }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let buffer else { return }
        CVPixelBufferLockBaseAddress(buffer, [])
        let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        context.draw(backdrop, in: CGRect(x: 0, y: 0, width: width, height: height))
        let rect = CGRect(x: (width - window.width) / 2, y: 26, width: window.width, height: window.height)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -12), blur: 40, color: CGColor(gray: 0, alpha: 0.6))
        context.draw(window, in: rect)
        context.restoreGState()
        if let patch { context.draw(patch, in: CGRect(x: rect.minX, y: rect.maxY - CGFloat(patch.height), width: CGFloat(patch.width), height: CGFloat(patch.height))) }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        adaptor.append(buffer, withPresentationTime: CMTime(value: frame, timescale: fps))
        frame += 1
    }
}

let recorder = Recorder()
Task {
    let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
    guard let window = content.windows.first(where: { $0.windowID == windowNumber }) else { print("No window \(windowNumber)"); exit(1) }
    let configuration = SCStreamConfiguration()
    configuration.width = Int(window.frame.width)
    configuration.height = Int(window.frame.height)
    configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
    configuration.pixelFormat = kCVPixelFormatType_32BGRA
    configuration.showsCursor = false
    let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: window), configuration: configuration, delegate: nil)
    try stream.addStreamOutput(recorder, type: .screen, sampleHandlerQueue: DispatchQueue(label: "capture"))
    try await stream.startCapture()
    await withCheckedContinuation { continuation in DispatchQueue.global().async { recorder.done.wait(); continuation.resume() } }
    try await stream.stopCapture()
    print("Wrote \(output.path)")
    exit(0)
}
RunLoop.main.run()
