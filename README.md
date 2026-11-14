# RootLawk 0.3.1

A small tool that protects the root account on a jailbroken Akai MPC (Gen 1 standalone units such as the MPC One, One+, Live, Live II, X and Key 61 running an SSH-enabled firmware like Hakai).

SSH firmwares usually ship with a **blank root password**. Anyone on the same WiFi can then log in and take full control of the MPC. RootLawk closes that door and keeps it closed.

## What it does

- Detects whether the root password is blank, disabled or set
- Forces you to create a password when it is blank
- Asks for the current password before allowing changes, and locks for 5 minutes after 3 wrong tries
- Turns off blank-password SSH logins (keeps a backup of every file it changes)
- Keeps your password after restarts. On MPC firmware the password file is reset to blank at every boot; RootLawk saves the password's hash (never the password) in /etc/rootlawk and hooks into SSH's own startup, so the password is put back right before SSH opens. If the restore ever fails, SSH still starts, so you can't be locked out
- Closes the maker's certificate login. The MPC's read-only key file trusts "AZ01 Certificate Authority", so anyone holding a certificate signed by it could log in as root without your password once SSH is on. With keep on, SSH reads keys only from /etc/rootlawk/authorized_keys. Your password and keys you add still work. Turning keep off reopens it
- Adds an SSH key for one-tap login from Termius
- Never stores or prints your password; Linux keeps only a hash

> **Beta.** Tested on an MPC One+ (Gen 1) with Hakai 3.9.0. Reports from other models (Live, Live II, X, Key 61, Force) and from Mac users are very welcome: open an [Issue](../../issues) with your model, firmware version and a photo of the status screen.

## Download

Get the latest **RootLawk-x.y.z.zip** from [Releases](../../releases) (on the right of this page). Don't use the green "Code" button unless you know git.

## Install (easy way)

You need: your MPC on Hakai (or another SSH firmware) with SSH turned on, and a computer on the same WiFi.

1. Unzip the RootLawk folder on your computer.
2. Find your MPC's address on the MPC: **Menu > Preferences > Wi-Fi** (it looks like 192.168.1.23).
3. Run the installer:
   - **Windows:** double-click `Install-RootLawk.bat`
   - **Mac:** right-click `Install-RootLawk.command` > Open (or in Terminal: `sh Install-RootLawk.command`)
4. Type the MPC's address and press Enter, then choose **1) Install**.
5. Type your MPC root password when asked (twice, once to copy and once to run). If you've never set one, it won't ask. Then make up a root password and type it twice. Nothing shows while you type; that's normal. Write it down somewhere safe.
6. Restart the MPC, then run the installer again and choose **2) Show status** to check that your password survived.

Run the installer again any time to update RootLawk, check its status or remove it. Once a password is set, the installer asks for it before changing anything.

Windows 10/11 already include SSH. If the installer says it's missing: Settings > System > Optional features > Add "OpenSSH Client".

## Install (by hand, from Termius)

1. Copy `rootlawk.sh` to the top level of your MPC drive (for example MPCDRIVE) or a USB stick.
2. Log in: `ssh root@<MPC address>`
3. Run `sh /media/MPCDRIVE/rootlawk.sh --install` (use `ls /media` to see your drive names), or run it without `--install` for the menu.

## Use

| Command | What it does |
| --- | --- |
| `sh rootlawk.sh` | Menu: change password, keep after restarts, refuse blank logins, add SSH key, status |
| `sh rootlawk.sh --install` | One-step setup: set the password if blank, keep it after restarts, close the maker's login |
| `sh rootlawk.sh --uninstall` | Asks for your password, then removes RootLawk |
| `sh rootlawk.sh --status` | Shows password and SSH status |
| `sh rootlawk.sh --restore` | Put the saved password back (run automatically at startup) |
| `sh rootlawk.sh --check` | Exit code only, for other installers: 0 = set, 10 = blank, 11 = password login disabled |
| `sh rootlawk.sh --help` | Help |

## Tips

- While setting the password you may see `passwd: warning: can't create backup copy ... Stale file handle`. That's harmless: the MPC's system storage doesn't allow the backup copy. The next line, `password for root changed by root`, confirms it worked.

- When pasting a password, nothing appears on screen. That is normal.
- After turning off blank logins, keep your Termius window open and test a new login in a second window before closing the first.
- Other mods that log in with a blank password (for example MPC Link) will need your new password.

## Known limits

- Tested on: MPC One+ on Hakai 3.9.0 (Gen 1): fresh install, update, remove and restarts all passed with the installer, which has no bash; RootLawk runs in plain sh. /etc is a writable layer that survives reboots; / and /root are read-only.
- SSH keys are stored in /etc/rootlawk/authorized_keys, because /root is read-only on this firmware.
- An official Akai or Hakai update may remove the startup service. Run RootLawk again after any update.
- "Refuse blank-password SSH logins" is only offered after "Keep password after restarts" is on. On MPC firmware the SSH settings folder is also reset at every boot, so this setting lasts only until the next restart.
- Why not a normal startup service? The MPC reads its startup list before its writable /etc layer is mounted, so services added there never run at boot. Hakai starts SSH later, which is why RootLawk hooks in there.
- Whether changes survive a reboot depends on the firmware. After setting the password, restart the MPC and confirm the new password still works.
- Forgot your password? There's no recovery on the MPC itself; re-flash Hakai, then run the installer again.

## License

MIT, free to use, share and change. See [LICENSE](LICENSE). Provided as is, with no warranty: RootLawk changes your MPC's root password, so write your password down.
