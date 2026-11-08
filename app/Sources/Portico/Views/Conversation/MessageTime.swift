import SwiftUI

/// v0.25 §3 (PORT-13, ZE2): a message's date and time, beside Copy on hover.
/// Today is the time only; yesterday says so; earlier this year is the day
/// and time; an earlier year adds the year. The tooltip is the full date and
/// time. When there's no real time, nothing is shown: a wrong time is worse
/// than none.
enum MessageTime {
    /// "3:42 PM", "Yesterday 3:42 PM", "Nov 6, 3:42 PM", "Nov 6, 2025, 3:42 PM" (en_US).
    static func short(_ date: Date, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String {
        let time = plain(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar, timeZone: calendar.timeZone).format(date))
        if calendar.isDate(date, inSameDayAs: now) { return time }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            let relative = DateFormatter()
            relative.locale = locale
            relative.calendar = calendar
            relative.timeZone = calendar.timeZone
            relative.doesRelativeDateFormatting = true
            relative.dateStyle = .medium
            relative.timeStyle = .none
            return "\(relative.string(from: date)) \(time)"
        }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        // The locale's short day ("Nov 6", "6 Nov"), a comma, then its time:
        // the system's own joiners read "Nov 6 at 3:42 PM", longer than ZE2's.
        return "\(SessionTime.day(date, withYear: !sameYear, calendar: calendar, locale: locale)), \(time)"
    }

    /// "Friday, November 6, 2026 at 3:42:10 PM" (en_US).
    static func full(_ date: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        template("EEEEMMMMdy jmmss", date, calendar: calendar, locale: locale)
    }

    /// The time to show for a message, or nil. `noTime` is the gateway's
    /// word that no transcript entry matched. A replayed (`fromHistory`)
    /// time counts only from a gateway that lists `history.times.v1`
    /// (`gatewayTimes`): an older one stamps its replay with today's time.
    static func shown(_ ts: String, noTime: Bool?, fromHistory: Bool, gatewayTimes: Bool) -> Date? {
        if noTime == true { return nil }
        if fromHistory && !gatewayTimes { return nil }
        return SessionTime.parse(ts)
    }

    private static func template(_ skeleton: String, _ date: Date, calendar: Calendar, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate(skeleton)
        return plain(formatter.string(from: date))
    }

    /// The narrow no-break space some locales put before AM/PM becomes a plain one, as `SessionTime.clock` does.
    private static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{202F}", with: " ")
    }
}

/// The row under a message while the pointer is on it (ZE2): its time in
/// secondary text, with the full date and time as a tooltip, then Copy, then
/// anything else the message offers (Read aloud). With no time, only the buttons.
struct MessageHoverRow<Extra: View>: View {
    let at: Date?
    let help: String
    let copy: () -> String
    @ViewBuilder var extra: Extra

    var body: some View {
        HStack(spacing: 2) {
            if let at {
                Text(MessageTime.short(at))
                    .scaledFont(11)
                    .foregroundStyle(Theme.text3)
                    .padding(.horizontal, 6)
                    .tip(MessageTime.full(at))
            }
            CopyButton(help: help, text: copy)
            extra
        }
    }
}

extension MessageHoverRow where Extra == EmptyView {
    init(at: Date?, help: String, copy: @escaping () -> String) {
        self.init(at: at, help: help, copy: copy) { EmptyView() }
    }
}
