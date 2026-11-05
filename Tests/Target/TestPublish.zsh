# What a dry run of --publish hands to gh for the GitHub Release: title and release notes.

# A sample project that can publish to a GitHub Release, with any further Release.zsh lines given.
make_publishing_project() {
    make_project
    add_origin
    configure_release release_notary_keychain_profile=SampleProfile 'release_publishers=(github-release)' "$@"
    use_fake_build_settings
    export FAKE_SECURITY_IDENTITY="Developer ID Application: Sample Developer (TEAMID1234)"
    export FAKE_NOTARY_ACCEPTS_CREDENTIALS=1
}

test_a_new_release_is_titled_with_its_tag() {
    make_publishing_project
    run_app_release all --dry-run --publish
    expect_success
    expect_output_containing "--title v1.2.3"
}

test_a_release_without_notes_gets_empty_notes_by_default() {
    make_publishing_project
    run_app_release all --dry-run --publish
    expect_success
    expect_output_containing "--notes ''"
    expect_output_not_containing "--generate-notes"
}

test_generated_notes_stand_in_when_no_notes_file_is_named() {
    make_publishing_project release_notes_fallback=generated
    run_app_release all --dry-run --publish
    expect_success
    expect_output_containing "--generate-notes"
}

test_a_notes_file_that_exists_is_used() {
    make_publishing_project release_notes_fallback=generated "release_notes_path='Changelogs/{tag}.md'"
    mkdir -p "$test_project/Changelogs"
    print -r -- "Fixes." > "$test_project/Changelogs/v1.2.3.md"
    commit_all "Add release notes"
    run_app_release all --dry-run --publish
    expect_success
    # The engine resolves symbolic links in the project path (/var is one on macOS); so does :A.
    expect_output_containing "--notes-file ${test_project:A}/Changelogs/v1.2.3.md"
    expect_output_not_containing "--generate-notes"
}

test_a_missing_notes_file_falls_back_to_generated_notes() {
    make_publishing_project release_notes_fallback=generated "release_notes_path='Changelogs/{tag}.md'"
    run_app_release all --dry-run --publish
    expect_success
    expect_output_containing "--generate-notes"
}

test_an_unknown_notes_fallback_is_refused() {
    make_publishing_project release_notes_fallback=sometimes
    run_app_release all --dry-run --publish
    expect_failure_containing "release_notes_fallback must be none or generated"
}
