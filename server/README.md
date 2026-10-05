# Queens server

The backend for the Queens client in `../queens`: identity, results, per-level
leaderboards, the league and friends. One static binary, Go and SQLite, no cgo.

```bash
go run ./cmd/queensd            # serve on :8080 against ./queens.db
go run ./cmd/queensd migrate    # apply migrations and import the levels, then exit
go run ./cmd/queensd openapi -o openapi.yaml
go run ./cmd/queensd admin      # operational commands
```

Open `/docs` for the rendered API, `/openapi.yaml` for the document.

## What it is responsible for

The client already defined the contract before this existed:
`queens/scripts/backend/backend.gd` has the methods and the record shapes, and
`local_backend.gd` is a working offline implementation of them. This service is
a port of that contract.

The one thing it changes is where the truth lives. Every score is recomputed
from the server's own level row, because `par_seconds` is the numerator of the
speed factor and a client that sends its own could pin the multiplier at its
maximum. The same goes for `size`, `difficulty` and `stars`.

## The league in one paragraph

The rules are `queens/shared/league.json`, embedded at build time (`go run
./internal/levelset/cmd/copylevels` refreshes the copy). Bronze and Silver have
no rounds: no round row, no group, a game only adds tier points until
`promo_score` promotes. From Gold on a tier plays in weeks. Random placement
fills a group to `group_size` (30); a player joins a friend's group (a follow in
either direction) up to `group_max` (50), automatically at their first game of
the week or explicitly through `POST /v1/league/join` after
`GET /v1/league/join-options`. Gold and Platinum groups are topped up to 30 with
bots. Nothing about a bot is stored: their scores are a pure function of the
group id, the slot and the clock (`domain.BotProgress`, pinned against the
GDScript by the parity fixtures), the active bots are always the first
`fill_to - people` slots, and the closer ranks them with everyone else but
settles only people. Diamond and Challenger (`online_required`) count a game
only when a session covers it and it arrived within `online_grace_s` of
finishing; anything else is stored with `results.counted = 0` and listed by
`GET /v1/league/runs`, but adds nothing. Below them a missing session is an
ordinary offline game and raises no flag.

## Layout

| Package | What is in it |
| --- | --- |
| `internal/domain` | Ports of `scoring.gd` and `league_rules.gd`, plus the types. Standard library only, so the parity tests are trivial. |
| `internal/store` | Repository interfaces. Everything above talks to these, so the engine can be swapped. |
| `internal/store/sqlite` | The SQLite implementation and the migrations. |
| `internal/levelset` | Imports `queens.json` on every boot. |
| `internal/service` | The business logic. Returns coded errors; knows nothing about HTTP. |
| `internal/api` | Huma v2 over chi. Thin handlers. |
| `internal/auth` | The two opaque secrets: the bearer token and the session token. |

## Configuration

Environment variables only.

| Variable | Default | Notes |
| --- | --- | --- |
| `QUEENS_ADDR` | `:8080` | |
| `QUEENS_DB` | `queens.db` | |
| `QUEENS_ENV` | `dev` | `prod` requires a pepper |
| `QUEENS_TOKEN_PEPPER` | dev only | Signs session tokens. Changing it invalidates every outstanding session. |
| `QUEENS_LOG_LEVEL` | `info` | |
| `QUEENS_TRUST_PROXY` | `false` | Honour `X-Forwarded-For`. Only behind a proxy you control, or every rate limit is spoofable with a header. |
| `QUEENS_COOLDOWN_SECONDS` | `604800` | |
| `QUEENS_SESSION_TTL` | `21600` | Freshness only. A session is accepted for 30 days. |
| `QUEENS_NO_SESSION_GRACE_UNTIL` | `0` | Unix time before which a result with no session is not flagged. Production sets it in the future, i.e. off: offline play is supported, and at weight 8 against a threshold of 15 the second offline game would shadow-exclude an honest player. See `../deploy/README.md`. |
| `QUEENS_BACKUP_DIR` | unset | Enables the nightly backup |
| `QUEENS_BACKUP_HOUR_UTC` | `3` | |

## Two details worth knowing before changing anything

**The write pool holds one connection.** Writes serialise through Go's
connection pool, which is a FIFO that honours context cancellation, rather than
through `SQLITE_BUSY` retries. Reads use a separate pool and never queue behind
a slow submit. `_txlock=immediate` removes the read-then-write upgrade deadlock.

**Levels are data, not schema, and append-only.** The database is the source
of truth for the level set. The copy of `queens/levels/queens.json` embedded in
the binary is imported additively on every boot, and `queensd admin levels
import FILE` imports any level file at run time: new ids are published after
the last level, known ids must be byte-for-byte the same board, and a level
missing from a file is left alone. A changed board (any field) is refused,
naming the level: clients compare level counts, not contents, so an edit would
never reach a device that has the old board, and scores on it would compare
different puzzles. Give a fixed board a new id instead.

A running server notices an import on its next level request (one `COUNT(*)`)
and reloads its level index, so new levels need neither a server deploy nor a
client release. At launch the client asks `GET /v1/levels/count`; when that
differs from its own count it fetches `GET /v1/levels/ids`, downloads the
missing boards with `GET /v1/levels?ids=...` (50 per request, solution
included: the client needs it to mark wrong queens) and caches them in
`user://levels_cache.json`. Runbook: `../deploy/README.md`, "Adding levels".

**Level state per player.** `player_levels` holds each player's state on every
level they started (plays, completions, last completion, best time, best run),
the server-side twin of the `levels` entry in the client's save file. A
session-backed start counts the play; every accepted result, verified or not,
adds the rest (an offline game also counts its play when it arrives). Clients
read it with `GET /v1/me/levels` at launch and on reconnect, take it as the
truth, and replay their still-unsent results on top.

## Deployment

One manually triggered pipeline, described in `../deploy/README.md`: merge
`main` into `release` and the server goes to Uberspace at
`https://www.ludwigso.de/queens/api` before the APK that was built against it
is published.

The binary is mounted behind a path that the reverse proxy strips, so there is
no base-path option here and the server is unaware of the prefix. It is a
single instance on purpose: the rate limiters are in-process and the write pool
holds one connection.

## Tests

```bash
go test ./...
```

That includes the cross-language parity fixtures in `../shared/fixtures`, which
are generated from the Godot client and pin the scoring and league maths in both
runtimes, and a sweep of four million scores hashed on each side. Regenerate
them from the repository root with:

```bash
godot --headless --path queens --script tools/gen_fixtures.gd
```

## What this deliberately does not do

- **No admin HTTP surface.** `queensd admin` reads the same database. An admin
  API is an authentication, authorisation and audit problem that is not worth
  having on day one.
- **No account recovery and no second device.** The credential lives on the
  device. `players.auth_provider` and `auth_external_id` exist so a sign-in can
  be added later without a migration.
- **No move-log replay.** Every counter a result carries is self-reported by
  hardware the reporter controls, so a patient cheater cannot be stopped. What
  is defended is the arithmetic, the level's intrinsic worth, the volume and the
  identity. `results.move_log` is reserved for the day that changes.
- **No purchase validation.** The unlimited-energy entitlement is still
  client-asserted. That hole is probably worth more than the leaderboard one.
