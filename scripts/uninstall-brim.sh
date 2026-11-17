#!/bin/zsh
# Removes Brim from this Mac completely: the app, its settings, its files, its saved Spotify sign-in, and the
# permissions it was given. Nothing else on the Mac is touched: every item below carries Brim's own name.
#
# Files go to the Trash, not straight away: if something was moved by mistake, it's still there to put back.
# Empty the Trash when you're sure.
#
#   zsh uninstall-brim.sh --dry-run   lists what it would do, changes nothing
#   zsh uninstall-brim.sh             does it
#
# Before running it (Brim's own switches, so macOS forgets them cleanly):
#   1. Brim → Settings → General: turn off "Open Brim at login".
#   2. If Spotify was connected: Settings → Media & Lyrics → Disconnect.
set -u
dry=0
[[ ${1:-} == --dry-run ]] && dry=1
bundle=com.theojones.Brim

step() { print -- "▸ $1"; }

if (( dry )); then
  print -- "Dry run: nothing is changed.\n"
else
  step "Quitting Brim"
  osascript -e 'tell application id "com.theojones.Brim" to quit' >/dev/null 2>&1
  sleep 2
  pkill -x Brim 2>/dev/null
  # Brim's Now Playing helper runs Apple's /usr/bin/perl with Brim's own framework: only that one is stopped.
  pkill -f 'MediaRemoteAdapter.framework.* stream' 2>/dev/null
fi

step "Brim's app and files (to the Trash)"
items=(
  "/Applications/Brim.app"
  "$HOME/Applications/Brim.app"
  "$HOME/Library/Application Support/Brim"
  "$HOME/Library/Application Support/$bundle"
  "$HOME/Library/Caches/$bundle"
  "$HOME/Library/HTTPStorages/$bundle"
  "$HOME/Library/HTTPStorages/$bundle.binarycookies"
  "$HOME/Library/Saved Application State/$bundle.savedState"
  "$HOME/Library/Logs/Brim"
  "$HOME/Library/Preferences/$bundle.plist"
)
stamp=$(date +%Y%m%d-%H%M%S)
found=0
for item in $items; do
  [[ -e $item ]] || continue
  found=1
  if (( dry )); then
    print -- "  would move to Trash: $item"
  else
    mv -- "$item" "$HOME/.Trash/${item:t} (Brim $stamp)" && print -- "  moved to Trash: $item"
  fi
done
(( found )) || print -- "  none found"

step "Brim's settings in memory"
if (( dry )); then
  defaults read $bundle >/dev/null 2>&1 && print -- "  would clear: defaults domain $bundle" || print -- "  none"
else
  # Clears macOS's cached copy too (the file alone isn't enough while it's cached).
  defaults delete $bundle >/dev/null 2>&1 && print -- "  cleared" || print -- "  none"
fi

step "Saved Spotify sign-in (Keychain item \"$bundle.spotify\")"
if security find-generic-password -s "$bundle.spotify" >/dev/null 2>&1; then
  if (( dry )); then
    print -- "  would delete it"
  else
    while security delete-generic-password -s "$bundle.spotify" >/dev/null 2>&1; do :; done
    print -- "  deleted"
  fi
else
  print -- "  none"
fi

step "Permissions given to Brim (Accessibility, Automation, Calendar, Bluetooth): Brim's entries only"
if (( dry )); then
  print -- "  would run: tccutil reset All $bundle"
else
  tccutil reset All $bundle >/dev/null 2>&1 && print -- "  reset" || print -- "  none to reset"
fi

print -- "\nDone. Optional: restart the Mac, then empty the Trash when you're sure."
print -- "If Spotify was connected, also remove Brim at spotify.com/account/apps (and the app you made on developer.spotify.com)."
