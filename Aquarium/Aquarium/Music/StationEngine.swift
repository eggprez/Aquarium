//  How a station chooses and orders its songs.
//
//  Three parts. `MusicNames` puts one name on a genre that the tags spell a
//  dozen ways — "Rockmusik", "Rock Music", "ロック" and "rock" are one genre
//  here — and a Latin-script name on an artist where there is a fair one to
//  give. `MixProfile` reduces a seed to what a candidate is measured against.
//  `StationRanker` scores every candidate against that profile *and* against
//  what this account has shown it likes (`MusicTaste`), then deals them out in
//  an order that doesn't put one artist, or one album, back to back.
//
//  The weights are deliberate: taste outweighs likeness. A song the seed only
//  vaguely resembles but that this account plays to the end every time beats a
//  close match it always skips. Likeness decides what is *in* a station;
//  taste decides what comes first.

import Foundation

// MARK: - Names

enum MusicNames {
    /// One key per genre, whatever language or spelling the tag used.
    /// Lowercased, accents folded, "music"/"musik"/"musique" dropped, and
    /// then looked up in the synonyms below.
    static func genreKey(_ raw: String) -> String {
        let folded = normalized(raw)
        if let hit = synonyms[folded] { return hit }
        let trimmed = folded.split(separator: " ").filter { !suffixes.contains(String($0)) }.joined(separator: " ")
        if let hit = synonyms[trimmed] { return hit }
        return trimmed.isEmpty ? folded : trimmed
    }

    /// The name to show for a genre: the English name when it is one this
    /// table knows, otherwise the tag as written, capitalised if it is Latin.
    static func genreName(_ raw: String) -> String {
        let key = genreKey(raw)
        if let name = displayNames[key] { return name }
        if isLatin(raw) { return raw.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ") }
        return raw
    }

    /// An artist's name in Latin letters when a fair one can be had: the
    /// server's sort name when that is Latin ("Utada, Hikaru" → "Hikaru
    /// Utada"), else a transliteration for scripts that have a reliable one
    /// (kana, hangul, Cyrillic, Greek, Chinese). Japanese written with kanji
    /// is left alone — the only transliteration the system has for kanji is
    /// Mandarin, and a Japanese name read as Mandarin is wrong, not helpful.
    static func artistName(_ name: String, sortName: String? = nil) -> String {
        guard Preferences.shared.musicRomanizeNames, !name.isEmpty, !isLatin(name) else { return name }
        if let sort = sortName, !sort.isEmpty, isLatin(sort) {
            let parts = sort.components(separatedBy: ", ")
            return parts.count == 2 ? "\(parts[1]) \(parts[0])" : sort
        }
        let scalars = name.unicodeScalars
        let hasHan = scalars.contains { (0x4E00...0x9FFF).contains($0.value) || (0x3400...0x4DBF).contains($0.value) }
        let hasKana = scalars.contains { (0x3040...0x30FF).contains($0.value) }
        if hasHan && hasKana { return name }
        guard let latin = name.applyingTransform(.toLatin, reverse: false)?
            .applyingTransform(.stripDiacritics, reverse: false), isLatin(latin) else { return name }
        return latin.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    static func isLatin(_ s: String) -> Bool {
        s.unicodeScalars.allSatisfy { !$0.properties.isAlphabetic || $0.value < 0x250 || (0x1E00...0x1EFF).contains($0.value) }
    }

    private static func normalized(_ raw: String) -> String {
        let folded = raw.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        let spaced = folded.map { "-_/.;:".contains($0) ? " " : $0 }
        return String(spaced).split(separator: " ").joined(separator: " ")
    }

    private static let suffixes: Set<String> = ["music", "musik", "musique", "musica", "muziek", "musikk", "muzyka", "musiikki", "genre"]

    /// Key → the name shown for it.
    private static let displayNames: [String: String] = [
        "rock": "Rock", "pop": "Pop", "electronic": "Electronic", "hip hop": "Hip-Hop", "r&b": "R&B",
        "soul": "Soul", "funk": "Funk", "jazz": "Jazz", "blues": "Blues", "classical": "Classical",
        "country": "Country", "folk": "Folk", "metal": "Metal", "punk": "Punk", "reggae": "Reggae",
        "latin": "Latin", "soundtrack": "Soundtrack", "anime": "Anime", "dance": "Dance", "house": "House",
        "techno": "Techno", "trance": "Trance", "ambient": "Ambient", "alternative": "Alternative",
        "indie": "Indie", "singer songwriter": "Singer-Songwriter", "world": "World", "children": "Children's",
        "christmas": "Christmas", "gospel": "Gospel", "new age": "New Age", "easy listening": "Easy Listening",
        "instrumental": "Instrumental", "lo fi": "Lo-Fi", "k pop": "K-Pop", "j pop": "J-Pop", "j rock": "J-Rock",
        "c pop": "C-Pop", "cantopop": "Cantopop", "rock and roll": "Rock & Roll", "hard rock": "Hard Rock",
        "progressive rock": "Progressive Rock", "drum and bass": "Drum & Bass", "trip hop": "Trip-Hop",
        "chillout": "Chill", "acoustic": "Acoustic", "opera": "Opera", "disco": "Disco", "edm": "EDM",
        "enka": "Enka", "kayokyoku": "Kayōkyoku", "city pop": "City Pop", "trot": "Trot", "chanson": "Chanson",
        "experimental": "Experimental", "alternative rock": "Alternative Rock", "indie rock": "Indie Rock",
        "indie pop": "Indie Pop", "synthpop": "Synth-Pop", "comedy": "Comedy", "musical": "Musicals",
    ]

    /// Spelling (already folded) → key. Several languages each, where the
    /// tag sources on a Jellyfin server — MusicBrainz, Discogs, embedded tags
    /// from wherever the files came from — are known to use them.
    private static let synonyms: [String: String] = {
        let groups: [String: [String]] = [
            "rock": ["rock", "rockmusik", "rock music", "musica rock", "musique rock", "摇滚", "搖滾", "ロック", "록", "рок"],
            "pop": ["pop", "popmusik", "pop music", "musica pop", "musique pop", "流行", "流行音乐", "流行音樂", "ポップ", "ポップス", "팝", "поп", "попса"],
            "electronic": ["electronic", "electronica", "electro", "elettronica", "electronique", "elektronisch", "elektronik",
                           "elektronische musik", "electronic music", "エレクトロニカ", "エレクトロニック", "电子", "电子音乐", "電子音樂",
                           "電子音楽", "일렉트로닉", "электроника", "электронная"],
            "hip hop": ["hip hop", "hiphop", "hip hop rap", "rap hip hop", "rap", "hip hop music", "ヒップホップ", "ラップ", "힙합",
                        "랩", "嘻哈", "说唱", "饒舌", "хип хоп", "рэп", "рэп и хип хоп"],
            "r&b": ["r&b", "rnb", "r n b", "r and b", "rhythm and blues", "rhythm & blues", "contemporary r&b", "リズム アンド ブルース",
                    "알앤비", "节奏布鲁斯"],
            "soul": ["soul", "ソウル", "소울", "灵魂乐", "соул"],
            "funk": ["funk", "ファンク", "放克", "фанк"],
            "jazz": ["jazz", "ジャズ", "재즈", "爵士", "爵士乐", "джаз"],
            "blues": ["blues", "ブルース", "블루스", "蓝调", "藍調", "блюз"],
            "classical": ["classical", "classique", "klassik", "klassisch", "klassische musik", "clasica", "musica clasica", "classica",
                          "musica classica", "klassiek", "klassisk", "クラシック", "클래식", "古典", "古典音乐", "古典音樂", "классика",
                          "классическая", "классическая музыка", "classical music"],
            "country": ["country", "country music", "カントリー", "컨트리", "乡村", "鄉村", "乡村音乐", "кантри"],
            "folk": ["folk", "folk music", "musica folk", "フォーク", "民谣", "民謠", "фолк"],
            "metal": ["metal", "heavy metal", "metal music", "メタル", "ヘヴィメタル", "메탈", "金属", "重金属", "метал", "хэви метал"],
            "punk": ["punk", "punk rock", "パンク", "朋克", "панк"],
            "reggae": ["reggae", "レゲエ", "레게", "雷鬼", "регги"],
            "latin": ["latin", "latino", "latina", "musica latina", "latin music", "ラテン", "라틴", "拉丁", "латиноамериканская"],
            "soundtrack": ["soundtrack", "soundtracks", "ost", "original soundtrack", "film score", "score", "film soundtrack",
                           "movie soundtrack", "bande originale", "bande originale de film", "filmmusik", "banda sonora", "colonna sonora",
                           "soundtrack music", "サウンドトラック", "サントラ", "사운드트랙", "영화음악", "原声", "原声带", "原聲帶", "电影原声",
                           "саундтрек"],
            "anime": ["anime", "anison", "アニメ", "アニソン", "アニメソング", "动漫", "動漫", "애니메이션"],
            "dance": ["dance", "dance music", "musica dance", "ダンス", "댄스", "舞曲", "танцевальная", "танцевальная музыка"],
            "house": ["house", "house music", "ハウス", "하우스", "хаус"],
            "techno": ["techno", "テクノ", "테크노", "техно"],
            "trance": ["trance", "トランス", "트랜스", "транс"],
            "ambient": ["ambient", "アンビエント", "앰비언트", "氛围", "эмбиент"],
            "alternative": ["alternative", "alternativ", "alternatif", "alternativo", "alternativa", "alt", "オルタナティヴ",
                            "オルタナティブ", "オルタナ", "얼터너티브", "另类", "另類", "альтернатива", "альтернативная"],
            "alternative rock": ["alternative rock", "alt rock", "オルタナティヴ ロック", "얼터너티브 록", "另类摇滚", "альтернативный рок"],
            "indie": ["indie", "independent", "インディー", "インディーズ", "인디", "独立", "獨立", "инди"],
            "indie rock": ["indie rock", "インディー ロック", "인디 록", "独立摇滚", "инди рок"],
            "indie pop": ["indie pop", "インディー ポップ", "인디 팝", "独立流行"],
            "singer songwriter": ["singer songwriter", "cantautor", "cantautore", "cantautora", "liedermacher", "auteur compositeur interprete",
                                  "シンガーソングライター", "싱어송라이터", "创作歌手"],
            "world": ["world", "world music", "musiques du monde", "weltmusik", "musica del mundo", "ワールド", "ワールドミュージック",
                      "월드 뮤직", "世界音乐"],
            "children": ["children", "children's", "childrens", "kids", "children's music", "kinder", "kinderlieder", "kindermusik",
                         "童谣", "童謡", "童謠", "동요", "детская", "детские песни"],
            "christmas": ["christmas", "holiday", "xmas", "weihnachten", "weihnachtslieder", "navidad", "villancicos", "noel",
                          "chants de noel", "natale", "クリスマス", "크리스마스", "圣诞", "聖誕", "рождество"],
            "gospel": ["gospel", "ゴスペル", "가스펠", "福音"],
            "new age": ["new age", "ニューエイジ", "뉴에이지", "新世纪", "нью эйдж"],
            "easy listening": ["easy listening", "イージーリスニング", "이지 리스닝"],
            "instrumental": ["instrumental", "instrumentale", "インストゥルメンタル", "インスト", "연주곡", "纯音乐", "純音樂", "инструментальная"],
            "lo fi": ["lo fi", "lofi", "lo fi hip hop", "ローファイ", "로파이"],
            "k pop": ["k pop", "kpop", "케이팝", "가요", "韩流", "韓流", "k pop music"],
            "j pop": ["j pop", "jpop", "ジェイポップ", "邦楽", "日本流行"],
            "j rock": ["j rock", "jrock", "邦ロック", "日本摇滚"],
            "c pop": ["c pop", "cpop", "mandopop", "华语流行", "華語流行", "國語流行", "国语流行"],
            "cantopop": ["cantopop", "粤语流行", "粵語流行"],
            "rock and roll": ["rock and roll", "rock & roll", "rock n roll", "rock'n'roll", "rock 'n' roll", "rocknroll", "ロックンロール",
                              "로큰롤", "рок н ролл"],
            "hard rock": ["hard rock", "ハードロック", "하드 록", "硬摇滚", "хард рок"],
            "progressive rock": ["progressive rock", "prog rock", "prog", "プログレ", "プログレッシブ ロック", "前卫摇滚", "прогрессивный рок"],
            "drum and bass": ["drum and bass", "drum & bass", "drum n bass", "dnb", "d&b", "drum'n'bass", "ドラムンベース"],
            "trip hop": ["trip hop", "triphop", "トリップホップ"],
            "chillout": ["chillout", "chill out", "chill", "chillhop", "チルアウト", "칠아웃"],
            "acoustic": ["acoustic", "akustik", "acustico", "acoustique", "アコースティック", "어쿠스틱", "原声吉他"],
            "opera": ["opera", "oper", "オペラ", "오페라", "歌剧", "歌劇", "опера"],
            "disco": ["disco", "ディスコ", "디스코", "迪斯科", "диско"],
            "edm": ["edm", "electronic dance music", "electronic dance"],
            "enka": ["enka", "演歌"],
            "kayokyoku": ["kayokyoku", "kayoukyoku", "歌謡曲"],
            "city pop": ["city pop", "シティポップ", "シティ ポップ", "시티팝"],
            "trot": ["trot", "트로트", "뽕짝"],
            "chanson": ["chanson", "chanson francaise", "variete francaise", "シャンソン", "샹송", "шансон"],
            "experimental": ["experimental", "experimentell", "experimentale", "experimentelle musik", "実験音楽", "실험음악", "实验"],
            "synthpop": ["synthpop", "synth pop", "electropop", "シンセポップ", "신스팝", "синти поп"],
            "comedy": ["comedy", "humor", "humour", "comedie", "komödie", "コメディ", "喜剧"],
            "musical": ["musical", "musicals", "show tunes", "broadway", "cast recording", "ミュージカル", "뮤지컬", "音乐剧", "мюзикл"],
        ]
        var out: [String: String] = [:]
        for (key, spellings) in groups {
            for s in spellings { out[normalized(s)] = key }
        }
        return out
    }()
}

// MARK: - Artists, by id or by name

enum MusicKeys {
    /// Songs know an artist by id; a record downloaded before there was an
    /// index knows a name. Both spellings, so either finds the other.
    static func artist(id: String?, name: String?) -> Set<String> {
        var out = Set<String>()
        if let id, !id.isEmpty { out.insert("id:\(id)") }
        if let name, !name.isEmpty { out.insert("name:\(name.lowercased())") }
        return out
    }

    static func artists(of song: BaseItem) -> Set<String> {
        var out = artist(id: nil, name: song.AlbumArtist)
        for pair in (song.ArtistItems ?? []) + (song.AlbumArtists ?? []) {
            out.formUnion(artist(id: pair.Id, name: pair.Name))
        }
        for name in song.Artists ?? [] { out.formUnion(artist(id: nil, name: name)) }
        return out
    }

    /// How a song is billed, plainly: the act's name, lowercased.
    static func lead(of song: BaseItem) -> String {
        let raw = song.AlbumArtist
            ?? (song.AlbumArtists?.first ?? song.ArtistItems?.first)?.Name
            ?? song.artistLine
        return raw.lowercased().trimmingCharacters(in: .whitespaces)
    }

    /// The act a song is credited to, by id and by name — not its guests.
    static func act(of song: BaseItem) -> Set<String> {
        var out = artist(id: nil, name: song.AlbumArtist)
        for pair in song.AlbumArtists ?? [] { out.formUnion(artist(id: pair.Id, name: pair.Name)) }
        if out.isEmpty, let first = song.ArtistItems?.first {
            out.formUnion(artist(id: first.Id, name: first.Name))
        }
        return out
    }

    static func genres(of song: BaseItem) -> [String] {
        let raw = song.Genres ?? song.GenreItems?.compactMap(\.Name) ?? []
        var seen = Set<String>()
        return raw.map(MusicNames.genreKey).filter { seen.insert($0).inserted }
    }
}

// MARK: - The seed

/// What a station is measured against: the seed, reduced to artists, genres
/// (by key), a year and an album.
struct MixProfile: Sendable {
    var artists = Set<String>()
    var genres: [String: Double] = [:]
    var words: [String: Double] = [:]
    var year: Int?
    var albumId: String?
    /// The seed is itself a song: it opens the station.
    var songId: String?
    /// A station about no one thing — Rediscover, Deep Cuts — is all taste.
    var isOpen = false
    var isArtistStation = false

    init(open: Bool) { isOpen = open }

    /// `members` are the seed's own songs where it has some to hand — an
    /// album's tracks, an artist's songs — and what its genres and years are
    /// read from.
    init(seed: BaseItem, members given: [BaseItem] = []) {
        var members = given
        if seed.isMusicGenre {
            add(genres: [MusicNames.genreKey(seed.title)])
        } else if seed.isArtist {
            isArtistStation = true
            artists = MusicKeys.artist(id: seed.Id, name: seed.Name)
        } else if seed.isAlbum {
            albumId = seed.Id
            year = seed.ProductionYear
        } else if seed.isSong {
            songId = seed.Id
            albumId = seed.AlbumId
            if members.isEmpty { members = [seed] }
        }
        for song in members {
            if !seed.isArtist { artists.formUnion(MusicKeys.artists(of: song)) }
            add(genres: MusicKeys.genres(of: song))
        }
        if members.isEmpty, !seed.isMusicGenre {
            artists.formUnion(MusicKeys.artists(of: seed))
            add(genres: MusicKeys.genres(of: seed))
        }
        if year == nil {
            let years = members.compactMap(\.ProductionYear).sorted()
            year = years.isEmpty ? seed.ProductionYear : years[years.count / 2]
        }
        // An artist's station is about their sound, not their decade.
        if seed.isArtist || seed.isMusicGenre { year = nil }
    }

    private mutating func add(genres keys: [String]) {
        for key in keys {
            genres[key, default: 0] += 1
            for word in Self.words(key) { words[word, default: 0] += 1 }
        }
    }

    private static let filler: Set<String> = ["music", "and", "the", "of", "&"]

    static func words(_ genre: String) -> [String] {
        genre.split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 1 && !filler.contains($0) }
    }

    /// 0…1: how much of the seed's genre weight a candidate's genres cover,
    /// counting a shared word ("indie rock" beside "rock") at half.
    func genreAffinity(_ candidate: [String]) -> Double {
        let total = genres.values.reduce(0, +)
        guard total > 0, !candidate.isEmpty else { return 0 }
        let keys = Set(candidate)
        let whole = keys.reduce(0.0) { $0 + (genres[$1] ?? 0) } / total
        let wordTotal = words.values.reduce(0, +)
        let shared = Set(keys.flatMap(Self.words)).reduce(0.0) { $0 + (words[$1] ?? 0) }
        let partial = wordTotal > 0 ? 0.5 * shared / wordTotal : 0
        return min(1, max(whole, partial))
    }

    /// 0…~9: how like the seed a song is. Zero means nothing in common.
    func likeness(_ song: BaseItem) -> Double {
        if isOpen { return 1 }
        let sameArtist = !artists.isDisjoint(with: MusicKeys.artists(of: song))
        let genre = genreAffinity(MusicKeys.genres(of: song))
        guard sameArtist || genre > 0 else { return 0 }
        var score = (sameArtist ? 3.0 : 0) + 4.0 * genre
        if let a = year, let b = song.ProductionYear {
            score += 1.5 * max(0, 1 - Double(abs(a - b)) / 15)
        }
        if let albumId, song.AlbumId == albumId { score += 0.5 }
        return score
    }
}

// MARK: - One act, however it is billed

/// Which billings are the same act, worked out from the billings themselves.
///
/// A library files a band's own records and the ones it backed somebody on
/// as different artists with different ids — and a station that believes
/// them plays two in a row and calls it variety. Two billings are the same
/// act here when they share an album artist, or when one name is where the
/// other begins ("Tom Petty" / "Tom Petty and the Heartbreakers"). No list
/// of artists anywhere: it is the shape of the billing that decides.
struct ArtistGroups {
    private var groupOf: [String: String] = [:]
    private var keys: [String: Set<String>] = [:]
    private var names: [String] = []

    mutating func of(_ song: BaseItem) -> String {
        let name = MusicKeys.lead(of: song)
        if let known = groupOf[name] { return known }
        let act = MusicKeys.act(of: song)
        let match = names.first { keys[$0]?.isDisjoint(with: act) == false || Self.sameAct(name, $0) }
        let group = match ?? name
        groupOf[name] = group
        keys[group, default: []].formUnion(act)
        if match == nil { names.append(group) }
        return group
    }

    /// One name is the other, with more after it at a word boundary. Long
    /// enough to be a name of its own: "Air" must not swallow "Air Supply".
    static func sameAct(_ a: String, _ b: String) -> Bool {
        let (short, long) = a.count <= b.count ? (a, b) : (b, a)
        guard short.count >= 8, long.count > short.count, long.hasPrefix(short) else { return false }
        let next = long[long.index(long.startIndex, offsetBy: short.count)]
        return !next.isLetter && !next.isNumber
    }
}

// MARK: - Choosing and ordering

@MainActor
enum StationRanker {
    struct Scored {
        var song: BaseItem
        var score: Double
        var alike: Bool
        /// Which act it counts as, for spacing and for the cap: see
        /// `ArtistGroups`.
        var artist: String
    }

    /// Every candidate scored: likeness to the seed, what this account has
    /// shown it thinks of the song, its artist and its genres, what it has
    /// done in *this* station so far, and a little luck. Songs the account
    /// has turned down are left out entirely.
    static func score(
        _ pool: [BaseItem], profile: MixProfile, session: StationSession? = nil,
        exclude: Set<String> = [], jitter: Double = 1.2
    ) -> [Scored] {
        let taste = MusicTaste.shared
        let now = Date()
        return pool.compactMap { song in
            guard !exclude.contains(song.Id), song.Id != profile.songId else { return nil }
            let lean = taste.lean(for: song, now: now)
            guard !lean.blocked else { return nil }
            let likeness = profile.likeness(song)
            var score = likeness + lean.score
            if likeness == 0 { score -= 4 }
            if let session { score += session.lean(for: song) }
            // Small nudges from the server's own record of the song, for an
            // account whose history is older than this app.
            if song.userData.isFavorite { score += 0.6 }
            score += min(0.6, log2(1 + Double(song.userData.PlayCount ?? 0)) * 0.15)
            score += Double.random(in: 0..<jitter)
            return Scored(song: song, score: score, alike: likeness > 0, artist: MusicKeys.lead(of: song))
        }
        .sorted { $0.score > $1.score }
    }

    /// The best `count`, dealt out in an order that flows: no artist again
    /// within three songs, no album twice running, no jump of decades from
    /// one song to the next when something closer scores nearly as well.
    /// `after` is what has played already, so the first pick follows on.
    static func sequence(
        _ scored: [Scored], count: Int, profile: MixProfile, after history: [BaseItem] = []
    ) -> [BaseItem] {
        guard count > 0 else { return [] }
        // Songs with something in common first; a thin station is topped up
        // with the nearest of the rest rather than ending after four songs.
        let floor = min(count, 20)
        var candidates = scored.filter(\.alike)
        if candidates.count < floor { candidates += scored.filter { !$0.alike }.prefix(floor - candidates.count) }

        // One grouping for the candidates and for what has already played, so
        // a band cannot follow itself under another billing.
        var acts = ArtistGroups()
        var group: [String: String] = [:]
        for c in candidates { group[c.song.Id] = acts.of(c.song) }
        for song in history { group[song.Id] = acts.of(song) }

        let cap = profile.isArtistStation ? max(4, count * 2 / 5) : max(3, count / 4)
        var perArtist: [String: Int] = [:]
        var pool: [Scored] = []
        var held: [Scored] = []
        for c in candidates where pool.count < count * 2 {
            let act = group[c.song.Id] ?? c.artist
            if perArtist[act, default: 0] < cap {
                perArtist[act, default: 0] += 1
                pool.append(c)
            } else {
                held.append(c)
            }
        }
        // The cap is for variety, not for a short station.
        if pool.count < floor { pool += held.prefix(floor - pool.count) }

        var recent = history.suffix(3).map { group[$0.Id] ?? MusicKeys.lead(of: $0) }
        var lastAlbum = history.last?.AlbumId
        var lastYear = history.last?.ProductionYear
        var lastGenres = Set(history.last.map(MusicKeys.genres) ?? [])
        var out: [BaseItem] = []
        while out.count < count, !pool.isEmpty {
            // Look a little way down the list, not the whole of it: the order
            // is still mostly best-first.
            let window = pool.prefix(8).indices
            var best = window.first!
            var bestValue = -Double.infinity
            for i in window {
                let c = pool[i]
                let act = group[c.song.Id] ?? c.artist
                var v = c.score
                // The artist just heard costs most; three songs back, least.
                if let at = recent.lastIndex(of: act) {
                    v -= [6.0, 3, 1.5][min(2, recent.count - 1 - at)]
                }
                if let album = c.song.AlbumId, album == lastAlbum { v -= 2 }
                if let a = lastYear, let b = c.song.ProductionYear, abs(a - b) > 20 {
                    v -= 0.8 * min(1, Double(abs(a - b) - 20) / 20)
                }
                if !lastGenres.isDisjoint(with: MusicKeys.genres(of: c.song)) { v += 0.3 }
                if v > bestValue { bestValue = v; best = i }
            }
            let pick = pool.remove(at: best)
            out.append(pick.song)
            recent.append(group[pick.song.Id] ?? pick.artist)
            if recent.count > 3 { recent.removeFirst() }
            lastAlbum = pick.song.AlbumId
            lastYear = pick.song.ProductionYear ?? lastYear
            lastGenres = Set(MusicKeys.genres(of: pick.song))
        }
        return out
    }
}
