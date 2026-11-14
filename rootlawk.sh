#!/bin/sh
# RootLawk - root password guard for jailbroken Akai MPCs
# (Gen 1 standalone units running an SSH-enabled firmware such as Hakai)
#
# What it does:
#   * Detects whether the root account is open (blank password), locked, or set
#   * Forces a password to be set when the account is open
#   * Asks for the current password before allowing changes (owner check)
#   * Locks itself for a few minutes after repeated wrong guesses
#   * Can turn off blank-password SSH logins and add SSH keys
#
# It never stores or prints your password. Linux keeps only a hash of it.
#
# Usage:
#   rootlawk            interactive menu (run as root)
#   rootlawk --status   print the password status
#   rootlawk --check    exit code only: 0 = set, 10 = open (blank), 11 = no password login
#   rootlawk --restore  put the saved password back (used at startup)
#   rootlawk --install  one-step setup (used by the PC/Mac installers): set the
#                       password if blank, keep it after restarts, show status
#   rootlawk --uninstall  owner check, then remove RootLawk from this MPC
#
# On MPC firmware the password file is reset to blank at every restart.
# RootLawk saves your password's hash (never the password itself) and installs a
# small startup service that puts it back after every boot.
#   rootlawk --help
#
# Exit codes for --check are used by other installers to refuse to continue on an open unit.

set -u

VERSION="0.3.1"
SHADOW_FILE="${ROOTLAWK_SHADOW:-/etc/shadow}"         # override only for testing
SSHD_CONF="${ROOTLAWK_SSHD_CONF:-/etc/ssh/sshd_config}"
SSHD_CONF_DIR="${SSHD_CONF}.d"
LOCKFILE="${ROOTLAWK_LOCKFILE:-/tmp/rootlawk.lock}"
KEEP_DIR="${ROOTLAWK_ETC:-/etc/rootlawk}"            # survives reboots on MPC firmware
SAVED_HASH="$KEEP_DIR/root.hash"
RESTORE_SCRIPT="$KEEP_DIR/restore.sh"
UNIT_DIR="${ROOTLAWK_UNIT_DIR:-/etc/systemd/system}"
MAX_TRIES=3
LOCK_SECS=300

# ---------- output helpers ----------
if [ -t 1 ]; then
  ESC=$(printf '\033')
  C_RED="${ESC}[31m"; C_GRN="${ESC}[32m"; C_YEL="${ESC}[33m"; C_BLD="${ESC}[1m"; C_OFF="${ESC}[0m"
else
  C_RED=""; C_GRN=""; C_YEL=""; C_BLD=""; C_OFF=""
fi
info() { printf '%s\n' "$*"; }
ok()   { printf '%s[ok]%s %s\n' "$C_GRN" "$C_OFF" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_YEL" "$C_OFF" "$*"; }
err()  { printf '%s[x]%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; }
die()  { err "$*"; exit 1; }

# Prompts that work in any POSIX shell (the MPC has no bash).
# Prompts go to stderr so $( ) captures only the answer.
ask() {
  local ans
  printf '%s' "$1" >&2
  IFS= read -r ans
  printf '%s' "$ans"
}
read_secret() {
  local ans
  printf '%s' "$1" >&2
  stty -echo 2>/dev/null
  IFS= read -r ans
  stty echo 2>/dev/null
  printf '\n' >&2
  printf '%s' "$ans"
}
trap 'stty echo 2>/dev/null' EXIT INT TERM

require_root() {
  [ "$(id -u)" -eq 0 ] || die "Run RootLawk as root (log in with: ssh root@<MPC address>)."
}

# ---------- password status ----------
# Prints the root password field from the shadow file (or passwd file as a fallback).
root_hash() {
  local h=""
  if [ -r "$SHADOW_FILE" ]; then
    h=$(awk -F: '$1=="root"{print $2; exit}' "$SHADOW_FILE")
  elif [ -r /etc/passwd ]; then
    h=$(awk -F: '$1=="root"{print $2; exit}' /etc/passwd)
  fi
  printf '%s' "$h"
}

# Prints OPEN, LOCKED or SET.
password_status() {
  local h
  h=$(root_hash)
  case "$h" in
    "")            echo OPEN ;;      # blank: anyone can log in
    "*"*|"!"*|"x") echo LOCKED ;;    # no password login possible
    *)             echo SET ;;
  esac
}

# ---------- password verification ----------
# verify_password <password> <hash>
# Returns 0 = match, 1 = no match, 3 = no tool on this unit can check this hash type.
# The password is passed on stdin, never on the command line.
verify_password() {
  local pw="$1" hash="$2" id salt rest computed salt_custom
  case "$hash" in
    \$*\$*\$*)
      rest="${hash#\$}"; id="${rest%%\$*}"; rest="${rest#*\$}"; salt="${rest%%\$*}"
      ;;
    *) id=""; salt="" ;;
  esac

  # 1) openssl handles $1$, $5$, $6$ (not custom rounds=)
  case "$salt" in rounds=*) salt_custom=1 ;; *) salt_custom=0 ;; esac
  if command -v openssl >/dev/null 2>&1 && [ -n "$id" ] && [ "$salt_custom" -eq 0 ]; then
    case "$id" in
      1|5|6)
        computed=$(printf '%s\n' "$pw" | openssl passwd "-$id" -salt "$salt" -stdin 2>/dev/null)
        if [ -n "$computed" ]; then
          [ "$computed" = "$hash" ] && return 0 || return 1
        fi
        ;;
    esac
  fi
  # 2) python3 crypt module (removed in Python 3.13, so it may be missing)
  if command -v python3 >/dev/null 2>&1; then
    computed=$(printf '%s\n' "$pw" | python3 -c '
import sys
try:
    import crypt
except Exception:
    sys.exit(3)
p = sys.stdin.readline().rstrip("\n")
print(crypt.crypt(p, sys.argv[1]) or "")
' "$hash" 2>/dev/null)
    if [ $? -eq 0 ] && [ -n "$computed" ]; then
      [ "$computed" = "$hash" ] && return 0 || return 1
    fi
  fi
  # 3) perl crypt()
  if command -v perl >/dev/null 2>&1; then
    computed=$(printf '%s\n' "$pw" | perl -e '$p=<STDIN>; chomp $p; print crypt($p, $ARGV[0]) // ""' "$hash" 2>/dev/null)
    if [ -n "$computed" ]; then
      [ "$computed" = "$hash" ] && return 0 || return 1
    fi
  fi
  return 3
}

# ---------- lockout after wrong guesses ----------
lock_remaining() {
  local count since now
  [ -f "$LOCKFILE" ] || { echo 0; return; }
  read -r count since < "$LOCKFILE" 2>/dev/null || { echo 0; return; }
  now=$(date +%s)
  if [ "${count:-0}" -ge "$MAX_TRIES" ] && [ $((now - ${since:-0})) -lt "$LOCK_SECS" ]; then
    echo $((LOCK_SECS - (now - since)))
  else
    echo 0
  fi
}
record_failure() {
  local count=0 since now
  now=$(date +%s)
  if [ -f "$LOCKFILE" ]; then read -r count since < "$LOCKFILE" 2>/dev/null || count=0; fi
  # start a fresh window if the old lock has expired
  if [ $((now - ${since:-0})) -ge "$LOCK_SECS" ]; then count=0; fi
  count=$((count + 1))
  printf '%s %s\n' "$count" "$now" > "$LOCKFILE"
  chmod 600 "$LOCKFILE" 2>/dev/null
}
clear_failures() { rm -f "$LOCKFILE"; }

# Asks for the current password. Returns 0 when the owner is confirmed.
confirm_owner() {
  local left pw rc hash
  left=$(lock_remaining)
  if [ "$left" -gt 0 ]; then
    err "Too many wrong tries. RootLawk is locked for $left more seconds."
    return 1
  fi
  hash=$(root_hash)
  pw=$(read_secret "Current root password: ")
  verify_password "$pw" "$hash"; rc=$?
  pw=""
  case $rc in
    0) clear_failures; ok "Owner confirmed."; return 0 ;;
    3) warn "This unit has no tool to check the password (no openssl, python3 crypt or perl)."
       warn "You already logged in as root with it, so RootLawk will continue."
       return 0 ;;
    *) record_failure
       left=$(lock_remaining)
       if [ "$left" -gt 0 ]; then err "Wrong password. Locked for $left seconds."
       else err "Wrong password."; fi
       return 1 ;;
  esac
}

# ---------- making changes ----------
# Checks that a directory can be written, without remounting anything.
# On MPC firmware the system drive (/) is read-only, but /etc sits on a
# writable layer that survives reboots, so changes there are safe.
ensure_writable() {
  local dir="${1:-/etc}" probe
  probe="$dir/.rootlawk-write-test.$$"
  if ( : > "$probe" ) 2>/dev/null; then
    rm -f "$probe"
    return 0
  fi
  err "Cannot write to $dir (it is read-only). Nothing was changed."
  warn "RootLawk will not remount the system drive. Ask for help before changing that."
  return 1
}

set_password() {
  ensure_writable /etc || return 1
  info ""
  info "Paste your new password, press Enter, then paste it again and press Enter."
  info "Nothing appears on screen while you paste. That is normal."
  local tries=0
  local alg=""
  passwd --help 2>&1 | grep -q -- '-a ALG' && alg="-a sha512"
  # shellcheck disable=SC2086
  until passwd $alg root; do
    tries=$((tries + 1))
    [ $tries -ge 3 ] && { err "Password was not changed."; return 1; }
    warn "Passwords did not match or were rejected. Try again."
  done
  sync
  if [ "$(password_status)" = SET ]; then
    ok "Root password is set."
    warn "Other mods that log in with a blank password (for example MPC Link) now need this password."
    if keep_installed; then save_hash && ok "Saved for restarts."; fi
    return 0
  fi
  err "Something went wrong: the password still reads as not set."
  return 1
}

sshd_allows_empty() {
  local f
  for f in "$SSHD_CONF" "$SSHD_CONF_DIR"/*.conf; do
    [ -f "$f" ] || continue
    grep -Eiq '^[[:space:]]*PermitEmptyPasswords[[:space:]]+yes' "$f" && return 0
  done
  return 1
}

harden_sshd() {
  if ! sshd_allows_empty; then
    ok "SSH already refuses blank-password logins."
    return 0
  fi
  if [ "$(password_status)" != SET ]; then
    err "Set a root password first, or you could lock yourself out."
    return 1
  fi
  ensure_writable "$(dirname "$SSHD_CONF")" || return 1
  local f stamp
  stamp=$(date +%Y%m%d-%H%M%S)
  for f in "$SSHD_CONF" "$SSHD_CONF_DIR"/*.conf; do
    [ -f "$f" ] || continue
    if grep -Eiq '^[[:space:]]*PermitEmptyPasswords[[:space:]]+yes' "$f"; then
      cp -p "$f" "$f.rootlawk-$stamp.bak" || { err "Could not back up $f"; return 1; }
      awk '{ if (tolower($0) ~ /^[ \t]*permitemptypasswords[ \t]+yes/) { sub(/[Pp][Ee][Rr][Mm][Ii][Tt][Ee][Mm][Pp][Tt][Yy][Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd][Ss][ \t]+[Yy][Ee][Ss]/, "PermitEmptyPasswords no") } print }' "$f" > "$f.rootlawk-tmp" \
        && cat "$f.rootlawk-tmp" > "$f" && rm -f "$f.rootlawk-tmp" \
        || { err "Could not update $f"; return 1; }
      ok "Updated $f (backup: $f.rootlawk-$stamp.bak)"
    fi
  done
  sync
  if command -v systemctl >/dev/null 2>&1; then
    systemctl reload sshd 2>/dev/null || systemctl restart sshd 2>/dev/null
  fi
  ok "Blank-password SSH logins are now refused."
  warn "Keep this window open. Open a second Termius session to test logging in before you close this one."
}

add_ssh_key() {
  local key dir="/root/.ssh" auth="/root/.ssh/authorized_keys"
  info "Paste the PUBLIC key from Termius (Keychain > your key > Export/Copy public key)."
  info "It starts with ssh-ed25519, ssh-rsa or ecdsa-sha2."
  key=$(ask "Public key: ")
  case "$key" in
    ssh-ed25519\ *|ssh-rsa\ *|ecdsa-sha2-*\ *) ;;
    *) err "That does not look like a public key. Nothing was changed."; return 1 ;;
  esac
  if lock_on; then
    dir="$KEEP_DIR"; auth="$OWN_KEYS"
  elif ! ensure_writable /root 2>/dev/null && ! { mkdir -p "$dir" 2>/dev/null && ensure_writable "$dir"; }; then
    err "/root is read-only here. Turn on 'Keep password after restarts' first; it gives SSH keys a home."
    return 1
  else
    mkdir -p "$dir" && chmod 700 "$dir"
  fi
  touch "$auth" && chmod 600 "$auth"
  if grep -qxF "$key" "$auth"; then
    ok "That key is already installed."
  else
    printf '%s\n' "$key" >> "$auth"
    sync
    ok "Key added. Termius can now log in with it."
  fi
}

# ---------- keep the password after restarts ----------
save_hash() {
  local h
  h=$(root_hash)
  case "$h" in ""|"*"*|"!"*) return 1 ;; esac
  mkdir -p "$KEEP_DIR" && chmod 700 "$KEEP_DIR" || return 1
  ( umask 077; printf '%s\n' "$h" > "$SAVED_HASH" ) || return 1
  chmod 600 "$SAVED_HASH"
  return 0
}

# Puts the saved hash back into the password file if it was reset. Safe to run any time.
restore_hash() {
  local want have tmp
  [ -r "$SAVED_HASH" ] || return 0
  want=$(cat "$SAVED_HASH")
  [ -n "$want" ] || return 0
  have=$(root_hash)
  [ "$have" = "$want" ] && return 0
  tmp="$SHADOW_FILE.rootlawk-tmp"
  awk -F: -v OFS=: -v h="$want" '$1=="root"{$2=h} {print}' "$SHADOW_FILE" > "$tmp" || { rm -f "$tmp"; return 1; }
  grep -q '^root:' "$tmp" || { rm -f "$tmp"; return 1; }
  cat "$tmp" > "$SHADOW_FILE" && rm -f "$tmp"
  chmod 600 "$SHADOW_FILE" 2>/dev/null
  sync
  command -v logger >/dev/null 2>&1 && logger -t rootlawk "root password restored after reset"
  return 0
}

# The MPC deletes passwd/shadow from its writable /etc layer at every boot, and it
# reads its startup list before that layer exists, so units in /etc never run at
# boot. Hakai starts sshd later with "systemctl start sshd", which loads sshd's
# settings fresh, so a drop-in on sshd restores the password before SSH opens.
# The "-" prefix means a failed restore never stops SSH from starting.
DROPIN_DIR="$UNIT_DIR/sshd.service.d"
DROPIN="$DROPIN_DIR/rootlawk.conf"
# The MPC's read-only /root/.ssh/authorized_keys trusts the maker's certificate
# authority ("AZ01 Certificate Authority"), so anyone with a certificate signed by
# it can log in as root without the password. RootLawk points SSH at its own key
# file instead, which ignores that line. Your password and your own keys still work.
OWN_KEYS="$KEEP_DIR/authorized_keys"
SSHD_BIN="${ROOTLAWK_SSHD_BIN:-/usr/sbin/sshd}"
LOCK_OPTS="-o AuthorizedKeysFile=$OWN_KEYS -o TrustedUserCAKeys=none -o AuthorizedKeysCommand=none"

lock_on() {
  [ -f "$DROPIN" ] && grep -q "AuthorizedKeysFile=$OWN_KEYS" "$DROPIN"
}

keep_installed() {
  [ -f "$DROPIN" ] && [ -r "$SAVED_HASH" ] && [ -r "$KEEP_DIR/rootlawk.sh" ]
}

remove_old_units() {
  if command -v systemctl >/dev/null 2>&1; then
    systemctl disable rootlawk-restore.path rootlawk-restore.service >/dev/null 2>&1
  fi
  rm -f "$UNIT_DIR/rootlawk-restore.service" "$UNIT_DIR/rootlawk-restore.path"
}

install_keep() {
  local self
  [ "$(password_status)" = SET ] || { err "Set a root password first."; return 1; }
  ensure_writable /etc || return 1
  save_hash || { err "Could not save the password hash."; return 1; }
  self=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")
  if [ "$self" != "$KEEP_DIR/rootlawk.sh" ]; then
    cp "$self" "$KEEP_DIR/rootlawk.sh" || { err "Could not copy RootLawk into $KEEP_DIR."; return 1; }
  fi
  chmod 700 "$KEEP_DIR/rootlawk.sh"
  remove_old_units
  mkdir -p "$DROPIN_DIR" || return 1
  touch "$OWN_KEYS" && chmod 600 "$OWN_KEYS"
  # Only close the maker's login if this sshd accepts the settings; otherwise just keep the password.
  if [ -x "$SSHD_BIN" ] && "$SSHD_BIN" -t $LOCK_OPTS >/dev/null 2>&1; then
    printf '[Service]\nExecStartPre=-/bin/sh %s/rootlawk.sh --restore\nExecStart=\nExecStart=-%s -D %s $SSHD_OPTS\n' \
      "$KEEP_DIR" "$SSHD_BIN" "$LOCK_OPTS" > "$DROPIN" || { err "Could not write $DROPIN."; return 1; }
  else
    printf '[Service]\nExecStartPre=-/bin/sh %s/rootlawk.sh --restore\n' "$KEEP_DIR" > "$DROPIN" \
      || { err "Could not write $DROPIN."; return 1; }
  fi
  command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload >/dev/null 2>&1
  sync
  ok "Your password will now come back automatically after every restart."
  if lock_on; then
    ok "The maker's certificate login is closed (takes effect the next time SSH starts)."
  else
    warn "Could not close the maker's certificate login on this firmware."
  fi
  warn "Test it: restart the MPC, then run: sh rootlawk.sh --status"
}

remove_keep() {
  remove_old_units
  rm -f "$DROPIN" "$SAVED_HASH"
  rmdir "$DROPIN_DIR" 2>/dev/null
  command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload >/dev/null 2>&1
  sync
  ok "Keep turned off. The password will be blank again after the next restart."
  warn "The maker's certificate login opens again the next time SSH starts."
}

print_status() {
  local s
  s=$(password_status)
  case "$s" in
    OPEN)   err "Root password: NOT SET (anyone on your network can take full control)" ;;
    LOCKED) warn "Root password: password login disabled" ;;
    SET)    ok "Root password: set" ;;
  esac
  if [ -f "$SSHD_CONF" ]; then
    if ! sshd_allows_empty; then ok "SSH: refuses blank-password logins"
    elif [ "$s" = SET ]; then ok "SSH: no blank-password logins possible (your password is set)"
    else warn "SSH: allows blank-password logins"; fi
  fi
  if keep_installed; then ok "Keep password after restarts: on"
  else warn "Keep password after restarts: off (MPC firmware resets it at every restart)"; fi
  if lock_on; then
    ok "Maker certificate login: closed"
    if [ -s "$OWN_KEYS" ]; then ok "Your SSH keys: $(grep -c . "$OWN_KEYS")"; else info "Your SSH keys: 0"; fi
  else
    if grep -q '^cert-authority' /root/.ssh/authorized_keys 2>/dev/null; then
      warn "Maker certificate login: open (turn on 'Keep password after restarts' to close it)"
    fi
    if [ -s /root/.ssh/authorized_keys ]; then
      info "SSH keys in /root: $(grep -c . /root/.ssh/authorized_keys)"
    fi
  fi
}

# One-step setup for the installers. Never leaves the MPC with a blank password.
install_flow() {
  require_root
  info "${C_BLD}RootLawk $VERSION installer${C_OFF}"
  case "$(password_status)" in
    OPEN)
      if [ -r "$SAVED_HASH" ] && restore_hash && [ "$(password_status)" = SET ]; then
        ok "Your saved password was put back."
        confirm_owner || exit 1
      else
        warn "Your MPC has NO root password: anyone on your WiFi can take full control."
        info "Create one now. Use a password you don't use anywhere else, and write it down."
        until set_password; do
          warn "A password is required. Let's try again (Ctrl+C to quit)."
        done
      fi ;;
    LOCKED)
      warn "Password login is turned off on this MPC, so RootLawk isn't needed. Nothing was changed."
      exit 0 ;;
    SET)
      ok "Root password is set."
      info "Type your MPC root password to update RootLawk."
      confirm_owner || exit 1 ;;
  esac
  install_keep || exit 1
  info ""
  print_status
  info ""
  ok "All done. Restart the MPC, then log in with your password to check it stuck."
}

uninstall_flow() {
  require_root
  [ "$(password_status)" = SET ] && { confirm_owner || exit 1; }
  remove_keep
  rm -f "$KEEP_DIR/rootlawk.sh" "$OWN_KEYS"
  rmdir "$KEEP_DIR" 2>/dev/null
  sync
  ok "RootLawk removed. Your password stays until the next restart, then the MPC firmware blanks it."
  warn "After the next restart anyone on your WiFi can log in again. Run the installer to protect it."
}

menu() {
  local choice
  while true; do
    info ""
    info "${C_BLD}RootLawk $VERSION${C_OFF}"
    info "  1) Change root password"
    info "  2) Keep password after restarts (recommended on MPC)"
    info "  3) Refuse blank-password SSH logins"
    info "  4) Add an SSH key (one-tap login)"
    info "  5) Show status"
    info "  6) Turn off keep-after-restarts"
    info "  7) Quit"
    choice=$(ask "Choose 1-7: ")
    case "$choice" in
      1) set_password ;;
      2) install_keep ;;
      3) if keep_installed; then harden_sshd
         else warn "Turn on option 2 first, or a restart could lock SSH out."; fi ;;
      4) add_ssh_key ;;
      5) print_status ;;
      6) remove_keep ;;
      7|q|Q) exit 0 ;;
      *) warn "Pick a number from 1 to 7." ;;
    esac
  done
}

main() {
  case "${1:-}" in
    --check)
      case "$(password_status)" in SET) exit 0 ;; OPEN) exit 10 ;; *) exit 11 ;; esac ;;
    --status)  print_status; exit 0 ;;
    --restore) require_root; restore_hash; exit $? ;;
    --version) echo "RootLawk $VERSION"; exit 0 ;;
    --install) install_flow; exit 0 ;;
    --uninstall) uninstall_flow; exit 0 ;;
    -h|--help) sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    "") ;;
    *) die "Unknown option: $1 (try --help)" ;;
  esac

  require_root
  info "${C_BLD}RootLawk $VERSION${C_OFF}"

  case "$(password_status)" in
    OPEN)
      if [ -r "$SAVED_HASH" ]; then
        warn "The password was reset to blank. Putting your saved password back..."
        restore_hash && [ "$(password_status)" = SET ] && ok "Saved password restored." && { confirm_owner || exit 1; menu; }
      fi
      err "YOUR MPC IS UNPROTECTED: the root password is blank."
      err "Anyone on your network can log in and take full control."
      info "You must create a root password before doing anything else."
      until set_password; do
        warn "A password is required. Let's try again (Ctrl+C to quit)."
      done
      a=$(ask "Keep this password after restarts? (recommended on MPC) [Y/n] ")
      case "$a" in n|N) ;; *) install_keep ;; esac
      ;;
    LOCKED)
      warn "Root password login is disabled on this unit."
      a=$(ask "Set a root password now? [y/N] ")
      case "$a" in y|Y) set_password ;; esac
      ;;
    SET)
      ok "Root password is set."
      confirm_owner || exit 1
      ;;
  esac
  menu
}

main "$@"
