#!/bin/sh
# Runs one PhotoRec recovery for Ritrovo, possibly as root.
# Usage: ritrovo-run.sh <uid:gid> <session_dir> <stop_file> <done_file> <photorec> [args...]
# - creating <stop_file> sends SIGINT: PhotoRec saves its session and quits
# - <done_file> receives the exit code at the end
# - the session folder is given back to the user who started the recovery
OWNER=$1
WORK=$2
STOP=$3
DONE=$4
shift 4
cd "$WORK" || exit 1
rm -f "$STOP" "$DONE"
"$@" </dev/null >/dev/null 2>&1 &
PID=$!
while kill -0 "$PID" 2>/dev/null; do
  if [ -e "$STOP" ]; then
    kill -INT "$PID" 2>/dev/null
    rm -f "$STOP"
  fi
  sleep 1
done
wait "$PID"
RC=$?
chown -R "$OWNER" "$WORK" 2>/dev/null
echo "$RC" > "$DONE"
chown "$OWNER" "$DONE" 2>/dev/null
exit 0
