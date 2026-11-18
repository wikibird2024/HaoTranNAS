# protocol

The contract between every part: message definitions, frame layout, protocol spec.

| | |
|---|---|
| Owns | `spec.md` (the contract), `vectors/*.json`, `tools/gen_vectors.py` |
| First milestone | M0 |
| Rules | [docs/conventions.md](../docs/conventions.md) |

## Build · Run · Test

```bash
python3 protocol/tools/gen_vectors.py   # regenerate vectors
git diff --exit-code protocol/vectors  # must be empty unless spec.md changed
```

No code is generated. `core/` (Rust) and `mobile/lib/protocol/` (Dart) are
hand-written and both tested against `vectors/`.
