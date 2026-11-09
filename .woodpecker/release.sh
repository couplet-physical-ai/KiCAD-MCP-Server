#!/usr/bin/env bash
# The Roadrunner release (.woodpecker/release.yaml), the port of .github/workflows/release.yml.
# Runs on the Woodpecker host for a pushed v* tag:
#   GH_TOKEN=... CI_REPO=owner/name bash .woodpecker/release.sh vX.Y.Z
# 1. checks the tag: it must equal v<package.json version> and its commit must be on main;
# 2. writes the notes with scripts/release-notes.mjs (README "What's New" section);
# 3. publishes the GitHub release, or leaves an existing one as it is;
# 4. for a non-prerelease tag, pushes the commit to stable (a plain push: stable only moves
#    forward, so releasing an older version fails here instead of rewinding it).
# Node and gh are pinned by version + sha256 and kept in .rr-tools; nothing is installed
# system-wide. GH_TOKEN never appears on a command line or in a URL.
set -euo pipefail

NODE_VERSION=24.22.2
GH_VERSION=2.103.3

tag=${1:?usage: release.sh vX.Y.Z}
: "${GH_TOKEN:?GH_TOKEN must be set}"
: "${CI_REPO:?CI_REPO (owner/name) must be set}"
cd "$(dirname "$0")/.."
tools="$PWD/.rr-tools"
mkdir -p "$tools"

case "$(uname -m)" in
  x86_64)
    arch=x64 gh_arch=amd64
    node_sha=361718c444e49af2ca5a110c83ba6a8901143f23ab285ebbef0341f391f482a9
    gh_sha=4c806978ffce1cec70853302a56d70ac6da4f19bae7adca4e1a8ab00633dd91d
    ;;
  aarch64)
    arch=arm64 gh_arch=arm64
    node_sha=95c264150aceb7f3437a29fd6984924f5f8d1511ea3cbd6c508b83f6c555dae2
    gh_sha=ee32df2323c8847f5fac6cb6b4b69ca75828e9329a8f22f677021f7b3306ce63
    ;;
  *) echo "release.sh: unsupported machine $(uname -m)" >&2; exit 1 ;;
esac

# unpack <url> <sha256>: download into .rr-tools, check the sha256, extract there.
unpack() {
  local file="$tools/${1##*/}"
  [ -f "$file" ] || curl -fsSL --retry 3 --max-time 300 -o "$file" "$1"
  echo "$2  $file" | sha256sum -c --quiet -
  tar -xzf "$file" -C "$tools"
}
node_dir=node-v$NODE_VERSION-linux-$arch
gh_dir=gh_${GH_VERSION}_linux_$gh_arch
unpack "https://nodejs.org/dist/v$NODE_VERSION/$node_dir.tar.gz" "$node_sha"
unpack "https://github.com/cli/cli/releases/download/v$GH_VERSION/$gh_dir.tar.gz" "$gh_sha"
node="$tools/$node_dir/bin/node"
gh() {
  GH_CONFIG_DIR="$tools/gh-config" GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 \
    "$tools/$gh_dir/bin/gh" "$@" --repo "$CI_REPO"
}
# git over https with the token from the environment (credential helper, never the URL).
remote="https://github.com/$CI_REPO.git"
git_auth() {
  # shellcheck disable=SC2016 # $GH_TOKEN is expanded by the helper's shell, not here.
  GIT_TERMINAL_PROMPT=0 timeout 300 git -c credential.helper= \
    -c 'credential.helper=!f() { echo username=x-access-token; echo "password=$GH_TOKEN"; }; f' "$@"
}

# Woodpecker clones the tag shallow: fetch main and every tag (for the previous release).
unshallow=""
[ "$(git rev-parse --is-shallow-repository)" = true ] && unshallow=--unshallow
git_auth fetch --quiet $unshallow --tags "$remote" "+refs/heads/main:refs/remotes/origin/main"

# 1. Check the tag.
version="${tag#v}"
commit=$(git rev-parse "$tag^{commit}")
package=$("$node" -p "require('./package.json').version")
if [ "$version" != "$package" ]; then
  echo "Tag $tag does not match the package.json version $package." >&2
  exit 1
fi
if ! git merge-base --is-ancestor "$commit" origin/main; then
  echo "Tag $tag points at $commit, which is not on main." >&2
  exit 1
fi
previous=$(git describe --tags --abbrev=0 --match 'v*' "$commit^" 2>/dev/null || true)
echo "Releasing $tag ($commit); previous release: ${previous:-none}"

# 2. Write the release notes.
notes="$tools/release-notes.md"
"$node" scripts/release-notes.mjs "$version" "$previous" > "$notes"

# 3. Publish the GitHub release (idempotent: an existing release is left as it is; a run that
#    loses a race with another run for the same tag finds it published and carries on).
if gh release view "$tag" > /dev/null 2>&1; then
  echo "Release $tag already exists; leaving it as it is."
else
  prerelease=()
  case "$tag" in *-*) prerelease=(--prerelease) ;; esac
  if ! gh release create "$tag" --verify-tag --title "$tag" --notes-file "$notes" "${prerelease[@]}"; then
    gh release view "$tag" > /dev/null 2>&1 || exit 1
    echo "Release $tag already exists; leaving it as it is."
  fi
fi

# 4. Move stable to the release (non-prerelease tags only).
case "$tag" in
  *-*) echo "Prerelease $tag: stable left alone." ;;
  *) git_auth push "$remote" "$commit:refs/heads/stable" ;;
esac
