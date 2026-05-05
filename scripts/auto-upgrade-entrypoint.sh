#!/usr/bin/env bash
set -e

# Opt-in: only run the auto-upgrade probe when AUTO_PG_UPGRADE=1.
# When enabled, detects a PG_VERSION mismatch between the mounted PGDATA
# and this image, and runs pg_upgrade as the postgres user before chaining
# to the official entrypoint.
if [ "${AUTO_PG_UPGRADE:-0}" = "1" ] \
        && [ "$(id -u)" = "0" ] \
        && [ -s "${PGDATA}/PG_VERSION" ]; then
    OLD_VER="$(cat "${PGDATA}/PG_VERSION")"
    if [ "$OLD_VER" != "$PG_MAJOR" ]; then
        chown -R postgres:postgres "$PGDATA" "$(dirname "$PGDATA")"
        gosu postgres /usr/local/bin/pg-auto-upgrade.sh
    fi
fi

exec docker-entrypoint.sh "$@"
