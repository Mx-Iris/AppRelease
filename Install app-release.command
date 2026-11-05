#!/bin/zsh -f
#
# Double-click in Finder to install the app-release launcher on this Mac: runs
# `app-release --install` from this folder, which copies it into ~/.local/bin. Safe to run again.

/bin/zsh -f "${0:A:h}/app-release" --install
install_status=$?
print
if (( install_status == 0 )); then
    print -r -- "Done."
else
    print -r -- "Failed with exit status $install_status; see the messages above."
fi
read -s -k 1 '?Press any key to close this window.'
print
exit $install_status
