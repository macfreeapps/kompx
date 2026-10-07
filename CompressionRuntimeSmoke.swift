import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AVFoundation
import Darwin

@main
@MainActor
struct CompressionRuntimeSmoke {
    struct CheckFailure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    static func main() async {
        let watchdog = Task.detached {
            try? await Task.sleep(nanoseconds: 90_000_000_000)
            if !Task.isCancelled {
                fputs("FAIL: smoke test timed out\n", stderr)
                exit(1)
            }
        }
        defer { watchdog.cancel() }
        do {
            guard CommandLine.arguments.count == 2 else { throw CheckFailure("Pass the fixture directory") }
            try await run(at: URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true))
            print("PASS: all runtime checks")
        } catch {
            fputs("FAIL: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw CheckFailure(message) }
        print("PASS:", message)
    }

    static func images(_ urls: [URL], output: URL? = nil, format: ImageOutputFormatChoice = .automatic) async -> [CompressionItemResult] {
        let compressor = ImageCompressor()
        return await withCheckedContinuation { continuation in
            compressor.compressImages(inputURLs: urls, quality: .balanced, outputDirectory: output,
                                      addCompressedSuffix: true, outputFormatPreference: format, completion: {
                continuation.resume(returning: $0)
            })
        }
    }

    static func videos(_ urls: [URL], output: URL? = nil) async -> [CompressionItemResult] {
        let compressor = VideoCompressor()
        return await withCheckedContinuation { continuation in
            compressor.compressVideos(inputURLs: urls, quality: .balanced, outputDirectory: output,
                                      addCompressedSuffix: true, completion: {
                continuation.resume(returning: $0)
            })
        }
    }

    static func run(at root: URL) async throws {
        let fm = FileManager.default
        let jpeg = root.appendingPathComponent("photo.jpg")
        try makeImage(at: jpeg, width: 3600, height: 2400, type: UTType.jpeg, orientation: 6)
        let originalImage = try Data(contentsOf: jpeg)
        let imageResult = await images([jpeg])
        try require(imageResult.count == 1 && imageResult[0].outcome == .compressed, "JPEG compression saves a smaller copy")
        try require(try Data(contentsOf: jpeg) == originalImage, "JPEG original remains byte-identical")
        let jpegOutput = imageResult[0].outputURL!
        let source = CGImageSourceCreateWithURL(jpegOutput as CFURL, nil)!
        let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        try require(decoded.width == 1280 && decoded.height == 1920, "Image orientation and scaled dimensions are correct")

        let secondImage = await images([jpeg], format: .heic)
        try require(secondImage.first?.outcome == .compressed && secondImage.first?.outputURL?.pathExtension == "heic", "HEIC conversion succeeds")
        let collision = await images([jpeg])
        try require(collision.first?.outcome == .compressed && collision.first?.outputURL != jpegOutput,
                    "Existing compressed copies are not overwritten")
        try require(fm.fileExists(atPath: jpegOutput.path), "Previous output remains available")

        let tinyPNG = root.appendingPathComponent("tiny.png")
        try makeImage(at: tinyPNG, width: 1, height: 1, type: UTType.png)
        let tinyBefore = try Data(contentsOf: tinyPNG)
        let unchanged = await images([tinyPNG])
        try require(unchanged.first?.outcome == .unchanged && unchanged.first?.outputURL == nil,
                    "Larger image output is discarded")
        try require(try Data(contentsOf: tinyPNG) == tinyBefore, "No-savings original remains byte-identical")

        let corrupt = root.appendingPathComponent("corrupt.jpg")
        try Data("invalid image".utf8).write(to: corrupt)
        let mixed = await images([corrupt, jpeg])
        try require(mixed.first(where: { $0.id == corrupt })?.outcome == .failed
                    && mixed.first(where: { $0.id == jpeg })?.outcome == .compressed,
                    "Invalid image does not prevent a valid image from saving")

        let multipage = root.appendingPathComponent("multipage.tiff")
        try makeImage(at: multipage, width: 64, height: 64, type: UTType.tiff, pages: 2)
        let multiBefore = try Data(contentsOf: multipage)
        let multiResult = await images([multipage])
        try require(multiResult.first?.outcome == .failed && (try Data(contentsOf: multipage)) == multiBefore,
                    "Multi-page images are rejected without changing the source")

        let video = root.appendingPathComponent("video.mp4")
        let videoBefore = try Data(contentsOf: video)
        let videoResult = await videos([video])
        try require(videoResult.count == 1 && videoResult[0].outcome == .compressed,
                    "Video with audio saves a smaller copy")
        try require(try Data(contentsOf: video) == videoBefore, "Video original remains byte-identical")
        let asset = AVURLAsset(url: videoResult[0].outputURL!)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let duration = try await asset.load(.duration).seconds
        let naturalSize = try await videoTracks[0].load(.naturalSize)
        try require(audioTracks.count == 1 && videoTracks.count == 1 && abs(duration - 4) < 0.5,
                    "Video duration and audio track are preserved")
        try require(naturalSize.width == 1920 && naturalSize.height == 1080, "Video dimensions are correct")

        let silent = root.appendingPathComponent("silent.mp4")
        let silentResult = await videos([silent])
        try require(silentResult.first?.outcome == .compressed, "Silent video compression succeeds")
        let rotated = root.appendingPathComponent("rotated.mov")
        let rotatedResult = await videos([rotated])
        try require(rotatedResult.first?.outcome == .compressed, "Rotated MOV compression succeeds")
        let rotatedAsset = AVURLAsset(url: rotatedResult[0].outputURL!)
        let rotatedTrack = try await rotatedAsset.loadTracks(withMediaType: .video)[0]
        let rotatedSize = try await rotatedTrack.load(.naturalSize)
        try require(rotatedSize.width == 1080 && rotatedSize.height == 1920, "Portrait video orientation is preserved")

        let multitrack = root.appendingPathComponent("multitrack.mp4")
        let multitrackBefore = try Data(contentsOf: multitrack)
        let multiVideo = await videos([multitrack, video])
        try require(multiVideo.first(where: { $0.id == multitrack })?.outcome == .failed
                    && multiVideo.first(where: { $0.id == video })?.outcome == .compressed,
                    "Extra audio tracks are rejected while valid video still saves")
        try require(try Data(contentsOf: multitrack) == multitrackBefore, "Multitrack original remains byte-identical")

        let output = root.appendingPathComponent("custom", isDirectory: true)
        try fm.createDirectory(at: output, withIntermediateDirectories: true)
        let customImage = await images([jpeg], output: output)
        let customVideo = await videos([video], output: output)
        try require(customImage.first?.outputURL?.deletingLastPathComponent() == output
                    && customVideo.first?.outputURL?.deletingLastPathComponent() == output,
                    "Custom output directory works for images and videos")

        let cancelled = VideoCompressor()
        let cancelledResults: [CompressionItemResult] = await withCheckedContinuation { continuation in
            cancelled.compressVideos(inputURLs: [video], quality: .high, addCompressedSuffix: true, completion: {
                continuation.resume(returning: $0)
            })
            cancelled.cancelCompression()
        }
        try require(cancelledResults.isEmpty && cancelled.statusMessage.contains("Cancelled"), "Video cancellation completes safely")
        try require(try Data(contentsOf: video) == videoBefore, "Cancelled video remains byte-identical")

        let cancelledImage = ImageCompressor()
        let cancelledImages: [CompressionItemResult] = await withCheckedContinuation { continuation in
            cancelledImage.compressImages(inputURLs: [jpeg], quality: .high, addCompressedSuffix: true, completion: {
                continuation.resume(returning: $0)
            })
            cancelledImage.cancelCompression()
        }
        try require(cancelledImages.isEmpty && (try Data(contentsOf: jpeg)) == originalImage,
                    "Image cancellation keeps the original")
        let leftovers = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(".komPX-staging-") }
        try require(leftovers.isEmpty, "Temporary staging directories are cleaned up")
    }

    static func makeImage(at url: URL, width: Int, height: Int, type: UTType,
                          orientation: Int = 1, pages: Int = 1) throws {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw CheckFailure("Could not create image fixture")
        }
        for y in stride(from: 0, to: height, by: 12) {
            let value = CGFloat(y) / CGFloat(height)
            context.setFillColor(red: value, green: 0.35, blue: 1 - value, alpha: 1)
            context.fill(CGRect(x: 0, y: y, width: width, height: 12))
        }
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, pages, nil) else {
            throw CheckFailure("Could not write image fixture")
        }
        for _ in 0..<pages {
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 1.0,
                                                           kCGImagePropertyOrientation: orientation] as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { throw CheckFailure("Could not finish image fixture") }
    }
}
