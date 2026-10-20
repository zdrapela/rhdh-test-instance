#!/usr/bin/env bash
# Usage: bash scripts/check-plugin-refs.sh <catalog-defaults.yaml> <config.yaml>...
# Accepts a full plugins config or a component's array of plugin overrides.
set -euo pipefail

if [[ $# -lt 2 ]]; then
    echo "Usage: $0 <catalog-defaults.yaml> <config.yaml>..." >&2
    exit 1
fi

defaults="$1"
shift
source "$(dirname "${BASH_SOURCE[0]}")/deployment-common.sh"
prepare_deploy_workdir
yq -o=json '.' "$defaults" > "${DEPLOY_WORKDIR}/defaults.json"
: > "${DEPLOY_WORKDIR}/plugin-configs.json"
for file in "$@"; do
    yq -o=json '.' "$file" >> "${DEPLOY_WORKDIR}/plugin-configs.json"
done

jq -n --slurpfile defaults "${DEPLOY_WORKDIR}/defaults.json" \
    --slurpfile configs "${DEPLOY_WORKDIR}/plugin-configs.json" '
    def entries: if type == "array" then . else (.plugins // []) end;
    def image_name:
        sub("!.*$"; "") | split("/")[-1] | sub("[@:].*$"; "");
    ($defaults[0].plugins | map(select(.package | startswith("oci://")) | .package | image_name)) as $available |
    ($configs | map(entries) | add) as $plugins |
    [$plugins[] | select(.package | startswith("ref://") | not) | .package] as $direct |
    [$plugins | group_by(.package | image_name)[] | select(length > 1) | .[0].package] as $duplicates |
    [$available | group_by(.)[] | select(length > 1) | .[0] |
        select(. as $name | $plugins | any((.package | image_name) == $name))] as $ambiguous |
    [$plugins[].package | image_name | select(. as $name | $available | index($name) | not)] as $missing |
    if ($direct | length) > 0 then
        error("Plugin configuration must use ref://: " + ($direct | join(", ")))
    elif ($duplicates | length) > 0 then
        error("Duplicate plugin overrides: " + ($duplicates | join(", ")))
    elif ($ambiguous | length) > 0 then
        error("Ambiguous image names in catalog defaults: " + ($ambiguous | join(", ")))
    elif ($missing | length) > 0 then
        error("Catalog defaults are missing: " + ($missing | join(", ")) +
            ". Supply CATALOG_INDEX_IMAGE with definitions for these packages; extra UI catalogs do not provide defaults.")
    else
        "Validated \($plugins | length) plugin references against catalog defaults."
    end
' -r
