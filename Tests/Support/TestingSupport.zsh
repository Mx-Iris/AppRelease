# Shared helpers for the AppRelease tests, the zsh counterpart of a TestingSupport library: assertions,
# the throwaway sample project, and the fakes that stand in for Xcode's tools at the system boundary.
#
# Tests drive app-release from the outside, the way a project does; nothing here reaches into the engine.

typeset -g testing_root=${${(%):-%x}:A:h:h}
typeset -g testing_engine_root=${testing_root:h}
typeset -g test_project= test_output=
typeset -gi test_status=0

# A test must not inherit the caller's release environment.
unset SSH_CONNECTION SSH_TTY APP_RELEASE_OUTPUT_ROOT APP_RELEASE_DERIVED_DATA_PATH \
    APP_RELEASE_CERTIFICATE_BASE64 APP_RELEASE_CERTIFICATE_PASSWORD APP_RELEASE_NOTARY_KEY_BASE64 \
    APP_RELEASE_NOTARY_KEY_IDENTIFIER APP_RELEASE_NOTARY_ISSUER_IDENTIFIER APP_RELEASE_NOTARY_KEYCHAIN_PROFILE \
    APP_RELEASE_SPARKLE_PRIVATE_KEY APP_RELEASE_PROJECT_DIRECTORY APP_RELEASE_ENGINE_DIRECTORY

fail_test() {
    print -u2 -r -- "FAIL: $*"
    exit 1
}

expect_equal() {
    local expected=$1 actual=$2 description=${3:-value}
    [[ $actual == $expected ]] || fail_test "$description: expected '$expected', got '$actual'"
}

expect_success() {
    (( test_status == 0 )) || fail_test "expected app-release to succeed, but it exited with $test_status. Output:"$'\n'"$test_output"
}

expect_failure_containing() {
    (( test_status != 0 )) || fail_test "expected app-release to fail, but it succeeded. Output:"$'\n'"$test_output"
    [[ $test_output == *"$1"* ]] || fail_test "expected the output to contain '$1'. Output:"$'\n'"$test_output"
}

expect_output_containing() {
    [[ $test_output == *"$1"* ]] || fail_test "expected the output to contain '$1'. Output:"$'\n'"$test_output"
}

expect_output_not_containing() {
    [[ $test_output != *"$1"* ]] || fail_test "expected the output not to contain '$1'. Output:"$'\n'"$test_output"
}

# Both texts appear, the first one before the second.
expect_output_containing_in_order() {
    [[ $test_output == *"$1"*"$2"* ]] ||
        fail_test "expected '$1' and then '$2' in the output. Output:"$'\n'"$test_output"
}

# A throwaway git repository holding the sample app, its Release.zsh and a build/ ignore rule.
make_project() {
    local temporary_directory
    temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/AppReleaseTest.XXXXXX")
    test_project=$temporary_directory/SampleApp
    cp -R "$testing_root/Fixtures/SampleApp" "$test_project"
    git -C "$test_project" init -q -b main
    commit_all "Sample app"
}

commit_all() {
    git -C "$test_project" add -A
    git -C "$test_project" -c user.name=Tests -c user.email=tests@example.com commit -q -m "${1:-Change}"
}

# Appends lines to the project's Release.zsh and commits them, so the working tree stays clean.
configure_release() {
    print -rl -- "$@" >> "$test_project/Release.zsh"
    commit_all "Configure the release"
}

# Writes an Info.plist into the project with the given key=value pairs and commits it.
write_info_plist() {
    local info_plist_path=$test_project/SampleApp/Info.plist pair
    print -r -- '<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict/>
</plist>' > "$info_plist_path"
    for pair in "$@"; do
        plutil -insert "${pair%%=*}" -string "${pair#*=}" "$info_plist_path"
    done
    commit_all "Add an Info.plist"
}

# Puts the fakes ahead of the real tools, and has the fake xcodebuild answer -showBuildSettings with
# the fixture settings, changed by any key=value pairs given.
use_fake_build_settings() {
    local settings_path=${test_project:h}/BuildSettings.json
    local filter='.[0].buildSettings.SRCROOT = $sourceRoot' pair
    local -a jq_arguments=(--arg sourceRoot "$test_project")
    local -i index=0
    for pair in "$@"; do
        index+=1
        filter+=" | .[0].buildSettings[\$key$index] = \$value$index"
        jq_arguments+=(--arg key$index "${pair%%=*}" --arg value$index "${pair#*=}")
    done
    jq "${jq_arguments[@]}" "$filter" "$testing_root/Support/Fixtures/BuildSettings.json" > "$settings_path"
    export FAKE_XCODEBUILD_SETTINGS_PATH=$settings_path
    path=("$testing_root/Support/Fakes" $path)
}

# A bare repository standing in for origin, so the publish steps have somewhere to look.
add_origin() {
    local origin_path=${test_project:h}/Origin.git
    git init -q --bare "$origin_path"
    git -C "$test_project" remote add origin "$origin_path"
}

# Runs app-release in the project through the launcher, with this checkout as the engine.
run_app_release() {
    test_status=0
    test_output=$(cd "$test_project" && APP_RELEASE_ENGINE_DIRECTORY=$testing_engine_root \
        "$testing_engine_root/app-release" "$@" 2>&1) || test_status=$?
}

clean_up_test_project() {
    if [[ -n $test_project && ${test_project:h:t} == AppReleaseTest.* ]]; then
        rm -rf "${test_project:h}"
    fi
}
