//! 农历候选（`nl` 显示今天农历；`N` + 8 位公历日期转农历），移植自雾凇 `lua/lunar.lua`。
//!
//! 用 1900–2100 的标准农历编码表（每年一个 u32：闰月 + 每月大小 + 闰月大小）。
//! 输出格式对齐雾凇默认模板 `{干支年}{生肖}年{俗称农历月}{农历日}`。

use crate::datetime::LocalTime;

/// 每年农历数据， bit 16..=4 是 12（或 13）个月的大小（1=30 天），低 4 位是闰月号（0 无闰），
/// bit 16 是闰月大小。来源：通用的 lunarInfo 表（1900–2100）。
const LUNAR_INFO: &[u32] = &[
    0x04bd8,0x04ae0,0x0a570,0x054d5,0x0d260,0x0d950,0x16554,0x056a0,0x09ad0,0x055d2, // 1900-1909
    0x04ae0,0x0a5b6,0x0a4d0,0x0d250,0x1d255,0x0b540,0x0d6a0,0x0ada2,0x095b0,0x14977, // 1910-1919
    0x04970,0x0a4b0,0x0b4b5,0x06a50,0x06d40,0x1ab54,0x02b60,0x09570,0x052f2,0x04970, // 1920-1929
    0x06566,0x0d4a0,0x0ea50,0x06e95,0x05ad0,0x02b60,0x186e3,0x092e0,0x1c8d7,0x0c950, // 1930-1939
    0x0d4a0,0x1d8a6,0x0b550,0x056a0,0x1a5b4,0x025d0,0x092d0,0x0d2b2,0x0a950,0x0b557, // 1940-1949
    0x06ca0,0x0b550,0x15355,0x04da0,0x0a5d0,0x14573,0x052d0,0x0a9a8,0x0e950,0x06aa0, // 1950-1959
    0x0aea6,0x0ab50,0x04b60,0x0aae4,0x0a570,0x05260,0x0f263,0x0d950,0x05b57,0x056a0, // 1960-1969
    0x096d0,0x04dd5,0x04ad0,0x0a4d0,0x0d4d4,0x0d250,0x0d558,0x0b540,0x0b6a0,0x195a6, // 1970-1979
    0x095b0,0x049b0,0x0a974,0x0a4b0,0x0b27a,0x06a50,0x06d40,0x0af46,0x0ab60,0x09570, // 1980-1989
    0x04af5,0x04970,0x064b0,0x074a3,0x0ea50,0x06b58,0x055c0,0x0ab60,0x096d5,0x092e0, // 1990-1999
    0x0c960,0x0d954,0x0d4a0,0x0da50,0x07552,0x056a0,0x0abb7,0x025d0,0x092d0,0x0cab5, // 2000-2009
    0x0a950,0x0b4a0,0x0baa4,0x0ad50,0x055d9,0x04ba0,0x0a5b0,0x15176,0x052b0,0x0a930, // 2010-2019
    0x07954,0x06aa0,0x0ad50,0x05b52,0x04b60,0x0a6e6,0x0a4e0,0x0d260,0x0ea65,0x0d530, // 2020-2029
    0x05aa0,0x076a3,0x096d0,0x04afb,0x04ad0,0x0a4d0,0x1d0b6,0x0d250,0x0d520,0x0dd45, // 2030-2039
    0x0b5a0,0x056d0,0x055b2,0x049b0,0x0a577,0x0a4b0,0x0aa50,0x1b255,0x06d20,0x0ada0, // 2040-2049
    0x14b63,0x09370,0x049f8,0x04970,0x064b0,0x168a6,0x0ea50,0x06b20,0x1a6c4,0x0aae0, // 2050-2059
    0x0a2e0,0x0d2e3,0x0c960,0x0d557,0x0d4a0,0x0da50,0x05d55,0x056a0,0x0a6d0,0x055d4, // 2060-2069
    0x052d0,0x0a9b8,0x0a950,0x0b4a0,0x0b6a6,0x0ad50,0x055a0,0x0aba4,0x0a5b0,0x052b0, // 2070-2079
    0x0b273,0x06930,0x07337,0x06aa0,0x0ad50,0x14b55,0x04b60,0x0a570,0x054e4,0x0d160, // 2080-2089
    0x0e968,0x0d520,0x0daa0,0x16aa6,0x056d0,0x04ae0,0x0a9d4,0x0a2d0,0x0d150,0x0f252, // 2090-2099
    0x0d520, // 2100
];

const GAN: [&str; 10] = ["甲","乙","丙","丁","戊","己","庚","辛","壬","癸"];
const ZHI: [&str; 12] = ["子","丑","寅","卯","辰","巳","午","未","申","酉","戌","亥"];
const ZODIAC: [&str; 12] = ["鼠","牛","虎","兔","龙","蛇","马","羊","猴","鸡","狗","猪"];
const MONTHS: [&str; 12] = ["正","二","三","四","五","六","七","八","九","十","冬","腊"];
const DAYS: [&str; 30] = [
    "初一","初二","初三","初四","初五","初六","初七","初八","初九","初十",
    "十一","十二","十三","十四","十五","十六","十七","十八","十九","二十",
    "廿一","廿二","廿三","廿四","廿五","廿六","廿七","廿八","廿九","三十",
];
const WEEK: [&str; 7] = ["日","一","二","三","四","五","六"];

fn leap_month(y: u32) -> u32 { LUNAR_INFO[(y - 1900) as usize] & 0xF }
fn leap_days(y: u32) -> u32 {
    if leap_month(y) == 0 { 0 } else if LUNAR_INFO[(y - 1900) as usize] & 0x10000 != 0 { 30 } else { 29 }
}
fn month_days(y: u32, m: u32) -> u32 {
    if LUNAR_INFO[(y - 1900) as usize] & (0x10000 >> m) != 0 { 30 } else { 29 }
}
fn year_days(y: u32) -> u32 {
    let mut sum = 348; // 12 * 29
    for m in 1..=12 {
        if LUNAR_INFO[(y - 1900) as usize] & (0x10000 >> m) != 0 { sum += 1; }
    }
    sum + leap_days(y)
}

/// 公历 -> 农历 (年, 月, 日, 是否闰月)。
fn solar_to_lunar(y: i32, m: u32, d: u32) -> Option<(i32, u32, u32, bool)> {
    if !(1900..=2100).contains(&y) || !(1..=12).contains(&m) || d < 1 || d > 31 {
        return None;
    }
    // 以 1900-01-31（农历正月初一）为基准
    let mut offset = chrono_days(y, m, d) - chrono_days(1900, 1, 31);
    let mut ly = 1900u32;
    while ly <= 2100 && offset >= year_days(ly) as i64 {
        offset -= year_days(ly) as i64;
        ly += 1;
    }
    if ly > 2100 { return None; }
    let leap = leap_month(ly);
    let mut lm = 1u32;
    let mut is_leap = false;
    loop {
        let md = month_days(ly, lm) as i64;
        if offset < md { break; }
        offset -= md;
        // 正常月走完后，若这个月后面有闰月，先插入闰月
        if leap > 0 && lm == leap && !is_leap {
            let ld = leap_days(ly) as i64;
            if offset < ld { is_leap = true; break; }
            offset -= ld;
        }
        lm += 1;
        if lm > 12 { return None; }
    }
    Some((ly as i32, lm, offset as u32 + 1, is_leap))
}

/// 公历日期 -> 从 1970-01-01 起的天数（只用年月日，够农历换算）。
fn chrono_days(y: i32, m: u32, d: u32) -> i64 {
    let (yy, mm) = if m <= 2 { (y - 1, m + 12) } else { (y, m) };
    let era = if yy >= 0 { yy } else { yy - 399 } / 400;
    let yoe = yy - era * 400;
    let doy = (153 * (mm as i64 - 3) + 2) / 5 + d as i64 - 1;
    let doe = yoe as i64 * 365 + yoe as i64 / 4 - yoe as i64 / 100 + doy;
    era as i64 * 146097 + doe - 719468
}

/// `nl`：今天的农历；`N` + 8 位（YYYYMMDD）：指定日期的农历。
/// 返回候选字符串（干支年+生肖+月日+星期）。
pub fn candidates(input: &str, now: &LocalTime) -> Vec<String> {
    let (y, m, d) = if input == "nl" {
        (now.year, now.month, now.day)
    } else if let Some(rest) = input.strip_prefix('N') {
        if rest.len() != 8 || !rest.bytes().all(|b| b.is_ascii_digit()) {
            return Vec::new();
        }
        let y: i32 = rest[0..4].parse().unwrap_or(0);
        let m: u32 = rest[4..6].parse().unwrap_or(0);
        let d: u32 = rest[6..8].parse().unwrap_or(0);
        (y, m, d)
    } else {
        return Vec::new();
    };
    let Some((ly, lm, ld, is_leap)) = solar_to_lunar(y, m, d) else {
        return Vec::new();
    };
    let gan = GAN[((ly - 4) % 10) as usize];
    let zhi = ZHI[((ly - 4) % 12) as usize];
    let zodiac = ZODIAC[((ly - 4) % 12) as usize];
    let month = if is_leap { format!("闰{}", MONTHS[(lm - 1) as usize]) } else { MONTHS[(lm - 1) as usize].to_string() };
    let month = match month.as_str() { "腊" => "腊月".to_string(), "冬" => "冬月".to_string(), x => format!("{x}月") };
    let day = DAYS[(ld.saturating_sub(1) as usize).min(29)];
    let weekday = if input == "nl" { now.weekday as usize } else {
        // 公历日期算星期：1970-01-01 是周四
        (chrono_days(y, m, d).rem_euclid(7) + 4) as usize % 7
    };
    let week = WEEK[weekday];
    let main = format!("{gan}{zhi}{zodiac}年{month}{day}");
    vec![format!("{main} 星期{week}"), main]
}

#[cfg(test)]
mod tests {
    use super::*;
    fn now() -> LocalTime {
        LocalTime { year: 2026, month: 11, day: 21, hour: 12, minute: 0, second: 0, weekday: 6 }
    }
    #[test]
    fn nl() {
        let c = candidates("nl", &now());
        assert!(!c.is_empty());
        assert!(c[0].contains('年'));
    }
    #[test]
    fn n_date() {
        let c = candidates("N20261121", &now());
        assert!(!c.is_empty());
        assert_eq!(c, candidates("nl", &now()));
    }
    #[test]
    fn invalid() {
        assert!(candidates("N123", &now()).is_empty());
        assert!(candidates("nlx", &now()).is_empty());
    }
}
