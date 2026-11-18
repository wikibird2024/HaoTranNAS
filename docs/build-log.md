# HaoTranNAS — Build log

Author: Hao Tran · Updated: 2026-11-18

What was built, in what order, and **why**. One section per wave. Read this to
learn the engineering ideas behind the project, not just the result.

---

## The big idea: fix things where they are cheapest

```
 cost of fixing one mistake
   │                                              ████  after release: version bump,
   │                                     ████     ████  every phone must update
   │                            ████     ████     ████
   │                   ████     ████     ████     ████  after code: 2 codecs + server + tests
   │          ████     ████     ████     ████     ████
   │  ▂▂▂▂    ████     ████     ████     ████     ████
   └──spec────design───code─────test─────release──────►
      ▲ a fix here is one line of text
```

Settle the things that are expensive to change first, while a change costs one line.

## Wave 0 — foundation (2026-11-18)

```
 1 contract ─► 2 test data ─► 3 skeletons ─► 4 CI ─► 5 parallel helpers ─► 6 review ─► 7 freeze
   (spec)       (vectors)      (stubs)        (robot   (worktrees)           (find bugs)  (lock it)
                                               checker)
```

| # | What was done | Why | Engineering idea |
|---|---|---|---|
| 1 | `protocol/spec.md` written before any code | Rust and Dart must speak exactly the same bytes; two people coding from memory always drift | **Contract first**: one written truth both sides obey |
| 2 | `protocol/tools/gen_vectors.py` makes the test frames | A third, separate implementation: if Rust, Dart and Python agree, the spec is very likely implemented right | **Golden test data**: answers fixed before the code exists, so code can't grade its own homework |
| 3 | Every module created as an empty stub, all dependencies declared up front | Many helpers then work at the same time without editing the same files | **Scaffold first**: decide the shape once, fill it in parallel |
| 4 | CI (GitHub Actions) on day 1: rust, Mobile (incl. APK), nas | Proved the Android build files work, which this PC never checks | **Fail fast**: learn of a problem an hour later, not a month later |
| 5 | Helpers in separate git worktrees, merged one at a time | Speed without chaos: each works in its own copy, each result is checked before it joins `main` | **Work in parallel, merge in sequence** |
| 6 | Review before the freeze | Found that a damaged chunk could never be repaired (fix: 3 lines of spec). After coding it would have meant 2 codecs + server + tests | **Review at the cheapest point** |
| 7 | Freeze (tag `protocol-v1`) waits for Hao's sign-off | After the freeze, changing the bytes means a new protocol version | **Lock what others build on** |

### Safety habits in the code

| Habit | Where | Why |
|---|---|---|
| Dry-run mode | `nas/scripts/zfs_mirror_setup.sh`, `wireguard_keys.sh` | See the exact commands before anything erases a disk |
| Typed confirmation `yes, erase <disk1> <disk2>` | ZFS script | A tired person can't wipe the wrong disk with Enter |
| Stable disk names `/dev/disk/by-id/…` | ZFS script | `/dev/sda` can change between boots |
| Default deny | `nas/firewall/haotrannas.nft` | Everything closed, then only what is needed opened |
| Test that no real key is in the repo | `nas/scripts/tests/run_tests.sh` | Secrets leak by accident, not on purpose |
| One crypto library only (ring) | `.github/workflows/rust.yml` | Less code to trust; CI fails if another one sneaks in |
| Vectors must equal the generator's output | `.github/workflows/rust.yml` | Nobody can "fix" a test frame to make code pass |
| Decision log | `docs/decisions.md` | In six months you know **why**, not just what |

### Review findings fixed before the freeze

| # | Finding | Fix |
|---|---|---|
| 1 | A chunk marked bad was "already stored", so it was never rewritten; Commit failed forever | Bad chunks are overwritten; on `CHUNKS_MISSING` the client re-offers |
| 2 | "Self-heal" never happened for photos already backed up | Shortcut skipped when a chunk is bad; repair = ZFS or phone "verify backup" (M6) |
| 3 | Vectors could be hand-edited without CI noticing | CI regenerates them and fails on any diff |
| 4 | Phone could try IPv6, which the firewall drops | Discovery uses IPv4 |
| 5 | Every push built the APK, even for docs | Path filters per CI job |
| 6 | aws-lc check ran twice | One check |

### Exercise: read bytes like a computer

The first test frame, `hello_basic`, from `protocol/vectors/messages.json`.
Decode it with `protocol/spec.md` §2–§5 open:

```
 00000027  0001  00000001  0001  0014 68616f7472616e6e61732d636c692f302e312e30  0007 706978656c2d37
```

| Bytes | Spec rule | Meaning |
|---|---|---|
| `00000027` | §3 `length_bytes u32` | 0x27 = 39 bytes follow |
| `0001` | §3 `message_type u16` | type 1 = Hello (§5) |
| `00000001` | §3 `request_id u32` | request 1 |
| `0001` | Hello `protocol_version u16` | version 1 |
| `0014` + 20 bytes | `str` = u16 length + UTF-8 | `haotrannas-cli/0.1.0` |
| `0007` + 7 bytes | `str` | `pixel-7` |

Check: 2 + 4 + 2 + (2 + 20) + (2 + 7) = 39. That is the whole job of a codec;
wave 1 teaches Rust and Dart to do it, and the 55 test frames prove they do.

See the text yourself:

```bash
echo 68616f7472616e6e61732d636c692f302e312e30 | xxd -r -p; echo
```

Next exercise: decode `ping` and `error_unknown_upload` from the same file.
