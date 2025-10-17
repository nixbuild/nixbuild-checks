#!/bin/bash

set -e

# Directory for storing the JSON representations of the created nixbuild.net
# process.
process_dir="$1"
shift

# JSON line produced by `evaluate.sh`
json="$1"

name="$(jq -nr --argjson x "$json" '$x.name')"
title="$(jq -nr --argjson x "$json" '$x.title')"
drv="$(jq -nr --argjson x "$json" '$x.drv')"
cache_dir="$(jq -nr --argjson x "$json" '$x.cache_dir')"

# Register a GC root for the drv. This mean we can garbage collect the store
# before saving the cache, pruning any things not used since last cache restore
# We don't cache the GC roots themselves though, which means that next time
# this drv could be removed if it is no longer used.
# Note that we are not appending '^*' or '^out' to the call below, this means
# we just "build" the .drv-file. Effectively, we are just registering a GC
# root to the .drv-file.
XDG_CACHE_HOME="$cache_dir" nix build --out-link "$(mktemp -u)" "$drv"

# Copy the .drv closure to nixbuild.net
# TODO This is a bit slow due to the way Nix sends the complete closure list
# to the remote to ask which paths already exist remotely.
XDG_CACHE_HOME="$cache_dir" nix copy --derivation --to ssh-ng://nixbuild "$drv"

# Fetch OIDC token
NIXBUILDNET_OIDC_ID_TOKEN="$(curl -sSL \
  -H "Authorization: Bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
  "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=nixbuild.net" | \
  jq -j .value
)"
if [ -z "${NIXBUILDNET_OIDC_ID_TOKEN+x}" ]; then
  echo >&2 "Failed retrieving OIDC ID Token from GitHub"
  exit 1
else
  echo "NIXBUILDNET_OIDC_ID_TOKEN=$NIXBUILDNET_OIDC_ID_TOKEN" >> "$GITHUB_ENV"
fi

# Create process for the installable
base_url="$NIXBUILDNET_HTTP_API_SCHEME://$NIXBUILDNET_HTTP_API_HOST:$NIXBUILDNET_HTTP_API_PORT$NIXBUILDNET_HTTP_API_SUBPATH"

jq -cn \
  --arg name "$name" \
  --arg title "$title" \
  --arg installable "$drv^*" '
  [
    {
      "installable": $installable,
      "attributes": [
        [ "NIXBUILDNET_HOOK_GITHUB_CHECK_RUN", "" ],
        [ "NIXBUILDNET_GITHUB_CHECK_RUN_NAME", "\($name)" ],
        [ "NIXBUILDNET_GITHUB_CHECK_RUN_TITLE", "\($title)" ]
      ]
    }
  ]
  ' | \
  curl "$base_url/processes" \
    -sL \
    --fail-with-body \
    --data-binary "@-" \
    --header "Content-Type: application/json" \
    --header "Accept: application/json" \
    -o "$process_dir/$RANDOM$RANDOM.json" \
    -H "Authorization: Bearer $NIXBUILDNET_TOKEN" \
    -H "NIXBUILDNET-OIDC-ID-TOKEN: $NIXBUILDNET_OIDC_ID_TOKEN"
