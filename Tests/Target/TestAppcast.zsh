# What the sparkle-appcast publisher hands to generate_appcast: the release notes when asked to embed
# them, and the same treatment for the archive of a second app, through app_release_generate_appcast.

# A sample project that publishes a GitHub Release and an appcast, with any further Release.zsh lines.
make_appcast_project() {
    make_project
    add_origin
    configure_release release_notary_keychain_profile=SampleProfile \
        'release_publishers=(github-release sparkle-appcast)' release_appcast_path=appcast.xml "$@"
    use_fake_build_settings
    export FAKE_SECURITY_IDENTITY="Developer ID Application: Sample Developer (TEAMID1234)"
    export FAKE_NOTARY_ACCEPTS_CREDENTIALS=1
    export FAKE_GENERATE_APPCAST_RECORD_PATH=${test_project:h}/generate_appcast.record
}

add_release_notes() {
    mkdir -p "$test_project/Changelogs"
    print -r -- "Fixes." > "$test_project/Changelogs/v1.2.3.md"
    commit_all "Add release notes"
}

test_the_appcast_embeds_the_release_notes_when_asked() {
    make_appcast_project "release_notes_path='Changelogs/{tag}.md'" release_appcast_embeds_release_notes=true
    add_release_notes
    run_app_release all --dry-run --publish
    expect_success
    expect_output_containing "--embed-release-notes"
    expect_output_containing "would embed the release notes ${test_project:A}/Changelogs/v1.2.3.md as SampleApp-1.2.3-45.md"
}

test_the_appcast_leaves_the_release_notes_out_by_default() {
    make_appcast_project "release_notes_path='Changelogs/{tag}.md'"
    add_release_notes
    run_app_release all --dry-run --publish
    expect_success
    expect_output_containing "generate_appcast"
    expect_output_not_containing "--embed-release-notes"
}

test_embedding_release_notes_needs_a_notes_file() {
    make_appcast_project release_appcast_embeds_release_notes=true
    run_app_release all --dry-run --publish
    expect_failure_containing "release_appcast_embeds_release_notes needs release_notes_path"
}

test_embedding_release_notes_takes_true_or_false() {
    make_appcast_project "release_notes_path='Changelogs/{tag}.md'" release_appcast_embeds_release_notes=yes
    add_release_notes
    run_app_release all --dry-run --publish
    expect_failure_containing "release_appcast_embeds_release_notes must be true or false"
}

# A hook can write the feed of a second app the release ships, such as one zipped inside the first. Here
# release_preflight stands in for release_deploy_appcast, the hook a project would call it from: it is the
# one a run that builds nothing reaches.
test_a_hook_writes_the_appcast_of_a_second_archive() {
    make_appcast_project \
        'release_preflight() {
            local work=${app_release_project_directory:h}/Second
            mkdir -p "$work"
            print -r -- archive > "$work/Second-1.2.3.zip"
            print -r -- "Fixes." > "$work/Notes.md"
            app_release_generate_appcast "$work/Second-1.2.3.zip" "$work/SecondAppcast.xml" "$work/Notes.md"
        }'
    run_app_release target --publish
    expect_success
    local record
    record=$(<$FAKE_GENERATE_APPCAST_RECORD_PATH)
    [[ $record == *$'\n-o\n'"${test_project:A:h}/Second/SecondAppcast.xml"$'\n'* ]] || fail_test "no -o for the second feed in: $record"
    [[ $record == *$'\n--download-url-prefix\nhttps://github.com/example/SampleApp/releases/download/v1.2.3/\n'* ]] ||
        fail_test "no download URL prefix of the release in: $record"
    [[ $record == *$'\n--embed-release-notes\n'* ]] || fail_test "the notes are not embedded: $record"
    expect_equal $'Second-1.2.3.md\nSecond-1.2.3.zip' "${record#*--- files$'\n'}" "files beside the archive"
    [[ -f ${test_project:h}/Second/SecondAppcast.xml ]] || fail_test "no feed written"
}

test_a_second_archive_without_notes_gets_none() {
    make_appcast_project \
        'release_preflight() {
            local work=${app_release_project_directory:h}/Second
            mkdir -p "$work"
            print -r -- archive > "$work/Second-1.2.3.zip"
            app_release_generate_appcast "$work/Second-1.2.3.zip" "$work/SecondAppcast.xml"
        }'
    run_app_release target --publish
    expect_success
    local record
    record=$(<$FAKE_GENERATE_APPCAST_RECORD_PATH)
    [[ $record != *--embed-release-notes* ]] || fail_test "notes embedded without a notes file: $record"
    expect_equal "Second-1.2.3.zip" "${record#*--- files$'\n'}" "files beside the archive"
}

test_a_second_archive_that_is_missing_stops_the_hook() {
    make_appcast_project \
        'release_preflight() {
            app_release_generate_appcast "${app_release_project_directory:h}/Nothing.zip" "${app_release_project_directory:h}/SecondAppcast.xml"
        }'
    run_app_release target --publish
    expect_failure_containing "app_release_generate_appcast: no archive at"
}
