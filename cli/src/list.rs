//! `list`: one folder of backed-up files (spec §9 `ListDir`), all pages.
//!
//! ```text
//!  ListDir(device, path, start_after = "", max 1000) ─► DirEntries
//!     print each entry; has_more → ListDir again after the last name
//! ```
//!
//! Output, one line per entry, sorted by name byte-wise (the server's order):
//! `d <name>/` for a folder, `f <name>  <size>  <mtime>  v<version>` for a
//! file (two spaces between columns; mtime in UTC, ISO 8601).

use anyhow::bail;
use haotrannas_core::limits::MAX_LIST_DIR_ENTRIES;
use haotrannas_core::message::{DirEntry, DirEntryKind, Message};
use haotrannas_core::path_rules::validate_path;

use crate::connection::{Transport, open_connection, unexpected_reply};

/// Device name the cli gives in `Hello`.
const CLI_DEVICE_NAME: &str = "haotrannas-cli";

/// What the person asked for.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ListRequest {
    /// 0 = this device.
    pub device_id: u64,
    /// "" = the root.
    pub path: String,
}

/// Lists the folder, printing each entry on stdout as its page arrives.
/// Returns how many entries were printed.
pub async fn run_list(
    server_address: &str,
    transport: &Transport,
    request: &ListRequest,
) -> anyhow::Result<usize> {
    if !request.path.is_empty()
        && let Err(path_error) = validate_path(&request.path)
    {
        bail!("bad remote path {:?}: {path_error}", request.path);
    }
    let mut connection = open_connection(server_address, transport, CLI_DEVICE_NAME).await?;
    let mut start_after = String::new();
    let mut entry_count = 0;
    loop {
        let list_dir = Message::ListDir {
            device_id: request.device_id,
            path: request.path.clone(),
            start_after: start_after.clone(),
            max_entries: MAX_LIST_DIR_ENTRIES,
        };
        let (entries, has_more) = match connection.request(&list_dir).await? {
            Message::DirEntries { entries, has_more } => (entries, has_more),
            other => return Err(unexpected_reply(&other).into()),
        };
        for entry in &entries {
            if entry.name.as_str() <= start_after.as_str() {
                bail!(
                    "server listed {:?} after {start_after:?} (not sorted)",
                    entry.name
                );
            }
            println!("{}", entry_line(entry));
            start_after.clone_from(&entry.name);
        }
        entry_count += entries.len();
        if !has_more {
            break;
        }
        if entries.is_empty() {
            bail!("server said more entries follow but sent none");
        }
    }
    connection.close().await;
    Ok(entry_count)
}

/// `d name/` or `f name  size  mtime  v<id>`.
fn entry_line(entry: &DirEntry) -> String {
    match entry.kind {
        DirEntryKind::Directory => format!("d {}/", entry.name),
        DirEntryKind::File => format!(
            "f {}  {}  {}  v{}",
            entry.name,
            entry.size_bytes,
            utc_time_text(entry.modified_time_ms),
            entry.version_id
        ),
    }
}

/// `2024-01-31T09:05:07Z` for ms since the Unix epoch (UTC, whole seconds).
fn utc_time_text(unix_time_ms: i64) -> String {
    const SECONDS_PER_DAY: i64 = 86_400;
    let unix_seconds = unix_time_ms.div_euclid(1000);
    let day_number = unix_seconds.div_euclid(SECONDS_PER_DAY);
    let second_of_day = unix_seconds.rem_euclid(SECONDS_PER_DAY);
    let (year, month, day) = civil_date_from_day_number(day_number);
    format!(
        "{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}Z",
        second_of_day / 3600,
        second_of_day % 3600 / 60,
        second_of_day % 60
    )
}

/// (year, month 1..=12, day 1..=31) for days since 1970-01-01, proleptic
/// Gregorian calendar (Howard Hinnant's `civil_from_days`).
fn civil_date_from_day_number(day_number: i64) -> (i64, i64, i64) {
    let shifted_days = day_number + 719_468;
    let era = shifted_days.div_euclid(146_097);
    let day_of_era = shifted_days.rem_euclid(146_097);
    let year_of_era =
        (day_of_era - day_of_era / 1460 + day_of_era / 36_524 - day_of_era / 146_096) / 365;
    let day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
    let month_from_march = (5 * day_of_year + 2) / 153;
    let day = day_of_year - (153 * month_from_march + 2) / 5 + 1;
    let month = if month_from_march < 10 {
        month_from_march + 3
    } else {
        month_from_march - 9
    };
    let year = year_of_era + era * 400 + i64::from(month <= 2);
    (year, month, day)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn entry_lines() {
        let folder = DirEntry {
            name: "photos".to_owned(),
            kind: DirEntryKind::Directory,
            size_bytes: 0,
            modified_time_ms: 0,
            version_id: 0,
        };
        assert_eq!(entry_line(&folder), "d photos/");
        let file = DirEntry {
            name: "a b.jpg".to_owned(),
            kind: DirEntryKind::File,
            size_bytes: 1234,
            modified_time_ms: 1_706_691_907_999,
            version_id: 42,
        };
        assert_eq!(
            entry_line(&file),
            "f a b.jpg  1234  2024-01-31T09:05:07Z  v42"
        );
    }

    #[test]
    fn utc_times() {
        assert_eq!(utc_time_text(0), "1970-01-01T00:00:00Z");
        assert_eq!(utc_time_text(951_782_400_000), "2000-02-29T00:00:00Z");
        assert_eq!(utc_time_text(-1), "1969-12-31T23:59:59Z");
        assert_eq!(utc_time_text(4_102_444_800_000), "2100-01-01T00:00:00Z");
    }
}
