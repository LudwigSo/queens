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
`queens/scripts/backend/backend.gd` has the fourteen methods and the record
shapes, and `local_backend.gd` is a working offline implementation of them. This
service is a port of that contract, minus the bots.

The one thing it changes is where the truth lives. Every score is recomputed
from the server's own level row, because `par_seconds` is the numerator of the
speed factor and a client that sends its own could pin the multiplier at its
maximum. The same goes for `size`, `difficulty` and `stars`.

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
| `QUEENS_NO_SESSION_GRACE_UNTIL` | `0` | Unix time before which a result with no session is not flagged. Set it at rollout so the queue built up by pre-server clients does not flag honest players. |
| `QUEENS_BACKUP_DIR` | unset | Enables the nightly backup |
| `QUEENS_BACKUP_HOUR_UTC` | `3` | |

## Two details worth knowing before changing anything

**The write pool holds one connection.** Writes serialise through Go's
connection pool, which is a FIFO that honours context cancellation, rather than
through `SQLITE_BUSY` retries. Reads use a separate pool and never queue behind
a slow submit. `_txlock=immediate` removes the read-then-write upgrade deadlock.

**Levels are data, not schema.** The file is re-imported on every boot. A
changed `size` or `difficulty` refuses to start, naming the level: both feed
`base` and `par_seconds`, so accepting the change would silently invalidate
every score ever recorded on that level. Give the changed board a new id
instead. Deploy the server before shipping a client with new levels; an old
server answers `ERR_LEVEL_UNKNOWN` and the client falls back to offline play for
that level rather than blocking the game.

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
