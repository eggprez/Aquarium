//  The seams an interrupted transcode leaves in a download, read back out of
//  fragmented MP4, and the tally that decides when the player re-anchors.

import XCTest
@testable import Aquarium

final class StreamSeamsTests: XCTestCase {
    // MARK: Building a package

    private func box(_ type: String, _ body: [UInt8]) -> [UInt8] {
        be32(UInt32(body.count + 8)) + Array(type.utf8) + body
    }
    private func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
    private func be64(_ v: Int64) -> [UInt8] {
        let u = UInt64(bitPattern: v)
        return be32(UInt32(u >> 32)) + be32(UInt32(u & 0xFFFF_FFFF))
    }

    private func track(id: UInt32, handler: String, timescale: UInt32) -> [UInt8] {
        box("trak",
            box("tkhd", be32(0) + be32(0) + be32(0) + be32(id) + [UInt8](repeating: 0, count: 60))
            + box("mdia",
                  box("mdhd", be32(0) + be32(0) + be32(0) + be32(timescale) + be32(0) + be32(0))
                  + box("hdlr", be32(0) + be32(0) + Array(handler.utf8) + [UInt8](repeating: 0, count: 13))))
    }

    /// Video on track 1, 48 kHz sound on track 2, as the server writes it.
    private var initSegment: [UInt8] {
        box("ftyp", Array("iso5".utf8) + be32(0))
        + box("moov",
              track(id: 1, handler: "vide", timescale: 16000)
              + track(id: 2, handler: "soun", timescale: 48000)
              + box("mvex", box("trex", be32(0) + be32(1) + be32(1) + be32(0) + be32(0) + be32(0))
                          + box("trex", be32(0) + be32(2) + be32(1) + be32(0) + be32(0) + be32(0))))
    }

    /// A segment whose audio starts at `start` (in 1/48000 s) and runs for
    /// `frames` AAC frames, behind a video fragment and some media to skip.
    private func segment(audioStart start: Int64, frames: UInt32) -> [UInt8] {
        let video = box("traf",
                        box("tfhd", be32(0x02_0000) + be32(1))
                        + box("tfdt", be32(0x0100_0000) + be64(0))
                        + box("trun", be32(0x100) + be32(1) + be32(48048)))
        // Per-sample durations, each beside a size, the way ffmpeg writes them.
        var samples: [UInt8] = []
        for _ in 0..<frames { samples += be32(1024) + be32(300) }
        let audio = box("traf",
                        box("tfhd", be32(0x02_0000) + be32(2))
                        + box("tfdt", be32(0x0100_0000) + be64(start))
                        + box("trun", be32(0x301) + be32(frames) + be32(0) + samples))
        return box("moof", box("mfhd", be32(0) + be32(1)) + video + audio)
            + box("mdat", [UInt8](repeating: 7, count: 4096))
    }

    private func package(_ segments: [[UInt8]]) throws -> URL {
        let package = FileManager.default.temporaryDirectory
            .appendingPathComponent("seams-\(UUID().uuidString).movpkg")
        let stream = package.appendingPathComponent("0-4000000-ABC")
        try FileManager.default.createDirectory(at: stream, withIntermediateDirectories: true)
        try Data(initSegment).write(to: stream.appendingPathComponent("(ABC)_(0).initfrag"))
        for (n, bytes) in segments.enumerated() {
            try Data(bytes).write(to: stream.appendingPathComponent("(\(n * 3))_(0)_(3.003).frag"))
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: package) }
        return package
    }

    // MARK: Reading it

    func testInitSegmentNamesTheSoundTrack() {
        XCTAssertEqual(StreamSeams.audioTrack(inInitSegment: Data(initSegment)),
                       StreamSeams.AudioTrack(id: 2, timescale: 48000, defaultDuration: 0))
        XCTAssertNil(StreamSeams.audioTrack(inInitSegment: Data([0, 1, 2, 3])))
    }

    func testFragmentNamesSortByTheirStart() throws {
        XCTAssertEqual(StreamSeams.startTime(ofFragmentNamed: "(126.793)_(0)_(7.92501).frag"), 126.793)
        XCTAssertNil(StreamSeams.startTime(ofFragmentNamed: "StreamInfoBoot.xml"))
        // 0, 3, … 30: by number, where a sort by name would put 12 before 3.
        let made = try package((0..<11).map { segment(audioStart: Int64($0) * 144_000, frames: 1) })
        let files = StreamSeams.fragmentFiles(in: made)
        XCTAssertEqual(files.segments.map(\.lastPathComponent).prefix(3),
                       ["(0)_(0)_(3.003).frag", "(3)_(0)_(3.003).frag", "(6)_(0)_(3.003).frag"])
        XCTAssertEqual(files.segments.last?.lastPathComponent, "(30)_(0)_(3.003).frag")
    }

    func testOneEncodeHasNoSeams() throws {
        // Starts a priming's length before zero, as the server's does, and
        // every segment picks up on the sample the last one ended at.
        let made = try package([
            segment(audioStart: -2112, frames: 143),
            segment(audioStart: -2112 + 143 * 1024, frames: 141),
            segment(audioStart: -2112 + 284 * 1024, frames: 141),
        ])
        XCTAssertEqual(StreamSeams.scan(StreamSeams.fragmentFiles(in: made)), [])
    }

    func testRestartedEncodeOverlapsWhereItRestarted() throws {
        // The third segment comes from a new encoder: its audio starts at
        // 5.956 s where the second's ended at 6.0147 s.
        let end = Int64(-2112 + 284 * 1024)
        let made = try package([
            segment(audioStart: -2112, frames: 143),
            segment(audioStart: -2112 + 143 * 1024, frames: 141),
            segment(audioStart: 285_888, frames: 144),
            segment(audioStart: 285_888 + 144 * 1024, frames: 141),
        ])
        let seams = try XCTUnwrap(StreamSeams.scan(StreamSeams.fragmentFiles(in: made)))
        XCTAssertEqual(seams.count, 1)
        XCTAssertEqual(seams[0].time, Double(end) / 48000, accuracy: 0.0001)
        XCTAssertEqual(seams[0].overlap, Double(end - 285_888) / 48000, accuracy: 0.0001)
    }

    func testAHoleIsNotASeam() throws {
        let made = try package([
            segment(audioStart: 0, frames: 141),
            segment(audioStart: 480_000, frames: 141),
            segment(audioStart: 0, frames: 141),
        ])
        XCTAssertEqual(StreamSeams.scan(StreamSeams.fragmentFiles(in: made)), [])
    }

    // MARK: The tally

    private let seams = [StreamSeam(time: 10, overlap: 0.07), StreamSeam(time: 20, overlap: 0.07),
                         StreamSeam(time: 30, overlap: 0.07)]

    func testOneSeamIsLeftAloneAndTheSecondIsNot() {
        var slip = SeamSlip(seams: seams)
        var asked: [Double] = []
        for t in stride(from: 0.0, through: 25, by: 0.5) where slip.advance(to: t) { asked.append(t) }
        // Half a second on: the first look at the playhead that is clear of it.
        XCTAssertEqual(asked.first, 20.5)
        XCTAssertEqual(slip.slip, 0.14, accuracy: 0.0001)
    }

    func testASeekStartsTheCountAgain() {
        var slip = SeamSlip(seams: seams)
        for t in stride(from: 9.0, through: 11, by: 0.5) { _ = slip.advance(to: t) }
        XCTAssertEqual(slip.slip, 0.07, accuracy: 0.0001)
        // Skipped back ten seconds without telling it: a step backwards.
        XCTAssertFalse(slip.advance(to: 1))
        XCTAssertEqual(slip.slip, 0)
        // And a jump forwards over two seams is not playing across them.
        XCTAssertFalse(slip.advance(to: 31))
        XCTAssertEqual(slip.slip, 0)
        slip.reset()
        XCTAssertFalse(slip.advance(to: 19.9))
        XCTAssertFalse(slip.advance(to: 20.4))
        XCTAssertEqual(slip.slip, 0.07, accuracy: 0.0001)
    }
}
