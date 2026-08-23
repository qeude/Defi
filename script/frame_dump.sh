#!/usr/bin/env bash
# Ground-truth on-screen frames for Ghostty windows and Defi border panels.
# Run this THE MOMENT the border desync appears; paste the output.
DAEMON_PID=$(pgrep -x defi-daemon)
xcrun swift "$(dirname "$0")/frame_dump.swift" 2>/dev/null || {
  DAEMON_PID=$DAEMON_PID swift "$(dirname "$0")/frame_dump.swift"
}
