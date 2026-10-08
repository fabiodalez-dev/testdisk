#!/bin/sh
# Runs one recovery engine process for Ritrovo, possibly as root.
# Usage: ritrovo-run.sh <uid> <gid> <work_dir> <stop_file> <seed|-> <command> [args...]
#
# Safe to run as root although the destination is user-writable:
# - <work_dir> must not exist: it is created here, by the running user, and
#   entered at once; every file is then written relative to it, never by path
# - the directory is checked to be the one just created (resolved path,
#   owner, empty), so a symlink swapped in before the cd is refused
# - <stop_file> is only tested for existence, it is never written or removed;
#   while it exists the stop is repeated, then forced (see below)
# - <seed> is a session file to resume: it is read as the user (never as
#   root, so it cannot expose a protected file) into ./.ritrovo.ses
# - at the end the files are given back with chown -R -P (no symlink is
#   followed) and the exit code goes to ./.done in the same directory
umask 022
OWNER_UID=$1
OWNER_GID=$2
WORK=$3
STOP=$4
SEED=$5
shift 5

case "$OWNER_UID$OWNER_GID" in
  *[!0-9]*|'') exit 2 ;;
esac

PARENT=$(cd -P "$(dirname "$WORK")" 2>/dev/null && pwd -P) || exit 3
EXPECTED="$PARENT/$(basename "$WORK")"
mkdir -m 755 "$EXPECTED" || exit 4
cd -P "$EXPECTED" || exit 5
[ "$(pwd -P)" = "$EXPECTED" ] || exit 6
[ "$(stat -f %u .)" = "$(id -u)" ] || exit 7
[ -z "$(ls -A .)" ] || exit 8

if [ "$SEED" != "-" ]; then
  if [ "$(id -u)" = 0 ]; then
    /usr/bin/sudo -n -u "#$OWNER_UID" /bin/cat "$SEED" > .ritrovo.ses || exit 9
  else
    /bin/cat "$SEED" > .ritrovo.ses || exit 9
  fi
fi

"$@" </dev/null >/dev/null 2>&1 &
PID=$!
STOPPED=0
while kill -0 "$PID" 2>/dev/null; do
  if [ -e "$STOP" ]; then
    # 1st SIGINT: the engine saves its session and quits. A process blocked
    # on a failing disk may not react: a 2nd SIGINT after 15 s ends it
    # (the engine's own behaviour), SIGKILL after 30 s.
    case "$STOPPED" in
      0) kill -INT "$PID" 2>/dev/null ;;
      15) kill -INT "$PID" 2>/dev/null ;;
      30) kill -KILL "$PID" 2>/dev/null ;;
    esac
    STOPPED=$((STOPPED + 1))
  fi
  sleep 1
done
wait "$PID"
RC=$?
# .done is written while the folder still belongs to root (nothing can be
# planted in it), then everything goes back to the user: the app waits for
# the ownership change before modifying the files.
echo "$RC" > .done.tmp && mv -f .done.tmp .done
if [ "$(id -u)" = 0 ]; then
  chown -R -P "$OWNER_UID:$OWNER_GID" . 2>/dev/null
fi
exit 0
