import Darwin
import Foundation

// Keep the legacy automatic value only so older recording manifests remain readable.
public enum RecordingOwner: String, Codable, Sendable { case manual, automatic }

public enum AudioSide: String, Codable, CaseIterable, Sendable {
    case caller
    case agent = "chrome"
}
public struct AudioGap: Codable, Equatable, Sendable {
    public let side: AudioSide
    public let startFrame: Int64
    public let frames: Int64
    public let reason: String
    public init(side: AudioSide, startFrame: Int64, frames: Int64, reason: String) {
        self.side = side
        self.startFrame = startFrame
        self.frames = frames
        self.reason = reason
    }
}
public struct RecordingSegment: Codable, Equatable, Sendable {
    public let side: AudioSide
    public let filename: String
    public let startFrame: Int64
    public let frames: Int64
    public init(side: AudioSide, filename: String, startFrame: Int64, frames: Int64) {
        self.side = side
        self.filename = filename
        self.startFrame = startFrame
        self.frames = frames
    }
}
public enum RecordingStatus: String, Codable, Sendable {
    case recording, finalizing, complete, recoverable, failed
}
public enum RecordingManifestError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedVersion, invalidSampleRate, invalidTimeline, invalidSegment, invalidFile

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion: "This recording file version is not supported."
        case .invalidSampleRate: "The recording sample rate is invalid."
        case .invalidTimeline: "The recording timing information is damaged."
        case .invalidSegment: "The recording source path or segment is damaged."
        case .invalidFile: "The recording metadata is not a supported file."
        }
    }
}

public struct RecordingManifest: Codable, Equatable, Identifiable, Sendable {
    public var version = 1
    public var id: UUID
    public var title: String
    public var createdAt: Date
    public var durationFrames: Int64 = 0
    public var sampleRate: Double = 48_000
    public var status: RecordingStatus = .recording
    public var segments: [RecordingSegment] = []
    public var gaps: [AudioGap] = []
    public var failure: String?
    public var failureCode: String?
    public var owner: RecordingOwner
    public var duration: TimeInterval {
        guard sampleRate.isFinite, sampleRate > 0, durationFrames >= 0 else { return 0 }
        return Double(durationFrames) / sampleRate
    }

    public init(id: UUID = UUID(), title: String, createdAt: Date = .now, owner: RecordingOwner) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.owner = owner
    }
    public func save(to directory: URL) throws {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(
            to: directory.appendingPathComponent("manifest.json"), options: .atomic)
    }
    public static func load(from directory: URL) throws -> Self {
        guard directory.isFileURL, !directory.path.contains("\0") else {
            throw RecordingManifestError.invalidFile
        }
        let folder = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard folder >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(folder) }
        let input = openat(folder, "manifest.json", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard input >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(input) }
        var attributes = stat()
        guard fstat(input, &attributes) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard attributes.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
            attributes.st_size > 0, attributes.st_size <= 16 * 1024 * 1024
        else { throw RecordingManifestError.invalidFile }
        var data = Data(count: Int(attributes.st_size))
        try data.withUnsafeMutableBytes { bytes in
            guard let base = bytes.baseAddress else { throw RecordingManifestError.invalidFile }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.read(input, base.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw RecordingManifestError.invalidFile }
                offset += count
            }
        }
        // Reject growth or truncation while reading the opened file, before decoding.
        var current = stat()
        guard fstat(input, &current) == 0, current.st_size == attributes.st_size else {
            throw RecordingManifestError.invalidFile
        }
        let manifest = try JSONDecoder().decode(Self.self, from: data)
        try manifest.validate()
        return manifest
    }

    /// Validate persisted input before it reaches file readers, arithmetic, or the UI.
    public func validate() throws {
        guard version == 1 else { throw RecordingManifestError.unsupportedVersion }
        guard sampleRate == 48_000 else { throw RecordingManifestError.invalidSampleRate }
        guard durationFrames >= 0, createdAt.timeIntervalSinceReferenceDate.isFinite else {
            throw RecordingManifestError.invalidTimeline
        }
        var filenames = Set<String>()
        for segment in segments {
            guard segment.filename == URL(fileURLWithPath: segment.filename).lastPathComponent,
                segment.filename.hasSuffix(".caf"),
                filenames.insert(segment.filename).inserted
            else { throw RecordingManifestError.invalidSegment }
            try validateRange(start: segment.startFrame, frames: segment.frames)
        }
        for gap in gaps { try validateRange(start: gap.startFrame, frames: gap.frames) }
    }

    private func validateRange(start: Int64, frames: Int64) throws {
        let (end, overflow) = start.addingReportingOverflow(frames)
        guard start >= 0, frames > 0, !overflow, end <= durationFrames else {
            throw RecordingManifestError.invalidTimeline
        }
    }
}
