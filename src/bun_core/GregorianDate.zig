const GregorianDate = @This();

year: i64,
month: u4,
day: u5,
weekday: u3,

pub fn fromDaysSinceUnixEpoch(days_since_epoch: i64) GregorianDate {
    const shifted = days_since_epoch + 719_468;
    const era = @divFloor(shifted, 146_097);
    const day_of_era = shifted - era * 146_097;
    const year_of_era = @divTrunc(
        day_of_era - @divTrunc(day_of_era, 1_460) + @divTrunc(day_of_era, 36_524) - @divTrunc(day_of_era, 146_096),
        365,
    );
    var year = year_of_era + era * 400;
    const day_of_year = day_of_era - (365 * year_of_era + @divTrunc(year_of_era, 4) - @divTrunc(year_of_era, 100));
    const march_month = @divTrunc(5 * day_of_year + 2, 153);
    const day = day_of_year - @divTrunc(153 * march_month + 2, 5) + 1;
    const month = march_month + (if (march_month < 10) @as(i64, 3) else -9);
    if (month <= 2) year += 1;
    return .{
        .year = year,
        .month = @intCast(month),
        .day = @intCast(day),
        .weekday = @intCast(@mod(days_since_epoch + 4, 7)),
    };
}
