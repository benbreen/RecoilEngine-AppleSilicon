# RecoilEngine-AppleSilicon — launcher messages

The **BAR Launcher** fetches a single file, [`messages.json`](messages.json),
on startup to show announcements or, when needed, to block a known-bad build.
It is read only by the BAR Launcher (not the plain engine build). Editing it is
how you talk to everyone who has the launcher installed — no app update needed.

## Editing (one file per message)

You do **not** hand-edit `messages.json` — it is generated. Instead add/edit a
small file per message under [`messages/`](messages), named
`YYYY-MM-DD-slug.jsonc` (the date prefix sets display order). Then assemble:

```sh
python3 assemble.py          # regenerates messages.json (validates as it goes)
python3 assemble.py --check  # validate only
```

On GitHub a workflow runs `assemble.py` automatically on every push, so in
practice you just add/delete a file in `messages/` and commit. Small per-message
files keep diffs clean and the set readable no matter how many there are.

## How the launcher uses it

- Fetched fresh **every launch**, never cached (a fixed-id message can have its
  content changed and users must see the update).
- **Fail-open**: if the file is unreachable or unparseable, the launcher just
  continues. A message is a courtesy, never a gate — the launcher's own
  disclaimer is hardcoded and local, so nothing here can weaken it offline.
- Messages that apply to the running version are shown **oldest → newest** (by
  `date`).

## File format (JSONC)

Full-line `//` comments are allowed (stripped before parsing). Do not put a
comment on the same line as data.

```jsonc
{
  "schema": 1,
  "messages": [ { …message… }, … ]
}
```

### Message fields

| Field | Required | Meaning |
|---|---|---|
| `id` | yes | Stable unique id. Suppression + "shown once" track by this. Reusing an id reuses that state; use a **new** id to force a re-show for everyone. |
| `date` | recommended | `YYYY-MM-DD`; controls oldest→newest display order. |
| `target` | yes | Which versions see it: `{ "op": …, "version": "0.2" }`. |
| `title` | yes | Dialog title. |
| `body` | yes | HTML fragment (`<b>`, `<i>`, `<a href>` clickable, `<span style='color:#…'>`). May be a **string** or an **array of lines** (joined) to keep multi-line HTML readable. |
| `suppressible` | no (false) | Adds a "Don't show this again" checkbox. |
| `suppressDefault` | no (true) | Checkbox initial state when `suppressible`. |
| `frequency` | no (`once`) | For **non**-suppressible messages: `once` (auto-suppress after first show) or `always` (show every launch). |
| `buttons` | no | Action buttons (see below). Default is a single `OK` that continues. |

### `target.op`

Single-version ops use `version`:
`all`, `eq`, `ne`, `lt`, `le`, `gt`, `ge`.

`range` uses `min` + `max` (both **inclusive** by default):

```jsonc
"target": { "op": "range", "min": "1.1", "max": "2.3" }
// exclusive bound: add "minInclusive": false and/or "maxInclusive": false
```

Versions compare **dotted-numeric** per component, so `0.11 > 0.2` (matches the
port's release numbering).

### Buttons

Listed in macOS order (first = rightmost). Each:

| Field | Meaning |
|---|---|
| `label` | Button text. |
| `action` | `continue` (launch the game), `quit` (quit the app), or `open-url`. |
| `url` | For `open-url`: the URL to open. |
| `then` | For `open-url`: `continue` (default), `quit`, or `stay` (open the link but keep this dialog on screen) after opening. |
| `default` | `true` marks the Return-key default button. |

A message with **no** `continue`/open-url-then-continue path is a hard block
(kill-switch): the user can only upgrade or quit.

## Server authority

The current file always wins:

- A message set to `frequency: always` (or made non-suppressible) is shown even
  to users who previously suppressed it — flip a message to forced to override
  earlier "don't show again".
- Deleting a message stops it for everyone.

See [`examples/`](examples) for worked examples of every combination (they are
documentation only — files there are NOT assembled into `messages.json`).
