# HaoTranNAS — Core concepts

Author: Hao Tran · Status: Draft v0.1 · 2026-11-18

The ideas you need to understand before building HaoTranNAS. Read this first,
then [architecture.md](architecture.md) (how we use them) and
[community-research.md](community-research.md) (who else uses them).

---

## 1. The mental model: a LEGO warehouse

```
  PHONE                                   SERVER = warehouse
  ┌──────────────┐                        ┌──────────────────────────────────┐
  │ photo.jpg    │  cut into bricks       │  SHELVES (chunk store)           │
  │ ┌──┬──┬──┐   │  label = fingerprint   │  [a1f][7c2][e90][44b][...]       │
  │ │a1│7c│e9│   │ ─────────────────────► │  each brick stored ONCE          │
  │ └──┴──┴──┘   │                        │                                  │
  └──────────────┘                        │  CATALOG (SQLite index)          │
                                          │  photo.jpg v2 = [a1f, 7c2, e90]  │
                                          │  ▲ written last, all at once     │
                                          └──────────────────────────────────┘
```

| Warehouse | Our system |
|---|---|
| Brick | Chunk (1 MiB of the file) |
| Label on the brick | Its hash (SHA-256 fingerprint) |
| Instruction sheet | File version = ordered list of hashes |
| Clerk asking "which bricks are you missing?" | `FileOffer` → `NeedChunks` |
| Filing the sheet in the catalog | `Commit` |

**One thing to remember:** the server stores bricks by their label, and a file
only exists once its instruction sheet is filed.

## 2. The concept stack (bottom to top)

```
   8  Trust          who is talking?            TLS, certificates
   7  Concurrency    many phones at once?       async tasks, one DB writer
   6  State machine  what may happen now?       Connected → Ready → Closed
   5  Atomicity      crash in the middle?       temp + rename, transaction
   4  Idempotency    safe to retry?             same chunk twice = no harm
   3  Chunking       big files, bad Wi-Fi?      1 MiB pieces
   2  Hashing        how to name content?       SHA-256 fingerprint
   1  Framing        where does a message end?  length prefix
   ───────────────────────────────────────────────────────────────────
   0  TCP: a reliable pipe of bytes, with no message boundaries
```

Each layer solves one problem the layer below leaves open.

| # | Concept | Where in our system | Milestone |
|---|---|---|---|
| 1 | Framing | `server/` codec layer | M0 |
| 2 | Hashing | Chunk names, `FileOffer` | M1 |
| 3 | Chunking | Phone Hasher, `NeedChunks` | M2 |
| 4 | Idempotency | Retry any message after a failure | M2 |
| 5 | Atomicity | Chunk write, `Commit` | M2 |
| 6 | State machine | Session layer | M0 |
| 7 | Concurrency | tokio tasks, DB writer task | M0–M2 |
| 8 | Trust | Pairing, mutual TLS, WireGuard | M3, M6 |

## 3. Each concept

### 3.1 Framing: TCP is a pipe, not an envelope

```
 You send:      [Hello][FileOffer]
 TCP may give:  [Hel] [loFileOf] [fer]      ← same bytes, cut anywhere
 Fix:           [len=12][Hello...][len=80][FileOffer...]
```

| | |
|---|---|
| Idea | Put each message's length first; the reader waits until it has that many bytes |
| If missing | Messages get glued together or split, at random |
| Ours | `lengthBytes · type · requestId · payload` |

### 3.2 Hashing: a fingerprint of content

```
 "cat photo" bytes ──SHA-256──► 7c2e…  (always the same for the same bytes)
 change 1 bit     ──SHA-256──► 91ab…  (completely different)
```

| Property | What we get |
|---|---|
| Same bytes → same hash | Dedupe: store once |
| 1 bit changed → new hash | Corruption is caught |
| Can't run it backwards | The hash is safe to use as a name |

This is **content addressing**: the name comes from the content. Git, restic
and Syncthing all rest on it.

### 3.3 Chunking: cut big things into small pieces

| Problem with one big 200 MB video | Fixed by chunks |
|---|---|
| Wi-Fi drops at 190 MB → start over | Only resend missing chunks |
| Needs 200 MB of RAM | Handle 1 MiB at a time |
| Edit the end → resend everything | Only the changed chunks are new |

### 3.4 Idempotency: doing it twice = doing it once

```
 send chunk 7c2 ──► stored
 send chunk 7c2 ──► "already have it" ──► nothing changes
```

A chunk is named by its content, so a retry can't do damage. The phone can
**just retry anything** after a failure. Without this, a retry could leave two
copies or a mix of old and new data.

### 3.5 Atomicity: all or nothing

```
 Chunk:  write tmp/x ─► fsync ─► check hash ─► rename to chunks/7c2   (rename is atomic)
 File:   BEGIN ─► insert version + chunk list ─► COMMIT                (transaction)

 crash anywhere before the last arrow ⇒ as if nothing happened
```

| Rule | Why |
|---|---|
| Never write in place | A crash would leave half a file |
| Make it real with one final step | Readers see the old state or the new one, never a mix |

### 3.6 State machine: only certain messages are allowed at each moment

```
 Connected ──Hello──► Greeted ──cert ok──► Ready ──(requests)──┐
                                             ▲─────────────────┘
 anything unexpected ──► Closed
```

The server always knows what it expects next. A `Commit` before `Hello` is
simply refused. This one rule wipes out a whole class of bugs and attacks.

### 3.7 Concurrency: many phones, one warehouse

| Part | Who runs it | Why |
|---|---|---|
| Each connection | Its own async task | One slow phone doesn't block the others |
| Chunk files | Any task, directly | Different names, so no fights |
| Catalog (SQLite) | **One** writer task | No two writers racing on the same file |

Async (tokio) means thousands of waiting connections cost almost nothing: a
task sleeps while it waits for the network.

### 3.8 Trust: who is on the other end?

```
 TLS = lock (nobody can read) + ID card (certificate)

 Pairing (once, at home):  phone ⇄ server swap ID-card fingerprints
 Every connection after:   "show your card" ── matches? ──► talk
```

| Threat | Stopped by |
|---|---|
| Someone listens on the Wi-Fi | TLS encryption |
| A fake server | Phone checks the server's fingerprint |
| A stranger's phone | Server checks the phone's fingerprint (mutual TLS) |
| Attack from the internet | No open port; outside home you only get in through WireGuard |

## 4. The whole system in 5 sentences

1. The phone cuts each file into chunks and names each chunk by its hash.
2. It tells the server the list of hashes, and the server replies with the ones it lacks.
3. The phone sends only those; the server checks each hash and stores the chunk atomically.
4. `Commit` files the list in the catalog in one transaction, so the file now exists.
5. Any failure → just retry; hashing makes retries harmless, and commit makes crashes harmless.

## 5. Check yourself

| # | Question | Answer |
|---|---|---|
| Q1 | Two phones back up the same meme. How many copies on disk? | One. Same bytes → same hashes → the server already has them |
| Q2 | Server crashes after all chunks arrive, before `Commit`. What does the user see? | Nothing new yet. The phone re-offers; the server needs no chunks; the phone sends `Commit` |
| Q3 | Why not just `write()` messages onto TCP and `read()` them back? | TCP has no message boundaries; you need framing |
| Q4 | Why one writer for the catalog but not for chunk files? | Chunks with different content never share a name; the catalog is one shared file |

## 6. Learn in this order

| Step | Concept | Best source / exercise |
|---|---|---|
| 1 | Framing + TCP | Write a 30-line echo server with a length prefix |
| 2 | Hashing + content addressing | `git cat-file -p HEAD`, then follow the hashes |
| 3 | Chunk store | [restic `doc/design.rst`](https://github.com/restic/restic/blob/master/doc/design.rst) |
| 4 | Atomicity | Search "write temp file fsync rename" |
| 5 | Protocol + state | [Syncthing `bep.proto`](https://github.com/syncthing/syncthing/blob/main/proto/bep/bep.proto) |
| 6 | TLS / certificates | Run `openssl s_client -connect example.com:443` and read the certificate |

## 7. Glossary

| Word | Meaning here |
|---|---|
| Chunk | 1 MiB piece of a file, stored once |
| Hash / fingerprint | SHA-256 of some bytes; used as a name |
| Content addressing | Naming data by its hash |
| Dedupe | Storing identical data only once |
| Frame | One message on the wire: length + type + id + payload |
| Idempotent | Safe to do more than once |
| Atomic | Happens fully or not at all |
| Commit | The final step that makes a file version real |
| fsync | Force data from the OS cache onto the disk |
| Mutual TLS | Both sides show a certificate |
| mDNS | Finding devices on the LAN by name, no IP typing |
| WireGuard | VPN; the only way in from outside home |
