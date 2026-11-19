//! Pairing codes (protocol spec §7): the admin opens a window with a random
//! `PAIRING_CODE_DIGITS`-digit code that lives `PAIRING_CODE_TTL_MS`; a
//! `PairRequest` is checked against it here.
//!
//! ```text
//!  admin `pair` ──► window open (new code, counters 0)
//!     right code          → used up (single use), window closed
//!     wrong code          → failures + 1; at MAX_PAIR_FAILURES_PER_WINDOW (10)
//!                           the window is locked: TOO_MANY_ATTEMPTS until it
//!                           would have expired (or the admin opens a new one)
//!     TTL over / no window → PAIRING_NOT_OPEN
//! ```
//!
//! The per-connection limit (3 wrong codes → fatal) is counted by the
//! session, see `handlers::pair`. The code is compared in constant time and
//! never logged or printed by `Debug`.

use std::fmt;
use std::net::IpAddr;
use std::sync::{Arc, Mutex, PoisonError};
use std::time::{Duration, Instant};

use haotrannas_core::limits::{MAX_PAIR_FAILURES_PER_WINDOW, PAIRING_CODE_DIGITS};

use crate::config::ServerConfig;
use crate::tls_identity::TlsIdentity;

/// The result of checking one offered code.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CodeCheck {
    /// Right code: the window is used up.
    Accepted,
    /// No window, or it expired → `PAIRING_NOT_OPEN`.
    NotOpen,
    /// Too many wrong codes in this window → `TOO_MANY_ATTEMPTS`.
    Locked,
    /// Wrong code → `BAD_PAIRING_CODE`.
    Wrong,
}

/// One open window.
struct OpenWindow {
    code: [u8; PAIRING_CODE_DIGITS],
    opened_at: Instant,
    failure_count: u32,
}

/// The one pairing window of a server (pure logic; the clock is passed in).
pub struct PairingWindow {
    code_ttl: Duration,
    open_window: Option<OpenWindow>,
}

impl fmt::Debug for PairingWindow {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("PairingWindow")
            .field("code_ttl", &self.code_ttl)
            .field("is_open", &self.open_window.is_some())
            .finish_non_exhaustive()
    }
}

impl PairingWindow {
    /// No window open yet; codes will live `code_ttl_ms`.
    pub fn new(code_ttl_ms: u64) -> Self {
        Self {
            code_ttl: Duration::from_millis(code_ttl_ms),
            open_window: None,
        }
    }

    /// Opens a new window with a fresh random code (replacing any open or
    /// locked one) and returns the code.
    pub fn open(&mut self, now: Instant) -> String {
        let code = random_code();
        self.open_window = Some(OpenWindow {
            code: code_bytes(&code),
            opened_at: now,
            failure_count: 0,
        });
        code
    }

    /// Checks an offered code.
    pub fn check(&mut self, offered_code: &str, now: Instant) -> CodeCheck {
        let Some(window) = &mut self.open_window else {
            return CodeCheck::NotOpen;
        };
        if now.duration_since(window.opened_at) >= self.code_ttl {
            self.open_window = None;
            return CodeCheck::NotOpen;
        }
        if window.failure_count >= MAX_PAIR_FAILURES_PER_WINDOW {
            return CodeCheck::Locked;
        }
        if is_same_code(&window.code, offered_code.as_bytes()) {
            self.open_window = None;
            return CodeCheck::Accepted;
        }
        window.failure_count += 1;
        CodeCheck::Wrong
    }
}

/// A new code: `PAIRING_CODE_DIGITS` uniformly random digits from the
/// thread CSPRNG (`ChaCha`, seeded by the OS).
fn random_code() -> String {
    let digit_count = u32::try_from(PAIRING_CODE_DIGITS).expect("a few digits");
    let code_number: u32 = rand::random_range(0..10_u32.pow(digit_count));
    format!("{code_number:0PAIRING_CODE_DIGITS$}")
}

fn code_bytes(code: &str) -> [u8; PAIRING_CODE_DIGITS] {
    code.as_bytes()
        .try_into()
        .expect("random_code makes PAIRING_CODE_DIGITS ASCII digits")
}

/// Constant-time compare: the time does not depend on where the codes
/// differ. (The length is not secret: every code has 6 digits.)
fn is_same_code(expected: &[u8], offered: &[u8]) -> bool {
    if offered.len() != expected.len() {
        return false;
    }
    let difference = expected
        .iter()
        .zip(offered)
        .fold(0_u8, |difference, (expected_byte, offered_byte)| {
            difference | (expected_byte ^ offered_byte)
        });
    std::hint::black_box(difference) == 0
}

/// A window the admin just opened: what `pair` prints.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OpenedWindow {
    /// The code to type on the device.
    pub code: String,
    /// The server's short id, for the person to compare.
    pub server_short_id: String,
    /// How long the code is valid.
    pub valid_ms: u64,
}

/// Everything a session needs to pair a device: the shared window, the TLS
/// identity that signs device certificates, and the network rule.
pub struct PairingService {
    window: Mutex<PairingWindow>,
    code_ttl_ms: u64,
    tls_identity: Arc<TlsIdentity>,
    config: ServerConfig,
}

impl fmt::Debug for PairingService {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("PairingService")
            .field("code_ttl_ms", &self.code_ttl_ms)
            .finish_non_exhaustive()
    }
}

impl PairingService {
    pub fn new(tls_identity: Arc<TlsIdentity>, config: ServerConfig, code_ttl_ms: u64) -> Self {
        Self {
            window: Mutex::new(PairingWindow::new(code_ttl_ms)),
            code_ttl_ms,
            tls_identity,
            config,
        }
    }

    /// Opens a new window (admin `pair`).
    pub fn open_window(&self) -> OpenedWindow {
        let code = self.lock_window().open(Instant::now());
        tracing::info!(valid_ms = self.code_ttl_ms, "pairing window opened");
        OpenedWindow {
            code,
            server_short_id: self.tls_identity.server_fingerprint().short_id(),
            valid_ms: self.code_ttl_ms,
        }
    }

    /// Checks a `PairRequest` code against the window.
    pub fn check_code(&self, offered_code: &str) -> CodeCheck {
        self.lock_window().check(offered_code, Instant::now())
    }

    /// Spec §7: the config's `pairing_networks`, plus loopback (D-028).
    pub fn is_allowed_from(&self, address: IpAddr) -> bool {
        address.to_canonical().is_loopback() || self.config.is_pairing_allowed_from(address)
    }

    /// The server identity that issues device certificates.
    pub fn tls_identity(&self) -> &Arc<TlsIdentity> {
        &self.tls_identity
    }

    fn lock_window(&self) -> std::sync::MutexGuard<'_, PairingWindow> {
        // The window holds no invariant a panic could break halfway.
        self.window.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

#[cfg(test)]
mod tests {
    use haotrannas_core::limits::PAIRING_CODE_TTL_MS;

    use super::*;

    fn opened_window() -> (PairingWindow, String, Instant) {
        let mut window = PairingWindow::new(PAIRING_CODE_TTL_MS);
        let now = Instant::now();
        let code = window.open(now);
        (window, code, now)
    }

    /// A 6-digit code that is not `code`.
    fn other_code(code: &str) -> String {
        let number: u32 = code.parse().unwrap();
        format!("{:06}", (number + 1) % 1_000_000)
    }

    #[test]
    fn codes_are_six_ascii_digits() {
        for _ in 0..200 {
            let code = random_code();
            assert_eq!(code.len(), PAIRING_CODE_DIGITS);
            assert!(code.bytes().all(|byte| byte.is_ascii_digit()), "{code}");
        }
    }

    #[test]
    fn right_code_works_once() {
        let (mut window, code, now) = opened_window();
        assert_eq!(window.check(&code, now), CodeCheck::Accepted);
        assert_eq!(window.check(&code, now), CodeCheck::NotOpen);
    }

    #[test]
    fn no_window_is_not_open() {
        let mut window = PairingWindow::new(PAIRING_CODE_TTL_MS);
        assert_eq!(window.check("123456", Instant::now()), CodeCheck::NotOpen);
    }

    #[test]
    fn code_expires_after_the_ttl() {
        let (mut window, code, now) = opened_window();
        let just_before = now + Duration::from_millis(PAIRING_CODE_TTL_MS - 1);
        assert_eq!(
            window.check(&other_code(&code), just_before),
            CodeCheck::Wrong
        );
        let expired_at = now + Duration::from_millis(PAIRING_CODE_TTL_MS);
        assert_eq!(window.check(&code, expired_at), CodeCheck::NotOpen);
    }

    #[test]
    fn ten_failures_lock_the_window_until_a_new_one_opens() {
        let (mut window, code, now) = opened_window();
        let wrong = other_code(&code);
        for _ in 0..MAX_PAIR_FAILURES_PER_WINDOW {
            assert_eq!(window.check(&wrong, now), CodeCheck::Wrong);
        }
        // Even the right code is refused now.
        assert_eq!(window.check(&code, now), CodeCheck::Locked);
        // The lock ends with the window's lifetime.
        let expired_at = now + Duration::from_millis(PAIRING_CODE_TTL_MS);
        assert_eq!(window.check(&code, expired_at), CodeCheck::NotOpen);
        // A new window starts from zero failures.
        let new_code = window.open(expired_at);
        assert_eq!(window.check(&new_code, expired_at), CodeCheck::Accepted);
    }

    #[test]
    fn malformed_codes_are_wrong() {
        let (mut window, code, now) = opened_window();
        for offered in ["", "12345", "1234567", "abcdef", &format!("{code} ")] {
            assert_eq!(window.check(offered, now), CodeCheck::Wrong, "{offered:?}");
        }
        assert_eq!(window.check(&code, now), CodeCheck::Accepted);
    }

    #[test]
    fn compare_is_exact() {
        assert!(is_same_code(b"482913", b"482913"));
        assert!(!is_same_code(b"482913", b"482914"));
        assert!(!is_same_code(b"482913", b"582913"));
        assert!(!is_same_code(b"482913", b"48291"));
    }

    #[test]
    fn debug_never_shows_the_code() {
        let (window, code, _) = opened_window();
        assert!(!format!("{window:?}").contains(&code));
    }

    #[test]
    fn loopback_may_always_pair_and_wireguard_never() {
        let tls_directory = tempfile::tempdir().unwrap();
        let identity = Arc::new(TlsIdentity::create(tls_directory.path()).unwrap());
        let service = PairingService::new(identity, ServerConfig::default(), PAIRING_CODE_TTL_MS);
        for allowed in [
            "127.0.0.1",
            "127.9.9.9",
            "::1",
            "::ffff:127.0.0.1",
            "192.168.1.20",
        ] {
            assert!(
                service.is_allowed_from(allowed.parse().unwrap()),
                "{allowed}"
            );
        }
        for refused in ["10.66.0.2", "8.8.8.8", "10.0.0.5", "fd00::1"] {
            assert!(
                !service.is_allowed_from(refused.parse().unwrap()),
                "{refused}"
            );
        }
    }
}
