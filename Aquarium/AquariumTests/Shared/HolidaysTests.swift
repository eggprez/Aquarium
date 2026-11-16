//  `Holiday`: when each holiday the seasonal app icons belong to falls, and
//  the two-month window around it in which its icon is offered.
//
//  Dates are the start of the day in this device's time zone, as the app
//  works them out, so the expectations are built the same way.

import XCTest
@testable import Aquarium

final class HolidaysTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .current
        return c
    }

    private func day(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0, minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func daysApart(_ a: Date, _ b: Date) -> Int {
        abs(calendar.dateComponents([.day], from: a, to: b).day ?? .max)
    }

    func testEveryHolidayIsListed() {
        XCTAssertEqual(Holiday.allCases.count, 37)
        XCTAssertEqual(Holiday.windowDays, 30)
        XCTAssertEqual(Set(Holiday.allCases.map(\.rawValue)).count, 37)
    }

    func testFixedDates() {
        let fixed: [(Holiday, Int, Int)] = [
            (.newYear, 1, 1), (.burnsNight, 1, 25), (.valentine, 2, 14), (.stPatrick, 3, 17), (.nowruz, 3, 20),
            (.vaisakhi, 4, 14), (.earthDay, 4, 22), (.repubblica, 6, 2), (.canadaDay, 7, 1), (.fourthOfJuly, 7, 4),
            (.bastilleDay, 7, 14), (.vivaMexico, 9, 16), (.halloween, 10, 31), (.diaDeMuertos, 11, 2),
            (.bonfireNight, 11, 5), (.christmas, 12, 25), (.kwanzaa, 12, 26),
        ]
        for year in [2024, 2026, 2031] {
            for (holiday, month, dayOfMonth) in fixed {
                XCTAssertEqual(holiday.dates(in: year), [day(year, month, dayOfMonth)], "\(holiday) \(year)")
            }
        }
    }

    func testDatesThatMoveWithTheWeek() {
        XCTAssertEqual(Holiday.mothersDay.dates(in: 2025), [day(2025, 5, 11)], "second Sunday of May")
        XCTAssertEqual(Holiday.mothersDay.dates(in: 2026), [day(2026, 5, 10)])
        XCTAssertEqual(Holiday.fathersDay.dates(in: 2025), [day(2025, 6, 15)], "third Sunday of June")
        XCTAssertEqual(Holiday.fathersDay.dates(in: 2026), [day(2026, 6, 21)])
        XCTAssertEqual(Holiday.thanksgiving.dates(in: 2023), [day(2023, 11, 23)], "fourth Thursday of November")
        XCTAssertEqual(Holiday.thanksgiving.dates(in: 2025), [day(2025, 11, 27)])
        XCTAssertEqual(Holiday.thanksgiving.dates(in: 2026), [day(2026, 11, 26)])
        XCTAssertEqual(Holiday.midsummer.dates(in: 2025), [day(2025, 6, 20)], "the Friday between 19 and 25 June")
        XCTAssertEqual(Holiday.midsummer.dates(in: 2026), [day(2026, 6, 19)])
        XCTAssertEqual(Holiday.midsummer.dates(in: 2027), [day(2027, 6, 25)])
        XCTAssertEqual(Holiday.oktoberfest.dates(in: 2025), [day(2025, 9, 20)], "opens on the first Saturday from 16 September")
        XCTAssertEqual(Holiday.oktoberfest.dates(in: 2026), [day(2026, 9, 19)])
        XCTAssertEqual(Holiday.oktoberfest.dates(in: 2028), [day(2028, 9, 16)])
    }

    func testKingsDayMovesOffASunday() {
        XCTAssertEqual(Holiday.kingsDay.dates(in: 2025), [day(2025, 4, 26)], "27 April 2025 is a Sunday")
        XCTAssertEqual(Holiday.kingsDay.dates(in: 2026), [day(2026, 4, 27)])
        XCTAssertEqual(Holiday.kingsDay.dates(in: 2031), [day(2031, 4, 26)])
    }

    func testEasterIsKeptOnBothCalendars() {
        XCTAssertEqual(Holiday.easter.dates(in: 2024), [day(2024, 3, 31), day(2024, 5, 5)])
        XCTAssertEqual(Holiday.easter.dates(in: 2025), [day(2025, 4, 20), day(2025, 4, 20)], "the two coincide in 2025")
        XCTAssertEqual(Holiday.easter.dates(in: 2026), [day(2026, 4, 5), day(2026, 4, 12)])
        XCTAssertEqual(Holiday.easter.dates(in: 2027), [day(2027, 3, 28), day(2027, 5, 2)])
        XCTAssertEqual(Holiday.easter.dates(in: 2038), [day(2038, 4, 25), day(2038, 4, 25)], "the latest Easter there is")
    }

    func testMardiGrasIsFortySevenDaysBeforeEaster() {
        XCTAssertEqual(Holiday.mardiGras.dates(in: 2024), [day(2024, 2, 13)])
        XCTAssertEqual(Holiday.mardiGras.dates(in: 2025), [day(2025, 3, 4)])
        XCTAssertEqual(Holiday.mardiGras.dates(in: 2026), [day(2026, 2, 17)])
    }

    func testHebrewFestivals() {
        XCTAssertEqual(Holiday.roshHashanah.dates(in: 2025), [day(2025, 9, 23)])
        XCTAssertEqual(Holiday.roshHashanah.dates(in: 2026), [day(2026, 9, 12)])
        XCTAssertEqual(Holiday.hanukkah.dates(in: 2024), [day(2024, 12, 26)])
        XCTAssertEqual(Holiday.hanukkah.dates(in: 2025), [day(2025, 12, 15)])
        XCTAssertEqual(Holiday.hanukkah.dates(in: 2026), [day(2026, 12, 5)])
        XCTAssertEqual(Holiday.passover.dates(in: 2024), [day(2024, 4, 23)])
        XCTAssertEqual(Holiday.passover.dates(in: 2025), [day(2025, 4, 13)])
        XCTAssertEqual(Holiday.passover.dates(in: 2026), [day(2026, 4, 2)])
        XCTAssertEqual(Holiday.purim.dates(in: 2025), [day(2025, 3, 14)])
        XCTAssertEqual(Holiday.purim.dates(in: 2026), [day(2026, 3, 3)])
        XCTAssertEqual(Holiday.purim.dates(in: 2024), [day(2024, 3, 24)], "in a leap year Purim is kept in the second Adar")
    }

    func testChineseFestivals() {
        XCTAssertEqual(Holiday.lunarNewYear.dates(in: 2024), [day(2024, 2, 10)])
        XCTAssertEqual(Holiday.lunarNewYear.dates(in: 2025), [day(2025, 1, 29)])
        XCTAssertEqual(Holiday.lunarNewYear.dates(in: 2026), [day(2026, 2, 17)])
        XCTAssertEqual(Holiday.midAutumn.dates(in: 2025), [day(2025, 10, 6)], "2025 has a leap sixth month before it")
        XCTAssertEqual(Holiday.midAutumn.dates(in: 2026), [day(2026, 9, 25)])
        XCTAssertEqual(Holiday.vesak.dates(in: 2025), [day(2025, 5, 12)])
        XCTAssertEqual(Holiday.vesak.dates(in: 2026), [day(2026, 5, 31)])
    }

    /// The Islamic months begin on a sighting; a day either way is expected.
    func testIslamicFestivalsToWithinADay() throws {
        let expected: [(Holiday, Int, Date)] = [
            (.ramadan, 2025, day(2025, 3, 1)), (.ramadan, 2026, day(2026, 2, 18)),
            (.eidAlFitr, 2025, day(2025, 3, 30)), (.eidAlFitr, 2026, day(2026, 3, 20)),
            (.eidAlAdha, 2025, day(2025, 6, 6)), (.eidAlAdha, 2026, day(2026, 5, 27)),
        ]
        for (holiday, year, date) in expected {
            let dates = holiday.dates(in: year)
            XCTAssertEqual(dates.count, 1, "\(holiday) \(year)")
            let found = try XCTUnwrap(dates.first, "\(holiday) \(year)")
            XCTAssertLessThanOrEqual(daysApart(found, date), 1, "\(holiday) \(year): \(found)")
        }
    }

    func testAFestivalCanFallTwiceInOneYear() {
        // The Islamic year is eleven days short of ours: Ramadan begins in
        // January 2030 and again in December.
        let dates = Holiday.ramadan.dates(in: 2030)
        XCTAssertEqual(dates.count, 2)
        XCTAssertEqual(dates.map { calendar.component(.month, from: $0) }, [1, 12])
        XCTAssertEqual(dates, dates.sorted())
    }

    /// Found from the mean moon, which is within a day of the true one.
    func testHoliAndDiwaliFollowTheMoon() throws {
        let expected: [(Holiday, Int, Date)] = [
            (.holi, 2025, day(2025, 3, 14)), (.holi, 2026, day(2026, 3, 3)),
            (.diwali, 2025, day(2025, 10, 21)), (.diwali, 2026, day(2026, 11, 9)),
        ]
        for (holiday, year, date) in expected {
            let dates = holiday.dates(in: year)
            XCTAssertEqual(dates.count, 1, "\(holiday) \(year)")
            let found = try XCTUnwrap(dates.first, "\(holiday) \(year)")
            XCTAssertLessThanOrEqual(daysApart(found, date), 1, "\(holiday) \(year): \(found)")
        }
    }

    func testEveryHolidayFallsInEveryYearAndInThatYear() {
        for year in 2020...2045 {
            for holiday in Holiday.allCases {
                let dates = holiday.dates(in: year)
                XCTAssertFalse(dates.isEmpty, "\(holiday) has no date in \(year)")
                XCTAssertLessThanOrEqual(dates.count, 2, "\(holiday) \(year)")
                for date in dates {
                    XCTAssertEqual(calendar.component(.year, from: date), year, "\(holiday) \(year)")
                    XCTAssertEqual(date, calendar.startOfDay(for: date), "\(holiday) \(year) is the start of a day")
                }
            }
        }
    }

    // MARK: The window

    func testTheWindowRunsAMonthEitherSideOfTheDay() throws {
        let window = try XCTUnwrap(Holiday.christmas.window(around: day(2026, 12, 1)))
        XCTAssertEqual(window.lowerBound, day(2026, 11, 25))
        XCTAssertEqual(window.upperBound, day(2027, 1, 25), "thirty days after, to the end of that day")

        XCTAssertNil(Holiday.christmas.window(around: day(2026, 11, 24, hour: 23, minute: 59)))
        XCTAssertNotNil(Holiday.christmas.window(around: day(2026, 11, 25)))
        XCTAssertNotNil(Holiday.christmas.window(around: day(2026, 12, 25, hour: 12)))
        XCTAssertNotNil(Holiday.christmas.window(around: day(2027, 1, 24, hour: 23, minute: 59)))
        XCTAssertNil(Holiday.christmas.window(around: day(2027, 1, 25, minute: 1)))
        XCTAssertNil(Holiday.christmas.window(around: day(2026, 7, 1)))
    }

    func testTheWindowReachesAcrossTheNewYear() throws {
        let afterChristmas = try XCTUnwrap(Holiday.christmas.window(around: day(2027, 1, 10)))
        XCTAssertEqual(afterChristmas.lowerBound, day(2026, 11, 25), "last year's Christmas")
        let beforeNewYear = try XCTUnwrap(Holiday.newYear.window(around: day(2026, 12, 15)))
        XCTAssertEqual(beforeNewYear.lowerBound, day(2026, 12, 2), "next year's New Year")
        XCTAssertEqual(beforeNewYear.upperBound, day(2027, 2, 1))
    }

    func testEveryHolidayIsInItsOwnWindowOnTheDay() {
        for holiday in Holiday.allCases {
            for date in holiday.dates(in: 2027) {
                XCTAssertNotNil(holiday.window(around: date.addingTimeInterval(12 * 3600)), "\(holiday)")
            }
        }
    }

    func testWhichIconsAreOfferedOnAGivenDay() {
        func offered(_ date: Date) -> Set<Holiday> {
            Set(Holiday.allCases.filter { $0.window(around: date) != nil })
        }
        XCTAssertEqual(offered(day(2026, 11, 14, hour: 12)),
                       [.halloween, .diaDeMuertos, .bonfireNight, .diwali, .thanksgiving, .hanukkah])
        XCTAssertEqual(offered(day(2026, 8, 13, hour: 12)), [.bastilleDay, .roshHashanah],
                       "high summer: Bastille Day on its last day, the Jewish new year on its first")
        XCTAssertEqual(offered(day(2026, 8, 15, hour: 12)), [.roshHashanah])
    }
}
