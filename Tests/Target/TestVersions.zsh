# How the target stage settles the version, the tag and the build number.

test_version_and_build_come_from_the_build_settings() {
    make_project
    use_fake_build_settings
    run_app_release target --to archive --dry-run
    expect_success
    expect_output_containing "1.2.3, build 45, tag v1.2.3"
}

test_a_literal_info_plist_version_wins_over_the_build_settings() {
    make_project
    write_info_plist CFBundleShortVersionString=1.9.0 CFBundleVersion=2929
    use_fake_build_settings INFOPLIST_FILE=SampleApp/Info.plist GENERATE_INFOPLIST_FILE=NO MARKETING_VERSION=1.0
    run_app_release target --to archive --dry-run
    expect_success
    expect_output_containing "1.9.0, build 2929, tag v1.9.0"
}

test_an_info_plist_reference_resolves_through_the_build_settings() {
    make_project
    write_info_plist 'CFBundleShortVersionString=$(MARKETING_VERSION)' 'CFBundleVersion=$(CURRENT_PROJECT_VERSION)'
    use_fake_build_settings INFOPLIST_FILE=SampleApp/Info.plist GENERATE_INFOPLIST_FILE=NO MARKETING_VERSION=2.0.1 CURRENT_PROJECT_VERSION=77
    run_app_release target --to archive --dry-run
    expect_success
    expect_output_containing "2.0.1, build 77, tag v2.0.1"
}

test_a_version_tag_that_differs_from_the_app_version_is_refused() {
    make_project
    use_fake_build_settings
    run_app_release target --to archive --dry-run --version-tag v1.2.4
    expect_failure_containing "does not match the app's version 1.2.3"
}

test_exact_matching_refuses_a_prerelease_suffix_on_a_numeric_version() {
    make_project
    use_fake_build_settings MARKETING_VERSION=1.9.0
    run_app_release target --to archive --dry-run --version-tag v1.9.0-beta.5
    expect_failure_containing "release_version_tag_match=exact"
}

test_base_matching_accepts_a_prerelease_suffix_and_marks_a_prerelease() {
    make_project
    configure_release release_version_tag_match=base
    use_fake_build_settings MARKETING_VERSION=1.9.0
    run_app_release target --to archive --dry-run --version-tag v1.9.0-beta.5
    expect_success
    expect_output_containing "tag v1.9.0-beta.5 (prerelease)"
}

# One test per example of LyricsX's scheme, so a failure names the version that broke.
expect_encoded_build_number() {
    local tag=$1 marketing_version=$2 expected_build_number=$3
    make_project
    configure_release release_version_tag_match=base release_build_number_source=semantic-version-encoding
    use_fake_build_settings MARKETING_VERSION=$marketing_version
    run_app_release target --to archive --dry-run --version-tag "$tag"
    expect_success
    expect_output_containing "$marketing_version, build $expected_build_number, tag $tag"
}

test_semantic_version_encoding_of_a_stable_release() {
    expect_encoded_build_number v1.8.7 1.8.7 10807999
}

test_semantic_version_encoding_of_a_beta() {
    expect_encoded_build_number v1.9.0-beta.5 1.9.0 10900105
}

test_semantic_version_encoding_of_a_release_candidate() {
    expect_encoded_build_number v1.9.0-rc.1 1.9.0 10900201
}

test_semantic_version_encoding_of_an_alpha() {
    expect_encoded_build_number v1.9.1-alpha.2 1.9.1 10901002
}

test_semantic_version_encoding_refuses_an_unknown_suffix() {
    make_project
    configure_release release_version_tag_match=base release_build_number_source=semantic-version-encoding
    use_fake_build_settings MARKETING_VERSION=1.9.0
    run_app_release target --to archive --dry-run --version-tag v1.9.0-preview.1
    expect_failure_containing "semantic-version-encoding needs"
}

test_an_injected_build_number_needs_the_info_plist_to_ask_for_it() {
    make_project
    write_info_plist 'CFBundleShortVersionString=$(MARKETING_VERSION)' CFBundleVersion=2929
    configure_release release_build_number_source=commit-count
    use_fake_build_settings INFOPLIST_FILE=SampleApp/Info.plist GENERATE_INFOPLIST_FILE=NO
    run_app_release target --to archive --dry-run
    expect_failure_containing 'change it to $(CURRENT_PROJECT_VERSION)'
}

test_commit_count_passes_the_number_of_commits_to_the_archive() {
    make_project
    configure_release release_build_number_source=commit-count
    use_fake_build_settings
    run_app_release all --to archive --dry-run
    expect_success
    expect_output_containing "1.2.3, build 2, tag v1.2.3"
    expect_output_containing "CURRENT_PROJECT_VERSION=2"
}

test_commit_count_refuses_a_shallow_clone() {
    make_project
    configure_release release_build_number_source=commit-count
    local shallow_project=${test_project:h}/ShallowClone
    git clone -q --depth 1 "file://$test_project" "$shallow_project"
    test_project=$shallow_project
    use_fake_build_settings
    run_app_release target --to archive --dry-run
    expect_failure_containing "this clone is shallow"
}
