#!/bin/sh
# RootLawk installer for Mac (and Linux). Double-click it, or in Terminal: sh Install-RootLawk.command
cd "$(dirname "$0")" || exit 1
printf '\n  RootLawk - password protection for your MPC\n\n'
printf '  Jailbroken MPCs (Hakai) come with NO root password, so anyone on your\n'
printf '  WiFi can take full control. RootLawk sets a password, keeps it after\n'
printf '  restarts, and closes the maker'"'"'s hidden login.\n\n'

[ -f rootlawk.sh ] || { echo "  [x] rootlawk.sh must be in the same folder as this installer."; exit 1; }
command -v ssh >/dev/null || { echo "  [x] ssh is missing on this computer."; exit 1; }

SAVED="$HOME/.rootlawk-mpc-address"
MPC=$(cat "$SAVED" 2>/dev/null)
echo "  Your MPC and this computer must be on the same WiFi."
echo "  Find the MPC's address on the MPC: Menu > Preferences > Wi-Fi (like 192.168.1.23)."
echo
while :; do
  if [ -n "$MPC" ]; then printf '  MPC address [press Enter for %s]: ' "$MPC"; else printf '  MPC address: '; fi
  read -r IN
  [ -n "$IN" ] && MPC=$IN
  case "$MPC" in ""|*[!0-9A-Za-z.-]*) echo "  [x] Use only numbers and dots, like 192.168.1.23"; MPC="" ;; *) break ;; esac
done
printf '%s\n' "$MPC" > "$SAVED"

printf '\n  1) Install or update RootLawk (recommended)\n  2) Show status\n  3) Remove RootLawk\n'
printf '  Choose 1-3 [1]: '; read -r CH
case "$CH" in 2) OPT=--status ;; 3) OPT=--uninstall ;; *) OPT=--install ;; esac

OPTS="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10"
echo
echo "  Connecting to root@$MPC ... It asks for your MPC root password twice: once to copy, once to run."
echo "  (Nothing shows while you type. If you never set one, it won't ask.)"
# shellcheck disable=SC2086
if ! scp $OPTS -q rootlawk.sh "root@$MPC:/tmp/rootlawk.sh" 2>/dev/null && \
   ! scp -O $OPTS -q rootlawk.sh "root@$MPC:/tmp/rootlawk.sh"; then
  echo
  echo "  [x] Couldn't reach the MPC at $MPC. Same WiFi? Right address? SSH on in Hakai?"
  echo "      After re-installing the firmware, run once: ssh-keygen -R $MPC"
  exit 1
fi
# shellcheck disable=SC2086
ssh -t $OPTS "root@$MPC" "sh /tmp/rootlawk.sh $OPT; rc=\$?; rm -f /tmp/rootlawk.sh; exit \$rc"
echo
printf '  Press Enter to close. '; read -r _
