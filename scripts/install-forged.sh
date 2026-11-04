#!/bin/sh

# Build a complete local package. Existing Codex data and installations are shared, not moved.
set -eu

for command in git cargo rustc python3 cc; do
    if ! command -v "$command" >/dev/null 2>&1; then
        printf 'Forged needs %s installed before it can be built.\n' "$command" >&2
        exit 1
    fi
done

target=$(rustc -vV | sed -n 's/^host: //p')
if [ -z "$target" ]; then
    printf 'Could not determine the Rust host target.\n' >&2
    exit 1
fi
case "$target" in
    *-linux-*)
        if [ -n "${CODEX_SKIP_BWRAP_BUILD+x}" ]; then
            printf 'Unset CODEX_SKIP_BWRAP_BUILD to build the Linux sandbox.\n' >&2
            exit 1
        fi
        if ! command -v pkg-config >/dev/null 2>&1 || ! pkg-config --exists libcap; then
            printf 'Building the Linux sandbox needs pkg-config and libcap development headers (for example, libcap-dev on Debian/Ubuntu).\n' >&2
            exit 1
        fi
        ;;
esac

install_dir=${FORGED_INSTALL_DIR:-"$HOME/.local/bin"}
data_dir=${FORGED_DATA_DIR:-"$HOME/.local/share/forged"}
mkdir -p "$install_dir" "$data_dir/releases"
install_dir=$(cd "$install_dir" && pwd -P)
data_dir=$(cd "$data_dir" && pwd -P)
destination=$install_dir/forged

if [ -e "$destination" ] || [ -L "$destination" ]; then
    if [ ! -L "$destination" ]; then
        printf 'Refusing to replace existing file: %s\n' "$destination" >&2
        exit 1
    fi
    previous=$(readlink "$destination")
    case "$previous" in
        "$data_dir"/releases/*/package/bin/forged) ;;
        *) printf 'Refusing to replace an unrelated link: %s\n' "$destination" >&2; exit 1 ;;
    esac
fi

source_tmp=
release_dir=
link_tmp=
installed=0
cleanup() {
    if [ -n "$link_tmp" ] && [ -L "$link_tmp" ]; then rm -f "$link_tmp"; fi
    if [ -n "$source_tmp" ]; then rm -rf "$source_tmp"; fi
    if [ "$installed" -eq 0 ] && [ -n "$release_dir" ]; then rm -rf "$release_dir"; fi
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

if [ -n "${FORGED_SOURCE_DIR:-}" ]; then
    source_dir=$(cd "$FORGED_SOURCE_DIR" && pwd -P)
else
    source_tmp=$(mktemp -d "${TMPDIR:-/tmp}/forged-source.XXXXXXXX")
    printf 'Cloning Forged source...\n'
    git clone --depth 1 --branch main https://github.com/alifwr/forged.git "$source_tmp/repo"
    source_dir=$source_tmp/repo
fi

if [ ! -f "$source_dir/codex-rs/cli/src/bin/forged.rs" ]; then
    printf 'The source does not contain the forged binary target. Update the repository first.\n' >&2
    exit 1
fi

release_dir=$(mktemp -d "$data_dir/releases/build.XXXXXXXX")
build_jobs=${CARGO_BUILD_JOBS:-1}
printf 'Building Forged and its runtime helpers for %s with %s Cargo job(s). This can take a while...\n' "$target" "$build_jobs"
CARGO_BUILD_JOBS="$build_jobs" CODEX_REPO_ROOT="$source_dir" python3 "$source_dir/scripts/build_codex_package.py" \
    --variant forged --target "$target" --cargo-profile release \
    --package-dir "$release_dir/package"

if [ ! -x "$release_dir/package/bin/forged" ]; then
    printf 'The package did not produce a Forged executable.\n' >&2
    exit 1
fi
link_tmp=$install_dir/.forged.$$
if [ -e "$link_tmp" ] || [ -L "$link_tmp" ]; then
    printf 'Temporary link already exists: %s\n' "$link_tmp" >&2
    exit 1
fi
ln -s "$release_dir/package/bin/forged" "$link_tmp"
mv -f "$link_tmp" "$destination"
link_tmp=
installed=1
printf '\nInstalled Forged at %s\n' "$destination"
case ":$PATH:" in
    *":$install_dir:"*) printf 'Run: forged\n' ;;
    *) printf 'Add %s to your PATH, then run: forged\n' "$install_dir" ;;
esac
printf 'Existing sessions remain in ~/.codex (or CODEX_HOME).\n'
