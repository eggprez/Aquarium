//  `StreamDiagnosis` and `TransportStream`: what is inside a channel that
//  opened and showed no picture, read from the stream's own program map.
//  The transport-stream packets are built here, byte by byte, the way a muxer
//  writes them; the playlists and segments are served from this machine's
//  loopback address.

import XCTest
@testable import Aquarium

/// Just enough of a muxer for the tables the diagnosis reads.
private enum TS {
    /// One 188-byte packet carrying the start of a table section.
    static func packet(pid: Int, section: [UInt8], adaptation: Int? = nil, startsSection: Bool = true) -> [UInt8] {
        var bytes: [UInt8] = [0x47, UInt8((startsSection ? 0x40 : 0) | ((pid >> 8) & 0x1F)), UInt8(pid & 0xFF)]
        if let adaptation {
            bytes.append(0x30)                       // adaptation field, then payload
            bytes.append(UInt8(adaptation))
            bytes += [UInt8](repeating: 0xFF, count: adaptation)
        } else {
            bytes.append(0x10)                       // payload only
        }
        bytes.append(0x00)                           // pointer: the section starts here
        bytes += section
        precondition(bytes.count <= 188)
        return bytes + [UInt8](repeating: 0xFF, count: 188 - bytes.count)
    }

    /// A packet with an adaptation field and no payload at all.
    static func adaptationOnly(pid: Int) -> [UInt8] {
        [0x47, UInt8(0x40 | ((pid >> 8) & 0x1F)), UInt8(pid & 0xFF), 0x20, 183] + [UInt8](repeating: 0xFF, count: 183)
    }

    static func pat(_ programs: [(number: Int, pid: Int)]) -> [UInt8] {
        var body: [UInt8] = [0x00, 0x01, 0xC1, 0x00, 0x00]
        for program in programs {
            body += [UInt8(program.number >> 8), UInt8(program.number & 0xFF),
                     UInt8(0xE0 | (program.pid >> 8)), UInt8(program.pid & 0xFF)]
        }
        return section(table: 0x00, body: body)
    }

    static func pmt(_ streams: [(type: UInt8, pid: Int, descriptors: [UInt8])], programInfo: [UInt8] = []) -> [UInt8] {
        var body: [UInt8] = [0x00, 0x01, 0xC1, 0x00, 0x00, 0xE1, 0x00,
                             UInt8(0xF0 | (programInfo.count >> 8)), UInt8(programInfo.count & 0xFF)]
        body += programInfo
        for stream in streams {
            body += [stream.type, UInt8(0xE0 | (stream.pid >> 8)), UInt8(stream.pid & 0xFF),
                     UInt8(0xF0 | (stream.descriptors.count >> 8)), UInt8(stream.descriptors.count & 0xFF)]
            body += stream.descriptors
        }
        return section(table: 0x02, body: body)
    }

    /// Table id, length, body, and four bytes standing for the CRC.
    private static func section(table: UInt8, body: [UInt8]) -> [UInt8] {
        let length = body.count + 4
        return [table, UInt8(0xB0 | (length >> 8)), UInt8(length & 0xFF)] + body + [0xDE, 0xAD, 0xBE, 0xEF]
    }

    /// A segment's head: the program table, then the program map on `pmtPID`.
    static func segment(_ streams: [(type: UInt8, pid: Int, descriptors: [UInt8])], pmtPID: Int = 0x1000) -> Data {
        Data(packet(pid: 0, section: pat([(1, pmtPID)])) + packet(pid: pmtPID, section: pmt(streams)))
    }
}

final class TransportStreamTests: XCTestCase {
    private func names(_ data: Data) -> [String] { TransportStream.elementaryStreams(in: data).map(\.name) }

    func testH264AndAACAreReadFromTheProgramMap() {
        let streams = TransportStream.elementaryStreams(in: TS.segment([(0x1B, 0x100, []), (0x0F, 0x101, [])]))
        XCTAssertEqual(streams.map(\.name), ["H.264", "AAC"])
        XCTAssertEqual(streams.map(\.isVideo), [true, false])
        XCTAssertEqual(streams.map(\.playsFromTransportStream), [true, true])
    }

    func testEveryCodecTheMapCanNameIsNamed() {
        let all: [(UInt8, String, Bool, Bool)] = [
            (0x01, "MPEG-1 video", true, false), (0x02, "MPEG-2 video", true, false), (0x1B, "H.264", true, true),
            (0x24, "H.265 (HEVC)", true, false), (0x27, "H.265 (HEVC)", true, false), (0x33, "AV1", true, false),
            (0x03, "MPEG audio", false, true), (0x04, "MPEG audio", false, true), (0x0F, "AAC", false, true),
            (0x11, "AAC", false, true), (0x81, "AC-3", false, true), (0x87, "E-AC-3", false, true),
        ]
        let streams = TransportStream.elementaryStreams(in: TS.segment(all.enumerated().map { ($1.0, 0x100 + $0, []) }))
        XCTAssertEqual(streams.map(\.name), all.map(\.1))
        XCTAssertEqual(streams.map(\.isVideo), all.map(\.2))
        XCTAssertEqual(streams.map(\.playsFromTransportStream), all.map(\.3))
    }

    func testUnknownStreamTypesAreLeftOut() {
        // 0x06 is private data (subtitles, teletext); 0x15 is metadata.
        XCTAssertEqual(names(TS.segment([(0x06, 0x100, []), (0x24, 0x101, []), (0x15, 0x102, [])])), ["H.265 (HEVC)"])
    }

    func testDescriptorsAndProgramInfoAreSteppedOver() {
        let pmt = TS.pmt([(0x24, 0x100, [0x05, 0x04, 0x48, 0x45, 0x56, 0x43]), (0x81, 0x101, [0x0A, 0x04, 0x65, 0x6E, 0x67, 0x00])],
                         programInfo: [0x0C, 0x02, 0x1B, 0x0F])
        let data = Data(TS.packet(pid: 0, section: TS.pat([(1, 0x1000)])) + TS.packet(pid: 0x1000, section: pmt))
        XCTAssertEqual(names(data), ["H.265 (HEVC)", "AC-3"],
                       "a descriptor byte that happens to equal a stream type is not a stream")
    }

    func testJunkBeforeTheFirstPacketIsSkipped() {
        let data = Data([0x00, 0x01, 0x02, 0x03, 0xFF]) + TS.segment([(0x1B, 0x100, [])])
        XCTAssertEqual(names(data), ["H.264"])
    }

    func testLostAlignmentIsFoundAgain() {
        let pat = TS.packet(pid: 0, section: TS.pat([(1, 0x1000)]))
        let pmt = TS.packet(pid: 0x1000, section: TS.pmt([(0x0F, 0x101, [])]))
        XCTAssertEqual(names(Data(pat + [UInt8](repeating: 0x00, count: 37) + pmt)), ["AAC"])
    }

    func testAnAdaptationFieldBeforeTheSectionIsSteppedOver() {
        let data = Data(TS.packet(pid: 0, section: TS.pat([(1, 0x1000)]), adaptation: 7)
            + TS.adaptationOnly(pid: 0x1000)
            + TS.packet(pid: 0x1000, section: TS.pmt([(0x1B, 0x100, [])]), adaptation: 1))
        XCTAssertEqual(names(data), ["H.264"])
    }

    func testOnlyTheProgramMapTheTableNamesIsRead() {
        // The network table (program 0) is not a program map, and a section on
        // a PID the table never named is somebody else's.
        let pat = TS.packet(pid: 0, section: TS.pat([(0, 0x0010), (1, 0x1000)]))
        let decoy = TS.packet(pid: 0x0010, section: TS.pmt([(0x02, 0x200, [])]))
        let stranger = TS.packet(pid: 0x0777, section: TS.pmt([(0x33, 0x300, [])]))
        let real = TS.packet(pid: 0x1000, section: TS.pmt([(0x1B, 0x100, [])]))
        XCTAssertEqual(names(Data(pat + decoy + stranger + real)), ["H.264"])
        XCTAssertEqual(names(Data(decoy + stranger)), [], "no program table, nothing to trust")
    }

    func testAProgramMapBeforeItsTableIsNotRead() {
        let data = Data(TS.packet(pid: 0x1000, section: TS.pmt([(0x1B, 0x100, [])])) + TS.packet(pid: 0, section: TS.pat([(1, 0x1000)])))
        XCTAssertEqual(names(data), [])
    }

    func testPacketsThatContinueASectionAreIgnored() {
        let pat = TS.packet(pid: 0, section: TS.pat([(1, 0x1000)]))
        let continuation = TS.packet(pid: 0x1000, section: TS.pmt([(0x02, 0x200, [])]), startsSection: false)
        XCTAssertEqual(names(Data(pat + continuation)), [])
    }

    func testNothingUsableIsNoStreamsRatherThanACrash() {
        XCTAssertEqual(names(Data()), [])
        XCTAssertEqual(names(Data([0x00, 0x11, 0x22])), [], "no sync byte")
        XCTAssertEqual(names(Data([0x47, 0x40, 0x00, 0x10])), [], "less than one packet")
        // A section that says it is longer than its packet.
        var liar = TS.packet(pid: 0, section: TS.pat([(1, 0x1000)]))
        liar[6] = 0xBF
        liar[7] = 0xFF
        XCTAssertEqual(names(Data(liar + TS.packet(pid: 0x1000, section: TS.pmt([(0x1B, 0x100, [])])))), [])
        XCTAssertEqual(names(Data([UInt8](repeating: 0x47, count: 188 * 3))), [], "sync bytes all the way down")
    }
}

final class StreamDiagnosisTests: XCTestCase {
    private var server: LoopbackServer!

    override func setUpWithError() throws { server = try LoopbackServer() }
    override func tearDown() { server.stop() }

    private let mpegurl = "application/vnd.apple.mpegurl"

    private func media(_ segment: String) -> String {
        "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:6\n#EXTINF:6.0,\n\(segment)\n#EXTINF:6.0,\nlater.ts\n"
    }

    func testHEVCInTransportSegmentsIsNamedThroughAMasterPlaylist() async throws {
        let segment = TS.segment([(0x24, 0x100, []), (0x0F, 0x101, [])])
        let mediaText = media("seg0.ts")
        server.setHandler { [mpegurl] request in
            switch request.path {
            case "/live/master.m3u8":
                .text("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080\n  v/hd.m3u8  \n#EXT-X-STREAM-INF:BANDWIDTH=900000\nv/sd.m3u8\n", type: mpegurl)
            case "/live/v/hd.m3u8": .text(mediaText, type: mpegurl)
            case "/live/v/seg0.ts": .data(segment, type: "video/mp2t")
            default: .status(404)
            }
        }
        let found = await StreamDiagnosis.inspect(hlsURL: server.url("/live/master.m3u8"))
        let finding = try XCTUnwrap(found)
        XCTAssertTrue(finding.videoWillNotPlay)
        XCTAssertTrue(finding.message.hasPrefix("This channel's video is H.265 (HEVC), sent as MPEG-TS segments with AAC audio."), finding.message)
        XCTAssertTrue(finding.message.contains("It has to be sent as H.264"), finding.message)
        XCTAssertEqual(server.requests.map(\.path), ["/live/master.m3u8", "/live/v/hd.m3u8", "/live/v/seg0.ts"],
                       "the first variant, and the first segment of it, each relative to where it was listed")
        XCTAssertEqual(server.requests.last?.headers["range"], "bytes=0-131071", "only the head of one segment is asked for")
    }

    func testVideoWithNoAudioLeavesTheAudioOutOfTheSentence() async throws {
        let segment = TS.segment([(0x33, 0x100, [])])
        let mediaText = media("/abs/seg.ts")
        server.setHandler { [mpegurl] request in
            request.path == "/ch.m3u8" ? .text(mediaText, type: mpegurl) : .data(segment, type: "video/mp2t")
        }
        let found = await StreamDiagnosis.inspect(hlsURL: server.url("/ch.m3u8"))
        let finding = try XCTUnwrap(found)
        XCTAssertTrue(finding.message.hasPrefix("This channel's video is AV1, sent as MPEG-TS segments. "), finding.message)
        XCTAssertEqual(server.requests.map(\.path), ["/ch.m3u8", "/abs/seg.ts"])
    }

    func testAnAudioOnlyStreamSaysSo() async throws {
        let segment = TS.segment([(0x81, 0x101, [])])
        let mediaText = media("seg0.ts")
        server.setHandler { [mpegurl] request in
            request.path.hasSuffix(".m3u8") ? .text(mediaText, type: mpegurl) : .data(segment, type: "video/mp2t")
        }
        let found = await StreamDiagnosis.inspect(hlsURL: server.url("/radio.m3u8"))
        let finding = try XCTUnwrap(found)
        XCTAssertTrue(finding.videoWillNotPlay)
        XCTAssertEqual(finding.message, "This channel is carrying no video at all — only AC-3. It is being sent as an audio-only stream.")
    }

    func testH264HasNothingToReport() async {
        let segment = TS.segment([(0x1B, 0x100, []), (0x0F, 0x101, [])])
        let mediaText = media("seg0.ts")
        server.setHandler { [mpegurl] request in
            request.path.hasSuffix(".m3u8") ? .text(mediaText, type: mpegurl) : .data(segment, type: "video/mp2t")
        }
        let found = await StreamDiagnosis.inspect(hlsURL: server.url("/fine.m3u8"))
        XCTAssertNil(found)
        XCTAssertEqual(server.requests.count, 2, "it was read, and found to be playable")
    }

    func testFragmentedMP4SegmentsAreNotFetched() async {
        for name in ["seg0.m4s", "SEG0.MP4"] {
            let mediaText = media(name)
            server.setHandler { [mpegurl] _ in .text(mediaText, type: mpegurl) }
            let found = await StreamDiagnosis.inspect(hlsURL: server.url("/fmp4-\(name).m3u8"))
            XCTAssertNil(found, name)
        }
        XCTAssertEqual(server.requests.count, 2, "one playlist each; fMP4 is the shape Apple does read HEVC from")
    }

    func testAnAddressThatIsNotAPlaylistIsLeftAlone() async {
        server.setHandler { _ in .text("<html>Not found</html>", type: "text/html") }
        let found = await StreamDiagnosis.inspect(hlsURL: server.url("/page"))
        XCTAssertNil(found)
        XCTAssertEqual(server.requests.count, 1)
    }

    func testFailuresAlongTheWayAreNoFinding() async {
        // The playlist is refused.
        server.setHandler { _ in .status(403) }
        var found = await StreamDiagnosis.inspect(hlsURL: server.url("/a.m3u8"))
        XCTAssertNil(found)

        // A master playlist that lists nothing.
        server.setHandler { [mpegurl] _ in .text("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\n", type: mpegurl) }
        found = await StreamDiagnosis.inspect(hlsURL: server.url("/b.m3u8"))
        XCTAssertNil(found)

        // A playlist with no segments yet.
        server.setHandler { [mpegurl] _ in .text("#EXTM3U\n#EXT-X-TARGETDURATION:6\n", type: mpegurl) }
        found = await StreamDiagnosis.inspect(hlsURL: server.url("/c.m3u8"))
        XCTAssertNil(found)

        // The segment is missing, then empty, then not a transport stream.
        let mediaText = media("seg0.ts")
        for answer in [LoopbackServer.Response.status(404), .data(Data(), type: "video/mp2t"), .text("not a transport stream", type: "video/mp2t")] {
            server.setHandler { [mpegurl] request in
                request.path.hasSuffix(".m3u8") ? .text(mediaText, type: mpegurl) : answer
            }
            found = await StreamDiagnosis.inspect(hlsURL: server.url("/d.m3u8"))
            XCTAssertNil(found)
        }
    }

    func testOnlyWebAddressesAreRead() async throws {
        // A playlist on this device would otherwise be opened like any other.
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("diagnosis-\(UUID().uuidString).m3u8")
        try Data(media("seg0.ts").utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let found = await StreamDiagnosis.inspect(hlsURL: file)
        XCTAssertNil(found)

        // And a web playlist that points at a file is not followed there.
        let mediaText = media(file.absoluteString)
        server.setHandler { [mpegurl] _ in .text(mediaText, type: mpegurl) }
        let second = await StreamDiagnosis.inspect(hlsURL: server.url("/points-at-file.m3u8"))
        XCTAssertNil(second)
        XCTAssertEqual(server.requests.count, 1)
    }
}
