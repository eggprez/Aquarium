//  The holidays the seasonal app icons belong to, and when each one falls.
//
//  An icon is offered from a month before its holiday to a month after — see
//  `Holiday.window(around:)` and `AppIconChoice.seasonal`. Dates come from the
//  calendar each holiday is kept by: Foundation's Hebrew, Islamic (Umm al-Qura)
//  and Chinese calendars for those festivals, the Computus for Easter, and the
//  moon for the Hindu ones Foundation has no calendar for. A day either way
//  (the Islamic months begin on a sighting, the Hebrew festivals at dusk) is
//  lost in a two-month window.

import Foundation

enum Holiday: String, CaseIterable, Sendable {
    // Civic and national
    case newYear, burnsNight, valentine, mardiGras, stPatrick, earthDay, kingsDay, mothersDay
    case repubblica, fathersDay, midsummer, canadaDay, fourthOfJuly, bastilleDay, vivaMexico
    case oktoberfest, halloween, bonfireNight, thanksgiving, christmas
    // Faith and culture
    case lunarNewYear, purim, nowruz, ramadan, eidAlFitr, holi, passover, easter, vaisakhi
    case vesak, eidAlAdha, roshHashanah, midAutumn, diaDeMuertos, diwali, hanukkah, kwanzaa

    /// How long before and after the day its icon is offered.
    static let windowDays = 30

    /// The day (or days — Easter is kept on two) the holiday falls in a
    /// Gregorian year, as the start of that day here.
    func dates(in year: Int) -> [Date] {
        switch self {
        case .newYear: [Self.day(year, 1, 1)]
        case .burnsNight: [Self.day(year, 1, 25)]
        case .valentine: [Self.day(year, 2, 14)]
        case .mardiGras: [Self.westernEaster(year).adding(days: -47)]
        case .stPatrick: [Self.day(year, 3, 17)]
        case .nowruz: [Self.day(year, 3, 20)]
        case .earthDay: [Self.day(year, 4, 22)]
        case .vaisakhi: [Self.day(year, 4, 14)]
        case .kingsDay: [Self.kingsDay(year)]
        case .mothersDay: [Self.nth(2, weekday: 1, month: 5, year: year)]
        case .repubblica: [Self.day(year, 6, 2)]
        case .fathersDay: [Self.nth(3, weekday: 1, month: 6, year: year)]
        case .midsummer: [Self.firstWeekday(6, onOrAfter: Self.day(year, 6, 19))]  // Friday 19–25 June
        case .canadaDay: [Self.day(year, 7, 1)]
        case .fourthOfJuly: [Self.day(year, 7, 4)]
        case .bastilleDay: [Self.day(year, 7, 14)]
        case .vivaMexico: [Self.day(year, 9, 16)]
        case .oktoberfest: [Self.firstWeekday(7, onOrAfter: Self.day(year, 9, 16))]  // opens on a Saturday
        case .halloween: [Self.day(year, 10, 31)]
        case .diaDeMuertos: [Self.day(year, 11, 2)]
        case .bonfireNight: [Self.day(year, 11, 5)]
        case .thanksgiving: [Self.nth(4, weekday: 5, month: 11, year: year)]
        case .christmas: [Self.day(year, 12, 25)]
        case .kwanzaa: [Self.day(year, 12, 26)]
        case .easter: [Self.westernEaster(year), Self.orthodoxEaster(year)]
        case .lunarNewYear: Self.chinese(month: 1, day: 1, year: year)
        case .midAutumn: Self.chinese(month: 8, day: 15, year: year)
        case .vesak: Self.chinese(month: 4, day: 15, year: year)
        // Hebrew months as Foundation numbers them: Tishrei is 1, Kislev 3,
        // Adar (Adar II in a leap year) 7, Nisan 8.
        case .roshHashanah: Self.hebrew(month: 1, day: 1, year: year)
        case .hanukkah: Self.hebrew(month: 3, day: 25, year: year)
        case .purim: Self.hebrew(month: 7, day: 14, year: year)
        case .passover: Self.hebrew(month: 8, day: 15, year: year)
        case .ramadan: Self.islamic(month: 9, day: 1, year: year)
        case .eidAlFitr: Self.islamic(month: 10, day: 1, year: year)
        case .eidAlAdha: Self.islamic(month: 12, day: 10, year: year)
        // Holi is the full moon of Phalguna, Diwali the new moon of Kartika.
        case .holi: Self.moon(full: true, from: Self.day(year, 2, 24), to: Self.day(year, 3, 26))
        case .diwali: Self.moon(full: false, from: Self.day(year, 10, 16), to: Self.day(year, 11, 15))
        }
    }

    /// The window around the nearest occurrence that contains `date`, if any.
    func window(around date: Date = .now) -> ClosedRange<Date>? {
        let year = Self.gregorian.component(.year, from: date)
        return (year - 1 ... year + 1)
            .flatMap(dates(in:))
            .map { $0.adding(days: -Self.windowDays) ... $0.adding(days: Self.windowDays + 1) }
            .first { $0.contains(date) }
    }

    // MARK: - Calendars

    private static var gregorian: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .current
        return c
    }

    private static func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        gregorian.date(from: DateComponents(year: year, month: month, day: day))!
    }

    /// The `n`th `weekday` (1 = Sunday) of a month.
    private static func nth(_ n: Int, weekday: Int, month: Int, year: Int) -> Date {
        firstWeekday(weekday, onOrAfter: day(year, month, 1)).adding(days: 7 * (n - 1))
    }

    private static func firstWeekday(_ weekday: Int, onOrAfter date: Date) -> Date {
        let offset = (weekday - gregorian.component(.weekday, from: date) + 7) % 7
        return date.adding(days: offset)
    }

    /// 27 April, or the Saturday before when that's a Sunday.
    private static func kingsDay(_ year: Int) -> Date {
        let d = day(year, 4, 27)
        return gregorian.component(.weekday, from: d) == 1 ? d.adding(days: -1) : d
    }

    /// Anonymous Gregorian algorithm.
    private static func westernEaster(_ y: Int) -> Date {
        let a = y % 19, b = y / 100, c = y % 100, d = b / 4, e = b % 4
        let f = (b + 8) / 25, g = (b - f + 1) / 3, h = (19 * a + b - d - g + 15) % 30
        let i = c / 4, k = c % 4, l = (32 + 2 * e + 2 * i - h - k) % 7
        let m = (a + 11 * h + 22 * l) / 451
        let month = (h + l - 7 * m + 114) / 31, dayOfMonth = (h + l - 7 * m + 114) % 31 + 1
        return day(y, month, dayOfMonth)
    }

    /// Meeus's Julian algorithm, moved onto the Gregorian calendar (13 days
    /// this century and next).
    private static func orthodoxEaster(_ y: Int) -> Date {
        let a = y % 4, b = y % 7, c = y % 19
        let d = (19 * c + 15) % 30, e = (2 * a + 4 * b - d + 34) % 7
        let month = (d + e + 114) / 31, dayOfMonth = (d + e + 114) % 31 + 1
        return day(y, month, dayOfMonth).adding(days: y / 100 - y / 400 - 2)
    }

    /// Every date in the Gregorian `year` that is `month`/`day` of the other
    /// calendar — found by converting the days either side of it, since the
    /// other calendar's year straddles ours.
    private static func other(_ id: Calendar.Identifier, month: Int, day dayOfMonth: Int, year: Int,
                              leap: Bool? = nil) -> [Date] {
        var cal = Calendar(identifier: id)
        cal.timeZone = .current
        let probes = [day(year, 1, 1), day(year, 7, 1), day(year, 12, 31)]
        let found = probes.compactMap { probe -> Date? in
            var dc = cal.dateComponents([.era, .year], from: probe)
            dc.month = month
            dc.day = dayOfMonth
            dc.isLeapMonth = leap
            return cal.date(from: dc).map { gregorian.startOfDay(for: $0) }
        }
        return Array(Set(found)).filter { gregorian.component(.year, from: $0) == year }.sorted()
    }

    private static func hebrew(month: Int, day: Int, year: Int) -> [Date] {
        other(.hebrew, month: month, day: day, year: year)
    }

    private static func islamic(month: Int, day: Int, year: Int) -> [Date] {
        other(.islamicUmmAlQura, month: month, day: day, year: year)
    }

    private static func chinese(month: Int, day: Int, year: Int) -> [Date] {
        other(.chinese, month: month, day: day, year: year, leap: false)
    }

    /// The mean new or full moon between two dates — within a day of the true
    /// one, which is all a two-month window needs.
    private static func moon(full: Bool, from start: Date, to end: Date) -> [Date] {
        let synodic = 29.530588861
        let jd = { (d: Date) in d.timeIntervalSince1970 / 86400 + 2440587.5 }
        var k = ((jd(start) - 2451550.09766) / synodic).rounded(.down) - 1 + (full ? 0.5 : 0)
        while true {
            let when = 2451550.09766 + synodic * k
            let date = Date(timeIntervalSince1970: (when - 2440587.5) * 86400)
            if date > end { return [] }
            if date >= start { return [gregorian.startOfDay(for: date)] }
            k += 1
        }
    }
}

private extension Date {
    func adding(days: Int) -> Date {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .current
        return c.date(byAdding: .day, value: days, to: self)!
    }
}
