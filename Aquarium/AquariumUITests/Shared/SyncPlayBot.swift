//  The other person in a SyncPlay group, for tests: the suite's own API
//  session, joining, jumping, pausing and playing over the server's REST
//  calls. It has no player, so it tells the server not to wait for it
//  (`SetIgnoreWait`); otherwise everyone would wait for ever for it to say
//  it had buffered.

import XCTest

struct SyncPlayBot {
    struct Group {
        var id: String
        var name: String
        var state: String
        var people: Int
    }

    let api: JellyfinAPI

    init(_ api: JellyfinAPI) { self.api = api }

    /// The first group on the server, which in a test is the only one.
    func group() -> Group? {
        guard let list = try? api.json("/SyncPlay/List") as? [[String: Any]], let first = list.first else { return nil }
        return Group(id: first["GroupId"] as? String ?? "", name: first["GroupName"] as? String ?? "",
                     state: first["State"] as? String ?? "", people: (first["Participants"] as? [Any])?.count ?? 0)
    }

    func create(_ name: String) throws {
        try api.request("POST", "/SyncPlay/New", body: ["GroupName": name])
        try api.request("POST", "/SyncPlay/SetIgnoreWait", body: ["IgnoreWait": true])
    }

    func join(_ groupId: String) throws {
        try api.request("POST", "/SyncPlay/Join", body: ["GroupId": groupId])
        try api.request("POST", "/SyncPlay/SetIgnoreWait", body: ["IgnoreWait": true])
    }

    func putOn(_ itemId: String, at seconds: Double) throws {
        try api.request("POST", "/SyncPlay/SetNewQueue", body: [
            "PlayingQueue": [itemId], "PlayingItemPosition": 0, "StartPositionTicks": Int64(seconds * 10_000_000),
        ])
    }

    func seek(to seconds: Double) throws {
        try api.request("POST", "/SyncPlay/Seek", body: ["PositionTicks": Int64(seconds * 10_000_000)])
    }

    func pause() throws { try api.request("POST", "/SyncPlay/Pause") }
    func unpause() throws { try api.request("POST", "/SyncPlay/Unpause") }
    func leave() { _ = try? api.request("POST", "/SyncPlay/Leave") }
}
