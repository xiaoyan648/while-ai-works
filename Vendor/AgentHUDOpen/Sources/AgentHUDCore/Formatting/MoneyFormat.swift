import Foundation

public enum MoneyFormat {
    /// A balance or an estimate, with the currency's symbol in the app's language: "$12.99", or up to six decimals for
    /// an estimate.
    public static func amount(_ amount: Decimal, currency: String, estimated: Bool = false) -> String {
        let format = Decimal.FormatStyle.Currency(code: currency)
            .presentation(.narrow)
            .locale(Locale(identifier: L10n.resolved == .zhHans ? "zh_CN" : "en_US"))
            .precision(.fractionLength(2...(estimated ? 6 : 2)))
        let minimum = Decimal(string: "0.000001")!
        if estimated, amount > 0, amount < minimum {
            return "<" + minimum.formatted(format)
        }
        return amount.formatted(format)
    }

    /// A price someone pays, written as the website writes it in either language: the ISO code, a space and two
    /// decimals, such as "USD 2.99". The number is grouped and rounded as `Intl.NumberFormat` does in English, whatever
    /// the Mac's region, and the space is a plain one.
    public static func price(_ amount: Decimal, currency: String) -> String {
        let format = Decimal.FormatStyle(locale: Locale(identifier: "en_US"))
            .precision(.fractionLength(2)).rounded(rule: .toNearestOrAwayFromZero)
        return (amount < 0 ? "-" : "") + currency + " " + abs(amount).formatted(format)
    }
}
