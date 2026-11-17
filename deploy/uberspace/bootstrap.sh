#!/usr/bin/env bash
#
# One-time setup on the Uberspace 8 host. Run it by hand over ssh; it is NOT
# part of the pipeline, because it registers a web backend and because the
# checks in it want a human reading the output.
#
#   ssh <user>@<host>.uberspace.de 'bash -s' < deploy/uberspace/bootstrap.sh
#
# Afterwards, add the CI public key with `uberspace ssh key add` and fill in the
# GitHub secrets listed in deploy/README.md.
set -euo pipefail

PORT="${QUEENS_PORT:-8721}"
# A bare path is mounted on every domain of the account, the default
# <account>.uber.space included. A custom domain goes in front:
# QUEENS_BACKEND_PATH=api.example.de/ after `uberspace web domain add`.
BACKEND_PATH="${QUEENS_BACKEND_PATH:-/queens}"

say() { printf '\n==> %s\n' "$*"; }

say "Checking the account"
arch="$(uname -m)"
echo "  architecture: $arch"
if [ "$arch" != x86_64 ]; then
  echo "!! The Deploy server workflow builds for amd64. Change GOARCH there first." >&2
  exit 1
fi
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
state="$(systemctl --user is-system-running 2>&1 || true)"
echo "  systemd user instance: $state"
case "$state" in
  running|degraded) ;;
  *) echo "!! systemctl --user does not work over ssh here; the deploy depends on it." >&2; exit 1 ;;
esac

say "Creating the directory layout"
mkdir -p ~/bin ~/etc ~/.config/systemd/user ~/releases ~/queens/backups
# SQLite creates the database 0644 and runBackup creates its directory 0755.
# On a shared host that is every player row and every session, world-readable.
chmod 700 ~/queens ~/queens/backups
ls -ld ~/queens ~/queens/backups

say "Domains on this account"
uberspace web domain list

case "$BACKEND_PATH" in
  /*)
    echo "  $BACKEND_PATH is a bare path: it answers on every domain above,"
    echo "  https://$USER.uber.space$BACKEND_PATH included. No DNS to check."
    ;;
  *)
    DOMAIN="${BACKEND_PATH%%/*}"
    say "$DOMAIN must point here"
    # Worth doing properly rather than by eye, because the half-broken case is
    # invisible from a desktop: an AAAA that points at Uberspace and an A that
    # still points at the registrar's parking makes the site work over IPv6 and
    # fail for everyone else -- including GitHub runners, which have no IPv6.
    uberspace web domain show "$DOMAIN" || {
      echo "!! $DOMAIN is not on this account: uberspace web domain add $DOMAIN" >&2
      exit 1
    }
    me="$(hostname -f)"
    host_v4="$(getent ahostsv4 "$me"     | awk '{print $1}' | sort -u)"
    host_v6="$(getent ahostsv6 "$me"     | awk '{print $1}' | sort -u)"
    dom_v4="$( getent ahostsv4 "$DOMAIN" | awk '{print $1}' | sort -u)"
    dom_v6="$( getent ahostsv6 "$DOMAIN" | awk '{print $1}' | sort -u)"
    printf '  this host (%s)\n    A    %s\n    AAAA %s\n' "$me" "${host_v4:-none}" "${host_v6:-none}"
    printf '  %s\n    A    %s\n    AAAA %s\n' "$DOMAIN" "${dom_v4:-none}" "${dom_v6:-none}"
    dns_ok=1
    for want in $host_v4; do echo "$dom_v4" | grep -qx "$want" || dns_ok=0; done
    for want in $host_v6; do echo "$dom_v6" | grep -qx "$want" || dns_ok=0; done
    # Extra addresses are as bad as missing ones: traffic lands wherever they point.
    [ "$(echo "$dom_v4" | grep -c .)" = "$(echo "$host_v4" | grep -c .)" ] || dns_ok=0
    if [ "$dns_ok" != 1 ]; then
      echo "!! $DOMAIN does not resolve to this host, in both families. Set the" >&2
      echo "!! A and AAAA records 'uberspace web domain show $DOMAIN' prints." >&2
      exit 1
    fi
    echo "  ok: both families point at this host"
    ;;
esac

say "Routing $BACKEND_PATH to port $PORT"
# --remove-prefix is what lets the server keep its own /v1, /healthz and /readyz
# paths: it never learns it is mounted under a prefix.
if uberspace web backend list | grep -F -- "$BACKEND_PATH" | grep -qw -- "$PORT"; then
  echo "  already routed"
else
  uberspace web backend add "$BACKEND_PATH" port "$PORT" --remove-prefix
fi
uberspace web backend list

cat <<EOF

==> Remaining manual steps

  1. Add the CI deploy key:
       uberspace ssh key add "ssh-ed25519 AAAA... queens-deploy"

  2. Record the host keys for the UBERSPACE_SSH_KNOWN_HOSTS secret, from your
     own machine:
       ssh-keyscan $(hostname -f)

  3. Use the SAME pepper as before for the QUEENS_TOKEN_PEPPER secret. It is
     NEVER rotated -- see deploy/README.md. Only for a brand-new database:
       openssl rand -base64 32

  4. Run the Deploy server workflow. The first deploy creates the database,
     applies the migrations and imports the levels.

  5. After that first deploy, prove WAL works on this filesystem -- SQLite's
     WAL mode is hardcoded and needs real POSIX locks, which an NFS-backed home
     would not give:
       QUEENS_DB=~/queens/probe.db QUEENS_ENV=dev QUEENS_TOKEN_PEPPER=probe \\
         ~/bin/queensd migrate && ls -l ~/queens/probe.db-wal; rm -f ~/queens/probe.db*
EOF
