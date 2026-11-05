# What the target stage refuses before any building starts.

test_uncommitted_changes_are_refused() {
    make_project
    use_fake_build_settings
    print -r -- "// an uncommitted change" >> "$test_project/SampleTool/main.swift"
    run_app_release target --to archive --dry-run
    expect_failure_containing "uncommitted changes"
}

test_allow_dirty_builds_anyway_with_a_warning() {
    make_project
    use_fake_build_settings
    print -r -- "// an uncommitted change" >> "$test_project/SampleTool/main.swift"
    run_app_release target --to archive --dry-run --allow-dirty
    expect_success
    expect_output_containing "warning: uncommitted changes"
}

test_an_output_root_the_repository_does_not_ignore_is_refused() {
    make_project
    : > "$test_project/.gitignore"
    commit_all "Stop ignoring build/"
    use_fake_build_settings
    run_app_release target --to archive --dry-run
    expect_failure_containing "inside the repository but not ignored"
}

test_export_needs_the_hardened_runtime() {
    make_project
    use_fake_build_settings ENABLE_HARDENED_RUNTIME=NO
    export FAKE_SECURITY_IDENTITY="Developer ID Application: Sample Developer (TEAMID1234)"
    run_app_release target --to export --dry-run
    expect_failure_containing "the hardened runtime is off"
}

test_export_needs_a_developer_id_identity_of_the_team() {
    make_project
    use_fake_build_settings
    export FAKE_SECURITY_IDENTITY="Developer ID Application: Someone Else (OTHERTEAM1)"
    run_app_release target --to export --dry-run
    expect_failure_containing 'no "Developer ID Application" identity of team TEAMID1234'
}

test_export_accepts_the_developer_id_identity_of_the_team() {
    make_project
    use_fake_build_settings
    export FAKE_SECURITY_IDENTITY="Developer ID Application: Sample Developer (TEAMID1234)"
    run_app_release target --to export --dry-run
    expect_success
}

test_an_ssh_session_without_ci_credentials_cannot_sign() {
    make_project
    use_fake_build_settings
    export FAKE_SECURITY_IDENTITY="Developer ID Application: Sample Developer (TEAMID1234)"
    export SSH_CONNECTION="192.0.2.1 50000 192.0.2.2 22"
    run_app_release target --to export --dry-run
    expect_failure_containing "this is an ssh session"
}

test_notarization_needs_credentials() {
    make_project
    use_fake_build_settings
    export FAKE_SECURITY_IDENTITY="Developer ID Application: Sample Developer (TEAMID1234)"
    run_app_release target --dry-run
    expect_failure_containing "no notarization credentials"
}

test_credentials_the_notary_service_refuses_are_reported() {
    make_project
    configure_release release_notary_keychain_profile=SampleProfile
    use_fake_build_settings
    export FAKE_SECURITY_IDENTITY="Developer ID Application: Sample Developer (TEAMID1234)"
    run_app_release target --dry-run
    expect_failure_containing "the notary service refused these credentials"
}

test_a_tag_that_names_another_commit_is_refused() {
    make_project
    git -C "$test_project" tag v1.2.3
    configure_release "# a commit after the tag"
    use_fake_build_settings
    run_app_release target --to archive --dry-run
    expect_failure_containing "the tag v1.2.3 already exists on"
}
