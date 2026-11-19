# protocol/fixtures

Test data recorded from real programs. Not part of the contract: `spec.md`
wins, and `vectors/` stays the codec source of truth.

| File | What it is |
|---|---|
| `mdns_announcement.hex` | One real mDNS answer (165 bytes, hex, 32 bytes per line; ignore whitespace) from `haotrannas-server`'s announcer (mdns-sd 0.22) to a PTR query for `_haotrannas._tcp.local` (spec section 13) |

## mdns_announcement.hex

Recorded by `HAOTRANNAS_WRITE_MDNS_FIXTURE=1 cargo test -p haotrannas-server mdns_capture -- --ignored`.
Fingerprint = SHA-256("abc"), so `fp=ba7816bf8f01cfea`; address 127.0.0.1.

| Section | Name | Type | Data |
|---|---|---|---|
| Header | id `0x4854`, flags `0x8400` (response, authoritative) | | 1 question, 1 answer, 3 additional |
| Question | `_haotrannas._tcp.local` | PTR, IN | |
| Answer | `_haotrannas._tcp.local` | PTR | `haotrannas._haotrannas._tcp.local` |
| Additional | `haotrannas._haotrannas._tcp.local` | SRV | priority 0, weight 0, port 47100, target `haotrannas-ba7816bf8f01cfea.local` |
| Additional | `haotrannas._haotrannas._tcp.local` | TXT | `v=1`, `fp=ba7816bf8f01cfea` |
| Additional | `haotrannas-ba7816bf8f01cfea.local` | A | 127.0.0.1 |

Names use DNS compression pointers. All TTLs are 10 s.

It is a *legacy unicast* answer (RFC 6762 §6.7: the query came from a port
other than 5353), which is why it echoes the query id and the question, has
TTL 10 and no cache-flush bit. A normal multicast answer on the LAN differs:
id 0, no question, class `0x8001` (cache-flush bit set) on SRV/TXT/A, TTL
120 s (SRV, A) and 4500 s (PTR, TXT). A decoder must mask the class with
`0x7FFF` and must not depend on the question section.
