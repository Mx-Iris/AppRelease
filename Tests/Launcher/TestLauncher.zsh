# The launcher runs the engine version the project pins, fetching it once into its cache.

typeset -g engine_repository= cache_directory= launcher_directory= launcher_errors=

# A local stand-in for github.com/Mx-Iris/AppRelease whose tags 0.9.0 and 1.0.0 hold this engine,
# each reporting its own version; and a copy of the launcher, the way --install leaves it.
make_engine_repository() {
    engine_repository=${test_project:h}/EngineRepository
    cache_directory=${test_project:h}/Cache
    launcher_directory=${test_project:h}/Bin
    mkdir -p "$engine_repository" "$launcher_directory"
    cp -R "$testing_engine_root/app-release" "$testing_engine_root/Sources" "$engine_repository/"
    cp "$testing_engine_root/app-release" "$launcher_directory/app-release"
    git -C "$engine_repository" init -q -b main
    local version
    for version in 0.9.0 1.0.0; do
        print -r -- "$version" > "$engine_repository/Sources/Version"
        git -C "$engine_repository" add -A
        git -C "$engine_repository" -c user.name=Tests -c user.email=tests@example.com commit -q -m "Version $version"
        git -C "$engine_repository" tag "$version"
    done
}

pin_engine_version() {
    local release_file=$test_project/Release.zsh
    local -a lines=("${(@f)$(<$release_file)}")
    lines=(${lines:#release_engine_version=*})
    print -rl -- "${lines[@]}" > "$release_file"
    if [[ -n $1 ]]; then
        print -r -- "release_engine_version=$1" >> "$release_file"
    fi
    commit_all "Pin AppRelease ${1:-nothing}"
}

# Runs the installed copy of the launcher; standard output and standard error stay apart.
run_installed_launcher() {
    test_status=0
    local error_path=${test_project:h}/launcher-errors.txt
    test_output=$(cd "$test_project" && APP_RELEASE_REPOSITORY_URL=file://$engine_repository \
        APP_RELEASE_CACHE_DIRECTORY=$cache_directory "$launcher_directory/app-release" "$@" 2> "$error_path") || test_status=$?
    launcher_errors=$(<$error_path)
}

test_the_launcher_fetches_and_runs_the_pinned_version() {
    make_project
    make_engine_repository
    pin_engine_version 0.9.0
    run_installed_launcher version
    expect_success
    expect_equal 0.9.0 "$test_output" "engine version that ran"
    [[ $launcher_errors == *"fetching AppRelease 0.9.0"* ]] || fail_test "expected a fetch; standard error was: $launcher_errors"
    expect_equal 0.9.0 "$(<$cache_directory/0.9.0/Sources/Version)" "cached engine version"
}

test_the_launcher_reuses_a_cached_version() {
    make_project
    make_engine_repository
    pin_engine_version 1.0.0
    run_installed_launcher version
    expect_success
    run_installed_launcher version
    expect_success
    expect_equal 1.0.0 "$test_output" "engine version that ran"
    [[ $launcher_errors != *fetching* ]] || fail_test "expected no second fetch; standard error was: $launcher_errors"
}

test_a_project_that_pins_nothing_is_refused() {
    make_project
    make_engine_repository
    pin_engine_version ""
    run_installed_launcher version
    (( test_status != 0 )) || fail_test "expected the launcher to refuse a project without a pin"
    [[ $launcher_errors == *"does not pin the engine"* ]] || fail_test "unexpected standard error: $launcher_errors"
}

test_a_pinned_version_that_does_not_exist_is_reported() {
    make_project
    make_engine_repository
    pin_engine_version 9.9.9
    run_installed_launcher version
    (( test_status != 0 )) || fail_test "expected the launcher to fail for a version with no tag"
    [[ $launcher_errors == *"could not fetch the tag 9.9.9"* ]] || fail_test "unexpected standard error: $launcher_errors"
}

test_the_engine_directory_override_runs_that_engine_and_says_so() {
    make_project
    run_app_release version
    expect_success
    expect_output_containing "warning: running the engine in $testing_engine_root"
    expect_output_containing "$(<$testing_engine_root/Sources/Version)"
}

test_install_copies_the_launcher_into_the_local_bin() {
    make_project
    local home_directory=${test_project:h}/Home
    mkdir -p "$home_directory"
    HOME=$home_directory "$testing_engine_root/app-release" --install > /dev/null
    local installed_path=$home_directory/.local/bin/app-release
    [[ -f $installed_path && ! -L $installed_path ]] || fail_test "expected a copy, not a link, at $installed_path"
    [[ -x $installed_path ]] || fail_test "expected $installed_path to be executable"
}
