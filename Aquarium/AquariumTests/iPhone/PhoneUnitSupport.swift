//  Small helpers for the iPhone unit tests: build the app's Jellyfin models
//  from the JSON the server sends, so a test reads like the answer it stands
//  for (field names exactly as Jellyfin writes them).

#if os(iOS)
import Foundation
import XCTest
@testable import Aquarium

enum PhoneJSON {
    static func decode<T: Decodable>(_ type: T.Type, _ json: String, file: StaticString = #filePath, line: UInt = #line) -> T {
        do {
            return try JSONDecoder().decode(T.self, from: Data(json.utf8))
        } catch {
            XCTFail("could not decode \(T.self): \(error)\n\(json)", file: file, line: line)
            fatalError("bad fixture JSON")
        }
    }

    static func item(_ json: String, file: StaticString = #filePath, line: UInt = #line) -> BaseItem {
        decode(BaseItem.self, json, file: file, line: line)
    }

    static func source(_ json: String, file: StaticString = #filePath, line: UInt = #line) -> MediaSource {
        decode(MediaSource.self, json, file: file, line: line)
    }

    /// A media source with one H.264 (or `videoCodec`) picture and one audio
    /// track, as `/Items/{id}/PlaybackInfo` describes it.
    static func videoSource(videoCodec: String = "h264", width: Int = 1920, height: Int = 1080,
                            bitrate: Int = 6_000_000, audioCodec: String = "aac",
                            container: String = "mp4", size: Int64 = 500_000_000) -> MediaSource {
        source("""
        {"Id":"src","Container":"\(container)","Size":\(size),"Bitrate":\(bitrate),"DefaultAudioStreamIndex":1,
         "MediaStreams":[
          {"Index":0,"Type":"Video","Codec":"\(videoCodec)","Width":\(width),"Height":\(height)},
          {"Index":1,"Type":"Audio","Codec":"\(audioCodec)","Channels":2,"Language":"eng"}]}
        """)
    }

    /// An episode, with what the Next Up rules read.
    static func episode(_ id: String, series: String = "s1", season: Int = 1, number: Int,
                        lastPlayed: String? = nil, played: Bool = false, position: Int64 = 0) -> BaseItem {
        var userData = "\"Played\":\(played),\"PlaybackPositionTicks\":\(position)"
        if let lastPlayed { userData += ",\"LastPlayedDate\":\"\(lastPlayed)\"" }
        return item("""
        {"Id":"\(id)","Name":"Episode \(number)","Type":"Episode","SeriesId":"\(series)","SeriesName":"Show",
         "ParentIndexNumber":\(season),"IndexNumber":\(number),"UserData":{\(userData)}}
        """)
    }
}
#endif
