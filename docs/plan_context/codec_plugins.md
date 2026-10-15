# Codecs as external plugins

## Goal

`libc0` carries only the C0 format. Every codec that expands a real-world binary format (PNG,
JPEG, TIFF, PDF, JSON, Baldur's Gate 3 saves) ships as a separate executable named
`c0-codec-<name>`, and the `c0` CLI reaches them only through the plugin protocol below. The
real-world codecs that validated the format on real data then also validate the plugin path a
third-party codec would use. Decided by the BDFN (Benevolent Dictator For Now), 2026-10-15,
over an in-repo library split.

## Protocol `c0-codec/1`

Each plugin is an executable taking a subcommand. Diagnostics go to its stderr, which the host
passes through unchanged. Exit status 0 means success; anything else is failure.

| Invocation | stdin | stdout |
| --- | --- | --- |
| `c0-codec-N info` | nothing | compact C0 object describing the codec |
| `c0-codec-N expand [--editable] [--compact] [--KEY VALUE]...` | native bytes | C0 text |
| `c0-codec-N collapse [--editable] [--KEY VALUE]...` | C0 text | native bytes |

`--editable` selects editable mode (derived fields such as CRCs omitted and recomputed);
faithful mode is the default. `--compact` disables pretty printing. Any other `--KEY VALUE`
pair is a codec-specific argument declared in `info`.

`info` returns an object whose values are all strings, arrays or objects (C0 has no other
types; booleans are `true`/`false` and numbers are decimal text):

```
{protocol:c0-codec/1,name:png,description:...,extensions:[.png],
 magic:[{offset:0,hex:89504e470d0a1a0a}],format_names:[png],
 faithful:true,editable:true,help:...,args:[{name:pages,value_name:RANGE,description:...}]}
```

Magic bytes travel as lowercase hex so their meaning never depends on payload encoding.

## Host behavior (`c0` CLI)

- Discovery: if `C0_CODEC_PATH` is set, it alone lists the directories to search (separator `:`,
  `;` on Windows). Otherwise search the directory holding the running `c0` executable (bundled
  codecs), then `~/.c0/codecs`, then `PATH`. The first plugin found for a name wins. Within a
  directory, names are taken in sorted order so detection is deterministic. On Windows the
  executable is `c0-codec-<name>.exe`.
- `info` is fetched lazily, once per plugin per process.
- `expand` without `--codec`: the first plugin whose magic matches wins; otherwise the first whose
  extension matches the file name, compared case-insensitively.
- `collapse` without `--codec`: decode the C0 input, read its top-level `format` field, and pick
  the first plugin whose `format_names` or name equals it.
- Spawning streams stdin and stdout concurrently (poll on POSIX, a writer thread on Windows), so a
  plugin may write before it finishes reading without deadlocking.

## Plugin implementation

One C host, `codecs/plugin_main.c`, is compiled into every plugin executable and performs all
I/O. It calls a uniform C ABI (`codecs/c0_plugin.h`) exported by each codec's Zig static
library: `c0_plugin_info`, `c0_plugin_expand`, `c0_plugin_collapse`, `c0_plugin_free`. The
shared Zig adapter (`codecs/plugin.zig`) turns any codec type into that ABI and serializes its
info. Codec logic stays pure Zig with no I/O, and its unit tests are unchanged apart from the move.

## Out of scope

Protocol versions beyond 1, plugin sandboxing, and persistent plugin processes. Plugins run with
the caller's authority.
