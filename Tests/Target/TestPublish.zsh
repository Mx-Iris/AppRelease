# What a dry run of --publish hands to gh for the GitHub Release: title and release notes, and how
# early a release that would have no notes stops.

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

test_a_missing_notes_file_stops_the_release_before_archiving() {
    make_publishing_project "release_notes_path='Changelogs/{tag}.md'"
    run_app_release all --dry-run --publish
    expect_failure_containing "no release notes at ${test_project:A}/Changelogs/v1.2.3.md"
    expect_output_not_containing "==> archive"
}

test_an_empty_notes_file_counts_as_missing() {
    make_publishing_project "release_notes_path='Changelogs/{tag}.md'"
    mkdir -p "$test_project/Changelogs"
    : > "$test_project/Changelogs/v1.2.3.md"
    commit_all "Add empty release notes"
    run_app_release all --dry-run --publish
    expect_failure_containing "no release notes at ${test_project:A}/Changelogs/v1.2.3.md"
}

test_publishing_a_continued_run_checks_the_notes_before_any_work() {
    make_publishing_project "release_notes_path='Changelogs/{tag}.md'"
    run_app_release target --to archive
    expect_success
    run_app_release all --from archive --dry-run --publish
    expect_failure_containing "no release notes at ${test_project:A}/Changelogs/v1.2.3.md"
    expect_output_not_containing "==> archive"
}

test_notes_from_the_compose_hook_are_settled_before_the_tag_is_pushed() {
    make_publishing_project "release_notes_path='Changelogs/{tag}.md'" \
        'release_compose_notes() { print -r -- "Fixes." > "$1"; }'
    run_app_release all --dry-run --publish
    expect_success
    expect_output_containing_in_order "would call the hook release_compose_notes" "push origin refs/tags/v1.2.3"
}

test_an_existing_release_needs_no_notes_file() {
    make_publishing_project "release_notes_path='Changelogs/{tag}.md'"
    export FAKE_GITHUB_RELEASE_EXISTS=1
    run_app_release all --dry-run --publish
    expect_success
    expect_output_containing "gh release upload v1.2.3"
}

test_an_unknown_notes_fallback_is_refused() {
    make_publishing_project release_notes_fallback=sometimes
    run_app_release all --dry-run --publish
    expect_failure_containing "release_notes_fallback must be none or generated"
}
