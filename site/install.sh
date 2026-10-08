#!/bin/sh
# Gwen installer:  curl -fsSL https://gwen-chi.vercel.app/install.sh | sh
# Clones (or updates) Gwen into ~/.gwen/src and runs `gwen install`, which compiles Gwen.app on this Mac,
# so the same line works on Apple silicon and Intel. GWEN_DIR picks another folder.
set -eu

main() {  # a function, so a download cut short runs nothing
    dir="${GWEN_DIR:-$HOME/.gwen/src}"
    [ "$(uname -s)" = Darwin ] || { echo "Gwen runs on macOS only." >&2; exit 1; }
    if ! xcode-select -p >/dev/null 2>&1; then  # git, swiftc and python3 all come with these
        xcode-select --install >/dev/null 2>&1 || true
        echo "Gwen needs Apple's command line tools. Finish the install that just opened, then run this again." >&2
        exit 1
    fi
    if [ -d "$dir/.git" ]; then
        git -C "$dir" pull --ff-only </dev/null
    else
        git clone --depth 1 https://github.com/mblancodev/gwen.git "$dir" </dev/null
    fi
    "$dir/bin/gwen" install </dev/null  # stdin is this script when piped from curl
}

main
