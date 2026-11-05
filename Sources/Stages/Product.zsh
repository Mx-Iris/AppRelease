# product: zip the stapled app, archive the dSYMs, check every product, write SHA256SUMS; with --publish,
# release them.
#
# products.tsv in the run directory lists the products, one "<notarized|not-notarized>\t<file name>"
# per line; hooks add to it through app_release_add_product.

_app_release_stage_product() {
    app_release_log "product"
    local products_directory=$app_release_run_directory/Products
    _app_release_render_template "$release_product_name"
    local product_name=$REPLY

    if [[ $_app_release_is_dry_run == true ]]; then
        _app_release_run ditto -c -k --sequesterRsrc --keepParent "$app_release_application_path" "$products_directory/$product_name"
        _app_release_call_hook release_after_product "$products_directory"
        if [[ $_app_release_publishes == true ]]; then
            _app_release_publish "$product_name"
        fi
        return 0
    fi

    rm -rf "$products_directory" "$app_release_run_directory/DebugSymbols"
    mkdir -p "$products_directory"
    : > "$app_release_run_directory/products.tsv"
    ditto -c -k --sequesterRsrc --keepParent "$app_release_application_path" "$products_directory/$product_name"
    print -r -- "notarized"$'\t'"$product_name" >> "$app_release_run_directory/products.tsv"
    _app_release_archive_debug_symbols
    _app_release_call_hook release_after_product "$products_directory"
    _app_release_verify_products
    _app_release_write_checksums

    _app_release_manifest_update '.stages.product.applicationArchive = $name
        | .stages.product.files = ($sums | split("\n") | map(select(length > 0) | capture("^(?<sha256>[0-9a-f]+)  (?<name>.+)$")))' \
        --arg name "$product_name" --rawfile sums "$products_directory/SHA256SUMS"
    app_release_detail "products: $products_directory"

    if [[ $_app_release_publishes == true ]]; then
        _app_release_publish "$product_name"
    fi
}

# dSYMs (the debug symbols that turn crash reports back into source lines) go next to the products, not
# into the release, unless a hook adds them.
_app_release_archive_debug_symbols() {
    local symbols_directory=$app_release_archive_path/dSYMs
    local -a symbol_bundles=("$symbols_directory"/*.dSYM(N))
    if (( ${#symbol_bundles} == 0 )); then
        app_release_detail "the archive has no dSYMs"
        return 0
    fi
    mkdir -p "$app_release_run_directory/DebugSymbols"
    ditto -c -k --sequesterRsrc --keepParent "$symbols_directory" \
        "$app_release_run_directory/DebugSymbols/$app_release_application_name.dSYMs.zip"
}

# Reads the list first: a check that reads standard input must not eat the rest of it.
_app_release_verify_products() {
    local -a entries=(${(f)"$(<$app_release_run_directory/products.tsv)"})
    local entry kind file_name
    for entry in "${entries[@]}"; do
        kind=${entry%%$'\t'*}
        file_name=${entry#*$'\t'}
        [[ -f $app_release_run_directory/Products/$file_name ]] ||
            app_release_fail "products.tsv lists $file_name, but Products/ has no such file"
        if [[ $kind == notarized ]]; then
            _app_release_verify_zipped_application "$app_release_run_directory/Products/$file_name"
        fi
    done
}

_app_release_write_checksums() {
    local -a file_names=(${(f)"$(cut -f 2 "$app_release_run_directory/products.tsv")"})
    file_names=(${(u)file_names})
    (cd "$app_release_run_directory/Products" && shasum -a 256 "${file_names[@]}" > SHA256SUMS)
}

# Prints the products' paths, one per line, for the publishers.
_app_release_product_paths() {
    local -a file_names=(${(f)"$(cut -f 2 "$app_release_run_directory/products.tsv")"})
    local file_name
    for file_name in ${(u)file_names}; do
        print -r -- "$app_release_run_directory/Products/$file_name"
    done
}
