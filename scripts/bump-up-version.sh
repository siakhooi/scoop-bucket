#!/usr/bin/env bash
# Check GitHub Releases for the latest version of each Scoop manifest and
# update bucket/<app>.json (version, download URL, hash).
#
# Usage:
#   ./scripts/bump-up-version.sh              # all apps in bucket/
#   ./scripts/bump-up-version.sh json2table picsum
#
# Auth (optional, raises GitHub API rate limits):
#   GITHUB_TOKEN or GH_TOKEN
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(cd "${SCRIPT_DIR}/.." && pwd)
BUCKET_DIR="${ROOT_DIR}/bucket"

usage() {
  cat <<'EOF'
Usage: bump-up-version.sh [app...]

Check GitHub Releases for the latest version of each Scoop manifest and
update bucket/<app>.json (version, url, hash).

With no arguments, every manifest in bucket/ is processed.
Arguments may be app names, manifest filenames, or paths.

Examples:
  ./scripts/bump-up-version.sh
  ./scripts/bump-up-version.sh json2table picsum
  ./scripts/bump-up-version.sh bucket/semvery.json
EOF
}

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "error: required command not found: $1" >&2
    exit 1
  fi
}

github_token() {
  printf '%s' "${GITHUB_TOKEN:-${GH_TOKEN:-}}"
}

github_api() {
  local url=$1
  local out=$2
  local token http_code
  local -a args=(
    -sS
    -o "$out"
    -w '%{http_code}'
    -H 'Accept: application/vnd.github+json'
    -H 'X-GitHub-Api-Version: 2022-11-28'
    -H 'User-Agent: scoop-bucket-bump-up-version'
  )

  token=$(github_token)
  if [[ -n $token ]]; then
    args+=(-H "Authorization: Bearer ${token}")
  fi

  http_code=$(curl "${args[@]}" "$url")
  if [[ $http_code != 200 ]]; then
    echo "error: GitHub API ${url} returned HTTP ${http_code}" >&2
    if [[ -s $out ]]; then
      cat "$out" >&2
      echo >&2
    fi
    return 1
  fi
}

strip_v_prefix() {
  local tag=$1
  if [[ $tag =~ ^[vV][0-9] ]]; then
    printf '%s' "${tag:1}"
  else
    printf '%s' "$tag"
  fi
}

owner_repo_from_homepage() {
  local homepage=$1
  if [[ $homepage =~ github\.com/([^/]+)/([^/#?]+) ]]; then
    local repo=${BASH_REMATCH[2]}
    repo=${repo%.git}
    printf '%s/%s' "${BASH_REMATCH[1]}" "$repo"
  fi
}

basename_from_url() {
  local url=$1
  url=${url%%#*}
  url=${url%%\?*}
  printf '%s' "${url##*/}"
}

sha256_of_url() {
  local url=$1
  local tmp=$2
  local token
  local -a args=(-fsSL -o "$tmp" -H 'User-Agent: scoop-bucket-bump-up-version')

  token=$(github_token)
  if [[ -n $token ]]; then
    args+=(-H "Authorization: Bearer ${token}")
  fi

  curl "${args[@]}" "$url"
  sha256sum "$tmp" | awk '{print $1}'
}

hash_from_asset() {
  local digest=$1
  local download_url=$2
  local tmp=$3

  if [[ -z $digest || $digest == null ]]; then
    sha256_of_url "$download_url" "$tmp"
    return
  fi

  case $digest in
    sha256:*)
      printf '%s' "${digest#sha256:}" | tr 'A-F' 'a-f'
      ;;
    sha512:* | sha1:* | md5:*)
      printf '%s' "$digest" | tr 'A-F' 'a-f'
      ;;
    *)
      sha256_of_url "$download_url" "$tmp"
      ;;
  esac
}

# Prefer the asset whose name matches the current URL with the version swapped.
# Fall back to a Windows archive that matches the Scoop architecture.
find_asset() {
  local release_json=$1
  local expected_name=$2
  local arch=$3

  local exact
  exact=$(jq -c --arg name "$expected_name" \
    '.assets[] | select(.name == $name)' \
    "$release_json")
  if [[ -n $exact ]]; then
    printf '%s' "$exact"
    return
  fi

  local filter
  case $arch in
    64bit)
      filter='test("x86_64|amd64|(?<![a-z0-9])x64(?![a-z0-9])|win64"; "i") and (test("arm64|aarch64|i386|(?<![a-z0-9])386(?![a-z0-9])"; "i") | not)'
      ;;
    32bit)
      filter='test("i386|(?<![a-z0-9])386(?![a-z0-9])|(?<![a-z0-9])x86(?![_a-z0-9])"; "i") and (test("x86_64|amd64|arm64|aarch64"; "i") | not)'
      ;;
    arm64)
      filter='test("arm64|aarch64"; "i")'
      ;;
    *)
      filter='true'
      ;;
  esac

  jq -c "
    [
      .assets[]
      | select(.name | test(\"\\\\.(zip|7z|msi|exe)$\"; \"i\"))
      | select(.name | test(\"win|windows\"; \"i\"))
      | select(.name | ${filter})
    ]
    | sort_by(.name | test(\"\\\\.zip$\"; \"i\") | not)
    | .[0] // empty
  " "$release_json"
}

list_asset_names() {
  jq -r '.assets[].name' "$1"
}

bump_app() {
  local app=$1
  local manifest="${BUCKET_DIR}/${app}.json"

  if [[ ! -f $manifest ]]; then
    echo "error: no manifest for '${app}' (${manifest})" >&2
    echo "available:" >&2
    local f
    for f in "${BUCKET_DIR}"/*.json; do
      echo "  $(basename "$f" .json)" >&2
    done
    return 1
  fi

  local homepage current_version owner_repo
  homepage=$(jq -r '.homepage // empty' "$manifest")
  current_version=$(jq -r '.version // empty' "$manifest")
  if [[ -z $homepage || -z $current_version ]]; then
    echo "error: ${app}: manifest is missing homepage or version" >&2
    return 1
  fi

  owner_repo=$(owner_repo_from_homepage "$homepage")
  if [[ -z $owner_repo ]]; then
    echo "error: ${app}: homepage is not a GitHub URL: ${homepage}" >&2
    return 1
  fi

  local release_json="${WORKDIR}/${app}.release.json"
  echo "${app}: checking https://github.com/${owner_repo}/releases/latest"
  github_api "https://api.github.com/repos/${owner_repo}/releases/latest" "$release_json"

  local tag new_version
  tag=$(jq -r '.tag_name // empty' "$release_json")
  if [[ -z $tag ]]; then
    echo "error: ${app}: latest release has no tag_name" >&2
    return 1
  fi
  new_version=$(strip_v_prefix "$tag")

  if [[ $new_version == "$current_version" ]]; then
    echo "${app}: already at ${current_version}"
    return 0
  fi

  local updated="${WORKDIR}/${app}.json"
  cp "$manifest" "$updated"
  jq --arg version "$new_version" '.version = $version' "$updated" >"${updated}.tmp"
  mv "${updated}.tmp" "$updated"

  local arch current_url expected_name asset download_url digest hash
  local has_arch
  has_arch=$(jq -r 'if .architecture then "yes" else "no" end' "$manifest")

  if [[ $has_arch == yes ]]; then
    while IFS= read -r arch; do
      [[ -z $arch ]] && continue
      current_url=$(jq -r --arg arch "$arch" '.architecture[$arch].url // empty' "$manifest")
      if [[ -z $current_url ]]; then
        echo "error: ${app}: architecture.${arch} has no url" >&2
        return 1
      fi

      expected_name=$(basename_from_url "$current_url")
      expected_name=${expected_name//"${current_version}"/"${new_version}"}

      asset=$(find_asset "$release_json" "$expected_name" "$arch")
      if [[ -z $asset || $asset == null ]]; then
        echo "error: ${app}: no release asset matching '${expected_name}' (${arch})" >&2
        echo "assets:" >&2
        list_asset_names "$release_json" | sed 's/^/  /' >&2
        return 1
      fi

      download_url=$(jq -r '.browser_download_url' <<<"$asset")
      digest=$(jq -r '.digest // empty' <<<"$asset")
      hash=$(hash_from_asset "$digest" "$download_url" "${WORKDIR}/${app}.${arch}.bin")

      jq --arg arch "$arch" --arg url "$download_url" --arg hash "$hash" \
        '.architecture[$arch].url = $url | .architecture[$arch].hash = $hash' \
        "$updated" >"${updated}.tmp"
      mv "${updated}.tmp" "$updated"
    done < <(jq -r '.architecture | keys[]' "$manifest")
  else
    current_url=$(jq -r '.url // empty' "$manifest")
    if [[ -z $current_url ]]; then
      echo "error: ${app}: manifest has neither architecture nor url" >&2
      return 1
    fi

    expected_name=$(basename_from_url "$current_url")
    expected_name=${expected_name//"${current_version}"/"${new_version}"}
    asset=$(find_asset "$release_json" "$expected_name" "64bit")
    if [[ -z $asset || $asset == null ]]; then
      echo "error: ${app}: no release asset matching '${expected_name}'" >&2
      echo "assets:" >&2
      list_asset_names "$release_json" | sed 's/^/  /' >&2
      return 1
    fi

    download_url=$(jq -r '.browser_download_url' <<<"$asset")
    digest=$(jq -r '.digest // empty' <<<"$asset")
    hash=$(hash_from_asset "$digest" "$download_url" "${WORKDIR}/${app}.bin")

    jq --arg url "$download_url" --arg hash "$hash" \
      '.url = $url | .hash = $hash' \
      "$updated" >"${updated}.tmp"
    mv "${updated}.tmp" "$updated"
  fi

  mv "$updated" "$manifest"
  echo "${app}: ${current_version} -> ${new_version}"
}

need curl
need jq
need sha256sum

if [[ ${1:-} == -h || ${1:-} == --help ]]; then
  usage
  exit 0
fi

if [[ ! -d $BUCKET_DIR ]]; then
  echo "error: bucket directory not found: ${BUCKET_DIR}" >&2
  exit 1
fi

apps=()
if [[ $# -eq 0 ]]; then
  shopt -s nullglob
  for f in "${BUCKET_DIR}"/*.json; do
    apps+=("$(basename "$f" .json)")
  done
  shopt -u nullglob
  if [[ ${#apps[@]} -eq 0 ]]; then
    echo "error: no manifests in ${BUCKET_DIR}" >&2
    exit 1
  fi
else
  for arg in "$@"; do
    if [[ $arg == -h || $arg == --help ]]; then
      usage
      exit 0
    fi
    apps+=("$(basename "$arg" .json)")
  done
fi

mapfile -t apps < <(printf '%s\n' "${apps[@]}" | sort)

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

failed=0
for app in "${apps[@]}"; do
  if ! bump_app "$app"; then
    failed=$((failed + 1))
  fi
done

if [[ $failed -ne 0 ]]; then
  echo "error: ${failed} app(s) failed" >&2
  exit 1
fi
