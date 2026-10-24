import Foundation
import XCTest
@testable import IslandCore

final class CurrencyTests: XCTestCase {
    let ratesJSON = #"[{"date":"2026-10-25","base":"EUR","quote":"USD","rate":1.08},{"date":"2026-10-23","base":"EUR","quote":"INR","rate":106.272},{"date":"2026-10-24","base":"EUR","quote":"JPY","rate":175.51}]"#
    let currenciesJSON = #"[{"iso_code":"INR","name":"Indian Rupee","symbol":"₹"},{"iso_code":"USD","name":"United States Dollar","symbol":"$"}]"#

    var rates: ExchangeRates {
        var rates = ExchangeRates.parseRates(Data(ratesJSON.utf8))!
        let extra = ExchangeRates.parseCurrencies(Data(currenciesJSON.utf8))
        rates.names = extra.names
        rates.symbols = extra.symbols
        return rates
    }

    func testParsesRatesAndNewestDate() {
        XCTAssertEqual(rates.base, "EUR")
        XCTAssertEqual(rates.rates["INR"], 106.272)
        XCTAssertEqual(rates.date, "2026-10-25")
        XCTAssertEqual(rates.name("inr"), "Indian Rupee")
        XCTAssertNil(ExchangeRates.parseRates(Data("[]".utf8)))
    }

    func testCrossRatesGoThroughTheBase() throws {
        XCTAssertEqual(try XCTUnwrap(rates.convert(1, from: "EUR", to: "USD")), 1.08, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(rates.convert(100, from: "USD", to: "INR")), 100 / 1.08 * 106.272, accuracy: 1e-6)
        XCTAssertNil(rates.convert(1, from: "USD", to: "XXX"))
        XCTAssertEqual(rates.codes.prefix(3), ["USD", "EUR", "INR"])
    }

    func testParsesTypedConversions() throws {
        let a = try XCTUnwrap(rates.parse("100 usd to inr"))
        XCTAssertEqual(a.amount, 100)
        XCTAssertEqual(a.from, "USD")
        XCTAssertEqual(a.to, "INR")
        let b = try XCTUnwrap(rates.parse("$20 in €"))
        XCTAssertEqual(b.from, "USD")
        XCTAssertEqual(b.to, "EUR")
        let c = try XCTUnwrap(rates.parse("2,500 rupees"))
        XCTAssertEqual(c.amount, 2500)
        XCTAssertEqual(c.from, "INR")
        XCTAssertNil(c.to)
        XCTAssertNil(rates.parse("5 km to mi"))
    }

    func testFormatsWithSymbols() {
        XCTAssertEqual(rates.format(8312.4, "INR"), "₹8,312")
        XCTAssertEqual(rates.format(12.5, "USD"), "$12.50")
        XCTAssertEqual(rates.format(3, "JPY"), "3.00 JPY")
    }
}
