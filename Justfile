fedora := env("FEDORA_VERSION", "44")
src_dir := "build/src"
cmake_dir := "build/cmake"
stage_dir := "build/stage"
toolbox := "plasma-setup"
just := just_executable()

[private]
default:
    @{{ just }} --list

# Unpack upstream plasma-setup from the Fedora SRPM into build/src as a git tree with patches/ applied
[group('Source')]
source:
    #!/usr/bin/bash
    set -euo pipefail
    if [[ -d {{ src_dir }}/.git ]] && [[ -n $(git -C {{ src_dir }} status --porcelain) ]]; then
        echo "{{ src_dir }} has uncommitted changes, commit them and run 'just export-patches' first" >&2
        exit 1
    fi
    srpm=$(./build.sh --fetch {{ fedora }})
    rm -rf {{ src_dir }} && mkdir -p {{ src_dir }}
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    (cd "$tmp" && rpm2cpio "$srpm" | cpio -id --quiet '*.tar.xz')
    tar -xf "$tmp"/plasma-setup-*.tar.xz -C {{ src_dir }} --strip-components=1
    cd {{ src_dir }}
    git init -q -b blossomos
    git add -A
    git -c user.name=upstream -c user.email=upstream@localhost commit -q -m "Upstream $(basename "$tmp"/plasma-setup-*.tar.xz .tar.xz)"
    git tag upstream
    shopt -s nullglob
    patches=(../../patches/*.patch)
    if (( ${#patches[@]} )); then
        git am -q --committer-date-is-author-date "${patches[@]}"
    fi
    echo "Patched source in {{ src_dir }} ($(git rev-list --count upstream..HEAD) patches)"

# Write the commits on top of upstream in build/src back to patches/
[group('Source')]
export-patches:
    #!/usr/bin/bash
    set -euo pipefail
    rm -f patches/*.patch
    mkdir -p patches
    git -C {{ src_dir }} format-patch -q --no-signature --zero-commit -o ../../patches upstream..HEAD
    ls patches

# Commit the changes in build/src as a new patch with the given subject, or fold them into patch NUMBER, then export (stages everything unless something is staged already)
[group('Source')]
patch target:
    #!/usr/bin/bash
    set -euo pipefail
    [[ -d {{ src_dir }}/.git ]] || { echo "No {{ src_dir }}, run 'just source' first" >&2; exit 1; }
    cd {{ src_dir }}
    git diff --cached --quiet && git add -A
    if git diff --cached --quiet; then
        echo "No changes in {{ src_dir }}" >&2
        exit 1
    fi
    target={{ quote(target) }}
    if [[ $target =~ ^[0-9]+$ ]]; then
        commit=$(git rev-list --reverse upstream..HEAD | sed -n "$((10#$target))p")
        if [[ -z $commit ]]; then
            echo "No patch $target, there are $(git rev-list --count upstream..HEAD)" >&2
            exit 1
        fi
        git commit -q --fixup="$commit"
        git -c sequence.editor=: rebase -q -i --autosquash upstream
        echo "Updated patch $(printf %04d $((10#$target))): $(git log -1 --format=%s "$(git rev-list --reverse upstream..HEAD | sed -n "$((10#$target))p")")"
    else
        git commit -q -m "$target"
        echo "Added patch $(printf %04d "$(git rev-list --count upstream..HEAD)"): $target"
    fi
    cd - >/dev/null
    {{ just }} export-patches

# Build build/src and install it into build/stage, in the toolbox when run from the host
[group('Build')]
build:
    #!/usr/bin/bash
    set -euo pipefail
    [[ -d {{ src_dir }} ]] || {{ just }} source
    if [[ ! -e /run/.containerenv ]]; then
        podman container exists {{ toolbox }} || {{ just }} toolbox
        exec toolbox run -c {{ toolbox }} just build
    fi
    [[ -f {{ cmake_dir }}/build.ninja ]] || cmake -B {{ cmake_dir }} -S {{ src_dir }} -GNinja \
        -DCMAKE_BUILD_TYPE=Debug -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_INSTALL_LIBEXECDIR=libexec \
        -DKDE_INSTALL_USE_QT_SYS_PATHS=ON -DBUILD_TESTING=OFF
    ninja -C {{ cmake_dir }}
    rm -rf {{ stage_dir }}
    DESTDIR="$PWD/{{ stage_dir }}" cmake --install {{ cmake_dir }} >/dev/null
    install -Dm644 wallpapers.json {{ stage_dir }}/usr/share/plasma-setup/wallpapers.json

# Create the Fedora toolbox 'just build' runs in, or bring its build dependencies up to date
[group('Build')]
toolbox:
    #!/usr/bin/bash
    set -euo pipefail
    srpm=$(./build.sh --fetch {{ fedora }})
    podman container exists {{ toolbox }} || toolbox create -y -c {{ toolbox }} --distro fedora --release {{ fedora }}
    toolbox run -c {{ toolbox }} sudo dnf -y -q install just cmake ninja-build gcc-c++ dnf-plugins-core
    toolbox run -c {{ toolbox }} sudo dnf -y -q builddep "$srpm"

# Build the patched plasma-setup RPM (build/rpmbuild/RPMS/)
[group('Build')]
rpm:
    ./build.sh {{ fedora }}

# Remove build output (keeps the SRPM cache)
[group('Build')]
clean:
    rm -rf build

# Run the wizard in a nested KWin window with a throwaway home; nothing on this system is changed (args: --dark, --page NAME, WIDTH HEIGHT)
[group('UI')]
preview *args: build
    scripts/preview {{ args }}

# Screenshot the landing page, or a page with --page NAME, through the preview (args: [FILE.png], --dark, --delay MS, WIDTH HEIGHT)
[group('UI')]
screenshot *args: build
    #!/usr/bin/bash
    set -euo pipefail
    set -- {{ args }}
    out=screenshot.png
    rest=()
    for arg; do
        if [[ $arg == *.png ]]; then out="$arg"; else rest+=("$arg"); fi
    done
    scripts/preview --screenshot "$out" "${rest[@]}"
