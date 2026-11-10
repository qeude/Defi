# Sourced by test_vm.sh and perf_release.sh with VM set: boots the windowless guest and reaches it over ssh.
# Call vm_start only while holding the VM lock; it restarts a running VM and stops it on exit.
KEY="$HOME/.tart/${VM}_ed25519"

vm() {
  ssh -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o BatchMode=yes \
    "admin@$(tart ip "$VM")" "$@"
}

vm_start() {
  # Restart a VM left running: it may lack the Xcode share. Holding the lock makes this safe.
  tart stop "$VM" >/dev/null 2>&1 || true
  XCODE="$(cd "$(xcode-select -p)/../.." && pwd)"
  nohup tart run "$VM" --no-graphics --no-audio "--dir=xcode:$XCODE:ro" >/dev/null 2>&1 &
  trap 'tart stop "$VM" >/dev/null || true' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  tart ip "$VM" --wait 180 >/dev/null
  for attempt in {1..60}; do
    tart exec "$VM" /usr/bin/true 2>/dev/null && break
    [[ "$attempt" -lt 60 ]] || { echo "The VM guest agent did not answer" >&2; exit 1; }
    sleep 2
  done
  [[ -f "$KEY" ]] || ssh-keygen -q -t ed25519 -N '' -C "$VM" -f "$KEY"
  tart exec "$VM" /bin/sh -c "mkdir -p ~/.ssh && chmod 700 ~/.ssh && grep -qsF '$(cat "$KEY.pub")' ~/.ssh/authorized_keys || echo '$(cat "$KEY.pub")' >> ~/.ssh/authorized_keys; chmod 600 ~/.ssh/authorized_keys"
  vm 'sudo -n mdutil -a -i off >/dev/null 2>&1; defaults write com.apple.WindowManager StandardHideWidgets -int 1; mkdir -p ~/defi-e2e'

  # Earlier sessions' traces and recordings fill the guest's 41 GB disk until a run fails mid-way.
  vm 'sudo -n sh -s' <<'GUEST' || { echo "The VM guest disk is full even after cleaning; free space in it first" >&2; exit 1; }
free_kb() { df -k /System/Volumes/Data | awk 'NR == 2 { print $4 }'; }
find /Users/admin -xdev \( -name '*.trace' -o -name '*.ktrace' -o -name '*.mov' \) -mtime +0 -prune -exec rm -rf {} + 2>/dev/null
rm -rf /private/var/folders/*/*/C/com.apple.dt.InstrumentsCLI/path_manager
[ "$(free_kb)" -gt 3145728 ] || log erase --all >/dev/null
[ "$(free_kb)" -gt 1572864 ]
GUEST

  # Trim services Defi never touches; launchd keeps this across reboots, so it applies from the next boot.
  vm 'sudo -n sh -s' <<'GUEST'
[ ! -e /var/db/defi-e2e-tuned ] || exit 0
pattern='intelligen|siri|workflow|shortcut|imagent|imtransfer|facetime|cloud|bird|photo|mediaanalysis|knowledge|suggest|parsec|maps|news|weather|stocks|calendar|remind|game|music|podcast|appstore|commerce|triald|modelcatalog|generative|homed|backupd|corespotlight|biome'
for plist in /System/Library/LaunchAgents/*.plist; do
  label="$(basename "$plist" .plist)"
  if echo "$label" | grep -Eiq "$pattern"; then launchctl disable "gui/501/$label"; fi
done
for plist in /System/Library/LaunchDaemons/*.plist; do
  label="$(basename "$plist" .plist)"
  if echo "$label" | grep -Eiq "$pattern"; then launchctl disable "system/$label"; fi
done
# The image's login-item banner would otherwise stay up and block the pointer over it.
rm -rf "/Users/admin/Library/Group Containers/group.com.apple.usernoted/db2"
pkill -x usernoted
pkill -x NotificationCenter
touch /var/db/defi-e2e-tuned
GUEST

  # Post-boot daemons saturate the guest and would slow the tests' own timing.
  # Read instantaneous idle time: the load average keeps decaying for minutes after the burst ends.
  calm=0
  for _ in {1..60}; do
    if [[ "$(vm "top -l 2 -s 3 -n 0 | awk '/CPU usage/ {idle = \$7} END {print int(idle)}'")" -ge 70 ]]; then calm=$((calm + 1)); else calm=0; fi
    [[ "$calm" -ge 3 ]] && break
  done
}
