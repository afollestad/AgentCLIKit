## Claude Hook Transport

- Keep hook listeners loopback-only and pass generated settings with `--settings`.
- Treat invalid, missing, stale, malformed, or oversized hook requests as successful Claude `deny` decisions.
- Return no-decision responses with nil bodies for valid hooks that the host does not control; do not encode those as explicit allows.
- Send nil hook response bodies as zero-length HTTP bodies.
- Scope hook tokens to one provider launch and invalidate them when that launch exits or is superseded.
- Keep HTTP parsing and listener lifecycle here; keep generic runtime APIs provider-neutral where possible.
