//  fixtures.json: what is on the QA server, by stable key.
//
//  Written by the QA folder's make-fixtures.py and described in FIXTURES.md
//  there. Read at run time (never compiled in), from AQUARIUM_FIXTURES or the
//  QA folder; nil when it isn't there, and `Fixtures.require()` turns that
//  into a skip.
//
//      let film = try Fixtures.require().item("film.long_direct")
//      film.id, film.name, film.durationSeconds
//      try Fixtures.require().libraryId("Fixture Films")

import Foundation
import XCTest

struct Fixtures {
    struct Item {
        let key: String
        let id: String
        let name: String
        let type: String
        let durationSeconds: Double?
        /// The whole entry, for anything not lifted out above.
        let raw: [String: Any]
    }

    let serverURL: String?
    let serverId: String?
    let libraries: [String: String]
    let items: [String: Item]
    let raw: [String: Any]

    static var file: URL {
        if let path = QA.env["AQUARIUM_FIXTURES"], !path.isEmpty { return URL(fileURLWithPath: path) }
        return QA.folder.appendingPathComponent("fixtures.json")
    }

    static let shared: Fixtures? = load(file)

    static func require(file: StaticString = #filePath, line: UInt = #line) throws -> Fixtures {
        guard let shared else { throw XCTSkip("fixtures.json not found at \(Self.file.path)") }
        return shared
    }

    static func load(_ url: URL) -> Fixtures? {
        guard let data = try? Data(contentsOf: url),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        let server = root["server"] as? [String: Any]
        var libraries: [String: String] = [:]
        for (name, value) in root["libraries"] as? [String: Any] ?? [:] {
            if let id = (value as? [String: Any])?["id"] as? String { libraries[name] = id }
        }
        var items: [String: Item] = [:]
        for (key, value) in root["fixtures"] as? [String: Any] ?? [:] {
            guard let entry = value as? [String: Any], let id = entry["id"] as? String else { continue }
            items[key] = Item(
                key: key, id: id,
                name: entry["name"] as? String ?? "",
                type: entry["type"] as? String ?? "",
                durationSeconds: entry["durationSeconds"] as? Double,
                raw: entry
            )
        }
        return Fixtures(serverURL: server?["url"] as? String, serverId: server?["id"] as? String,
                        libraries: libraries, items: items, raw: root)
    }

    func item(_ key: String, file: StaticString = #filePath, line: UInt = #line) throws -> Item {
        guard let item = items[key] else { throw XCTSkip("no fixture \(key) in fixtures.json") }
        return item
    }

    func libraryId(_ name: String) throws -> String {
        guard let id = libraries[name] else { throw XCTSkip("no library \(name) in fixtures.json") }
        return id
    }
}
