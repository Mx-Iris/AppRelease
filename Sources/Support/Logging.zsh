# Output helpers. The app_release_* ones are part of the contract with the hooks in Release.zsh.

# A step of the release, at the left margin.
app_release_log() {
    print -r -- "==> $*"
}

# A detail of the current step, indented under it.
app_release_detail() {
    print -r -- "    $*"
}

app_release_warn() {
    print -u2 -r -- "warning: $*"
}

# Stops the release. Inside a hook it stops the hook, and the engine then stops the release.
app_release_fail() {
    print -u2 -r -- "error: $*"
    exit 1
}

# The command as it would be typed, for --dry-run and for messages.
_app_release_quote_command() {
    print -r -- "${(j: :)${(q-)@}}"
}

# Runs a command, or under --dry-run only prints it.
_app_release_run() {
    if [[ $_app_release_is_dry_run == true ]]; then
        print -r -- "    + $(_app_release_quote_command "$@")"
        return 0
    fi
    "$@"
}

_app_release_timestamp() {
    date -u +%Y-%m-%dT%H:%M:%SZ
}

# Names the place of a failure that no explicit check caught; Engine.zsh installs it as the ZERR trap.
# Quiet where err_exit is off, because there a failing command is expected and handled
# (see _app_release_call_hook).
_app_release_report_unexpected_failure() {
    if [[ -o err_exit ]]; then
        print -u2 -r -- "error: unexpected failure (status $1) near ${funcfiletrace[1]:-an unknown place}"
    fi
}
