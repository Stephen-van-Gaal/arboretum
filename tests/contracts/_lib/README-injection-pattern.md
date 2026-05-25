# Prompt-Injection-Resistance Test Pattern

> Per WS4 design spec §D6. This pattern documents how to write a contract test that asserts a seam's input-handling code does not execute hostile input as code (mega-epic success criterion SC11).

## When to apply

Apply this pattern to any seam whose producer ingests **user-controlled** content — issue titles, issue bodies, PR comments, statusline cache, intake reports, anything that originates outside the agent's own writes.

Foundation-triplet status:
- **S2** (/design → /build) — producer is /design, content is agent-controlled. Lower urgency; pattern application is per-seam follow-up.
- **S3** (/build → /finish) — producer is /build, content is agent-controlled. Lower urgency.
- **S9** (any stage skill → log-stage.sh) — producer is "any stage skill", which interpolates CLI args derived from issue text. **Worked example here** (S9-7).

WS5 (governance-script contracts) and WS7 (intake pipeline, cross-repo seam) will both ingest user-controlled content and MUST apply this pattern.

## The three-piece shape

Every injection test has three pieces:

### 1. Malicious-input fixture

A static file under `tests/contracts/fixtures/` containing payloads representative of the seam's hostile-input class. The canonical payload classes to include:

| Class | Example | Where it bites |
|---|---|---|
| ANSI escape sequences | `\x1b[2J` (clear screen), `\x1b]0;evil\x07` (set window title) | Terminal context (statusline, banner) |
| Control characters | `\x00`-`\x08`, `\x0b`-`\x0c`, `\x0e`-`\x1f`, `\x7f`-`\x9f` | Same; matches `scripts/refresh-next-cache.sh`'s scrub regex |
| Shell metacharacters | `` ` cmd ` ``, `$(cmd)`, `$((expr))` | Anywhere unquoted bash interpolation can occur |
| Markdown directive injection | `<!-- evil -->`, `[click](javascript:...)` | Anywhere the output is rendered as Markdown |
| Quoted-value escape attempts | unescaped `, `, `"`, `\n` | Anywhere the seam uses structural delimiters |

### 2. Sanitizer/validator invocation

The seam's input-handling code is invoked against the payload. For helper scripts, this means feeding the payload as a CLI arg and capturing the produced output.

### 3. Output-safety assertion

The output is asserted to be safe. Safety has two parts:

- **No control characters in the output.** Use a portable python3 check — `grep -P` is unsupported on BSD grep (macOS) and would silently no-op. Read the output as decoded UTF-8 text (not raw bytes — UTF-8 continuation bytes like `0x80` from `—` U+2014 would false-positive on byte-level matches) and search Unicode codepoints with `re.search(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f-\x9f]', text)`. See `tests/contracts/s9/s9-7-quoted-value-escaping.sh` for the worked example.
- **Structural delimiters preserved.** Quoted values that contain `, `, `"`, or `\n` MUST be escaped per the seam's documented rules; the test asserts round-trip fidelity (un-escape produces the original payload).

## Worked example: S9-7

See `tests/contracts/s9/s9-7-quoted-value-escaping.sh` and the fixture `tests/contracts/fixtures/log-stage-injection-payload.txt`.

## Failure modes this pattern catches

- A sanitizer that scrubs control chars but forgets ANSI escapes.
- A quoter that handles `"` but not `\n`.
- A round-trip that produces lossy output (un-escape produces a different string than the original).
- A consumer downstream of the seam that re-interprets the safe output as code.
