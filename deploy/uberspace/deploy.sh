#!/usr/bin/env bash
#
# Swaps a staged queensd build into service on an Uberspace 8 host.
#
# Piped over ssh by .github/workflows/deploy-server.yml, which has already
# uploaded ~/releases/<sha>.incoming/queensd and the files next to this one.
# Safe to run by hand with the same environment.
#
# Required environment:
#   RELEASE_SHA                    the commit being deployed; names the release dir
#   QUEENS_PORT                    the port the web backend points at
#   QUEENS_TOKEN_PEPPER            generated once, never rotated
#   QUEENS_NO_SESSION_GRACE_UNTIL  see deploy/README.md
#   QUEENS_BACKEND_PATH            the web backend, e.g. /queens
set -euo pipefail

: "${RELEASE_SHA:?RELEASE_SHA is required}"
: "${QUEENS_PORT:?QUEENS_PORT is required}"
: "${QUEENS_TOKEN_PEPPER:?QUEENS_TOKEN_PEPPER is required}"
: "${QUEENS_NO_SESSION_GRACE_UNTIL:?QUEENS_NO_SESSION_GRACE_UNTIL is required}"
: "${QUEENS_BACKEND_PATH:?QUEENS_BACKEND_PATH is required}"

STAGE="$HOME/releases/$RELEASE_SHA.incoming"
TARGET="$HOME/releases/$RELEASE_SHA"
LINK="$HOME/bin/queensd"
ENVFILE="$HOME/etc/queensd.env"
SERVICE=queensd.service
UNIT="$HOME/.config/systemd/user/$SERVICE"
DB="$HOME/queens/queens.db"
BACKUPS="$HOME/queens/backups"
KEEP_RELEASES=5

say() { printf '\n==> %s\n' "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

# The service logs to the journal. Everything since a given epoch, as plain
# message lines (queensd's own JSON), for the checks below.
journal_since() {
  journalctl --user --unit "$SERVICE" --since "@$1" --output cat --no-pager 2>/dev/null || true
}

# ---------------------------------------------------------------- preconditions

say "Checking the host"
mkdir -p "$HOME/bin" "$HOME/etc" "$HOME/.config/systemd/user" "$HOME/queens" "$BACKUPS" "$HOME/releases"
chmod 700 "$HOME/queens" "$BACKUPS"
[ -f "$STAGE/queensd" ] || die "no staged binary at $STAGE/queensd"

# systemctl --user needs the user's systemd instance, which Uberspace starts at
# boot. Over `ssh host bash -s` XDG_RUNTIME_DIR can be unset, and then every
# systemctl call below fails with a bus error rather than doing anything.
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
systemctl --user is-system-running >/dev/null 2>&1 \
  || [ "$(systemctl --user is-system-running 2>/dev/null)" = degraded ] \
  || die "cannot reach the systemd user instance (XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR)"

# The port is defined once in bootstrap.sh; everything else asserts against it.
#
# Finding the CLI matters: over `ssh host bash -s` the shell is non-interactive
# with a reduced PATH, so a bare `command -v` can come up empty on the very
# host this check exists for -- and the one guard against a routing
# misconfiguration would then switch itself off without failing anything.
uberspace_cli=""
if command -v uberspace >/dev/null 2>&1; then
  uberspace_cli="uberspace"
elif [ -x /usr/local/bin/uberspace ]; then
  uberspace_cli=/usr/local/bin/uberspace
elif [ -x /usr/bin/uberspace ]; then
  uberspace_cli=/usr/bin/uberspace
fi

if [ -n "$uberspace_cli" ]; then
  if ! "$uberspace_cli" web backend list | grep -F -- "$QUEENS_BACKEND_PATH" | grep -qw -- "$QUEENS_PORT"; then
    "$uberspace_cli" web backend list || true
    die "no web backend for $QUEENS_BACKEND_PATH on port $QUEENS_PORT. Run deploy/uberspace/bootstrap.sh first."
  fi
  echo "ok: $QUEENS_BACKEND_PATH is routed to port $QUEENS_PORT"
elif hostname -f 2>/dev/null | grep -q '\.uberspace\.de$'; then
  die "this is an Uberspace host but the uberspace CLI is not on PATH; refusing to skip the web-backend check"
else
  echo "note: not an Uberspace host, skipping the web-backend check"
fi

# ---------------------------------------------------------------- stage

say "Staging $RELEASE_SHA"
# OpenSSH 9 uploads over SFTP and does not reliably preserve the mode.
chmod 755 "$STAGE/queensd"
# A smoke test of the artifact itself, before anything in service is touched.
staged_version="$("$STAGE/queensd" version)"
[ "$staged_version" = "$RELEASE_SHA" ] || die "staged binary reports version '$staged_version', expected '$RELEASE_SHA'"
rm -rf "$TARGET"
mv "$STAGE" "$TARGET"
echo "ok: $TARGET/queensd reports $staged_version"

# QUEENS_ADDR has no host part on purpose: Uberspace 8 forwards to the port on
# the host's public address, and a server bound to 127.0.0.1 is never reached.
umask 077
cat > "$ENVFILE" <<EOF
# Written by deploy.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ). Do not edit by hand:
# the next deploy overwrites it. Change the workflow inputs instead.
QUEENS_ENV=prod
QUEENS_ADDR=:$QUEENS_PORT
QUEENS_DB=$DB
QUEENS_BACKUP_DIR=$BACKUPS
QUEENS_TRUST_PROXY=true
QUEENS_LOG_LEVEL=info
QUEENS_NO_SESSION_GRACE_UNTIL=$QUEENS_NO_SESSION_GRACE_UNTIL
QUEENS_TOKEN_PEPPER=$QUEENS_TOKEN_PEPPER
EOF
chmod 600 "$ENVFILE"
umask 022

# ---------------------------------------------------------------- pre-flight

# The failure that actually takes production down is levelset.Sync refusing a
# changed level, which aborts the process *before* it binds. Catch it here,
# against a throwaway copy of the real database, while the old build is still
# serving. The backup this needs is the pre-deploy backup we want anyway.
schema_changed=0
if [ -f "$DB" ] && [ -x "$LINK" ]; then
  say "Pre-flight against a copy of the live database"
  snapshot="$BACKUPS/pre-$RELEASE_SHA.db"
  # In a subshell: the env file must not leak into the rest of the script.
  ( set -a; . "$ENVFILE"; set +a; "$LINK" backup -o "$snapshot" )

  preflight="$(mktemp)"
  if ! QUEENS_DB="$snapshot" QUEENS_ENV=dev QUEENS_TOKEN_PEPPER=preflight \
       "$TARGET/queensd" migrate >"$preflight" 2>&1; then
    cat "$preflight"
    rm -f "$preflight"
    die "the new build cannot open the live schema or the level set changed. Nothing was swapped."
  fi
  if grep -q 'migration applied' "$preflight"; then
    schema_changed=1
    echo "NOTE: this deploy applies new migrations:"
    grep 'migration applied' "$preflight"
  fi
  rm -f "$preflight"
  echo "ok: the new build migrates and imports the live data cleanly"
elif [ -f "$DB" ]; then
  say "A database exists but there is no current build to snapshot it with; skipping the pre-flight"
else
  say "No database yet; the first start will create it"
fi

# ---------------------------------------------------------------- swap

# Track the previous release as a DIRECTORY, not as the resolved binary path:
# the prune below compares against the directories the glob yields, and
# dirname keeps both sides in the same shape.
# -e, not -L: if someone replaced the symlink with a plain copy during an
# incident we still want to know where it came from. The rollback below
# refuses anything that is not a release directory.
prev_dir=""
if [ -e "$LINK" ]; then
  prev_dir="$(dirname "$(readlink -f "$LINK")")"
fi

install -m 644 "$TARGET/queensd.service" "$UNIT"
systemctl --user daemon-reload
systemctl --user enable "$SERVICE" >/dev/null 2>&1

say "Swapping the symlink to $RELEASE_SHA"
ln -sfn "$TARGET/queensd" "$LINK.tmp"
mv -T "$LINK.tmp" "$LINK"

# A unit that hit its start limit in an earlier failure refuses to start until
# the counter is cleared, and would make this restart fail for no new reason.
systemctl --user reset-failed "$SERVICE" 2>/dev/null || true
# One second back, so the startup line cannot fall before the --since bound.
started_at=$(( $(date +%s) - 1 ))
systemctl --user restart "$SERVICE"

# ---------------------------------------------------------------- verify

rollback() {
  echo
  echo "---- last 200 log lines ----"
  journalctl --user --unit "$SERVICE" --lines 200 --output cat --no-pager 2>/dev/null || true
  echo "----------------------------"

  # This comes first, and unconditionally: when migrations have been applied
  # the operator needs the snapshot path whether or not the symlink rollback
  # below can run at all.
  if [ "$schema_changed" = 1 ]; then
    cat >&2 <<EOF

!! This deploy had already applied new migrations before it failed.
!! An older binary does NOT detect a newer schema -- it starts happily and may
!! fail at runtime on tables it does not know about, and /readyz will not
!! notice because it only pings the database.
!!
!! Verify writes by hand. To go back properly, restore:
!!   $BACKUPS/pre-$RELEASE_SHA.db
!! See deploy/README.md, "Rolling back across a migration".
EOF
  fi

  case "$prev_dir" in
    "$HOME"/releases/*) ;;
    *) prev_dir="" ;;
  esac
  if [ -z "$prev_dir" ] || [ "$prev_dir" = "$TARGET" ] || [ ! -x "$prev_dir/queensd" ]; then
    die "no previous release to roll back to. The service is down; fix it by hand."
  fi

  say "Rolling back to $prev_dir"
  ln -sfn "$prev_dir/queensd" "$LINK.tmp"
  mv -T "$LINK.tmp" "$LINK"
  systemctl --user reset-failed "$SERVICE" 2>/dev/null || true
  systemctl --user restart "$SERVICE" || true
  die "deploy failed; rolled back to the previous release"
}

say "Waiting for /readyz"
ready=0
for _ in $(seq 1 30); do
  if curl -fsS --max-time 2 "http://127.0.0.1:$QUEENS_PORT/readyz" >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 1
done
[ "$ready" = 1 ] || rollback

# /healthz is a constant, so it cannot tell a real deploy from a no-op. The
# startup line can: main.go logs "starting" with the linker-injected version.
say "Confirming the serving build"
if ! journal_since "$started_at" | grep -q "\"version\":\"$RELEASE_SHA\""; then
  echo "the startup line does not mention $RELEASE_SHA"
  rollback
fi
# Informational only; never fail the deploy over a log format change.
journal_since "$started_at" | grep '"msg":"starting"' | tail -1 || true

# ---------------------------------------------------------------- prune

# Everything from here on is housekeeping: the deploy has already succeeded,
# so nothing below may fail the run. `set -e` plus `pipefail` makes that easy
# to get wrong -- an `ls` over a glob that matches nothing exits 2 and would
# abort the script after a perfectly good deploy.
say "Pruning"
set +e

# Anything left behind by an interrupted upload.
rm -rf "$HOME"/releases/*.incoming

# shellcheck disable=SC2012
old_dirs="$(ls -1dt "$HOME"/releases/*/ 2>/dev/null | tail -n "+$((KEEP_RELEASES + 1))")"
for dir in $old_dirs; do
  dir="$(readlink -f "${dir%/}")"
  # Never delete what is running or what we would roll back to: after a
  # rollback the live release is not the newest one, and deleting it would
  # leave a dangling symlink at the next restart.
  if [ "$dir" = "$TARGET" ] || [ "$dir" = "$prev_dir" ]; then
    continue
  fi
  echo "removing $dir"
  rm -rf "$dir"
done

# runBackup's own retention only matches queens-*.db, so these would pile up.
# shellcheck disable=SC2012
old_snaps="$(ls -1t "$BACKUPS"/pre-*.db 2>/dev/null | tail -n +6)"
[ -n "$old_snaps" ] && rm -f $old_snaps

say "Deployed $RELEASE_SHA"
systemctl --user --no-pager --lines 0 status "$SERVICE"
set -e
