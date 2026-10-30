#!/usr/bin/bash
set -eou pipefail

# ./build.sh [fedora_version]          build the patched RPM
# ./build.sh --fetch [fedora_version]  only fetch the SRPM into cache/, print its path
FETCH_ONLY=0
if [[ "${1:-}" == "--fetch" ]]; then
    FETCH_ONLY=1
    shift
fi

FEDORA_VERSION="${1:-44}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${SCRIPT_DIR}/build"
CACHE_DIR="${SCRIPT_DIR}/cache"
RELEASE_SUFFIX="blossomos1"

patch_file_list() {
    find "${SCRIPT_DIR}/patches" -name '*.patch' | sort
}

fetch_srpm() {
    local version="$FEDORA_VERSION"
    local nvr
    nvr="$(koji latest-build "f${version}-updates" plasma-setup 2>/dev/null | awk '/^plasma-setup/{print $1; exit}')"
    [[ -z "$nvr" ]] && nvr="$(koji latest-build "f${version}" plasma-setup | awk '/^plasma-setup/{print $1; exit}')"

    local cached="${CACHE_DIR}/${nvr}.src.rpm"
    if [[ -f "${cached}" ]]; then
        echo "==> Using cached SRPM: ${nvr}.src.rpm" >&2
    else
        echo "==> Fetching ${nvr}.src.rpm..." >&2
        mkdir -p "${CACHE_DIR}"
        (cd "${CACHE_DIR}" && koji download-build --arch=src "${nvr}") >&2
    fi
    echo "${cached}"
}

patch_spec() {
    local spec="$1"
    local names=()
    for patch in $(patch_file_list); do
        cp "${patch}" "${BUILD_DIR}/rpmbuild/SOURCES/"
        names+=("$(basename "${patch}")")
    done
    cp "${SCRIPT_DIR}/wallpapers.json" "${BUILD_DIR}/rpmbuild/SOURCES/"

    python3 - "${spec}" "${RELEASE_SUFFIX}" "${names[@]}" <<'PYEOF'
import sys, re

spec_path, suffix = sys.argv[1], sys.argv[2]
patch_names = sys.argv[3:]

with open(spec_path) as f:
    lines = f.readlines()

out = []
for line in lines:
    # Fedora's downstream patches pick Fedora's look and feel and wallpaper;
    # ours replace both
    if re.match(r'^Patch100[12]:', line):
        continue
    if re.match(r'^Requires:\s+plasma-lookandfeel-fedora', line):
        out += [f'Requires:       {p}\n' for p in
                ('blossomui', 'bibata-cursor-themes', 'blossom-sound-theme', 'blossomos-skel', 'qt6-qtmultimedia', 'python3', 'kscreen', 'kf6-kconfig', 'qt6-qttools', 'dbus-tools', 'pulseaudio-utils')]
        continue
    if re.match(r'^(Build)?Requires:\s+system-backgrounds-kde', line):
        continue
    if 'konqi-calling.png' in line:
        continue
    if line.startswith('Release:'):
        line = line.rstrip('\n') + f'.{suffix}\n'
    # Our patches add and remove binary files (git format-patch), which
    # GNU patch can't apply; git can (git-core is already a BuildRequires)
    if line.startswith('%autosetup'):
        line = '%autosetup -S git -p1\n'
    out.append(line)
    # The wallpapers the wallpaper page offers, see wallpapers.json
    if line.startswith('Source1:'):
        out.append('Source100: wallpapers.json\n')
        # The browser page installs browsers with libflatpak
        out.append('BuildRequires:  pkgconfig(flatpak)\n')
        out += [f'BuildRequires:  {dep}\n' for dep in
                ('cmake(KF6DNSSD)', 'cmake(KF6Solid)', 'pkgconfig(libarchive)', 'pkgconfig(openssl)')]
    if line.startswith('%cmake_install'):
        out.append('install -Dpm644 %{SOURCE100} %{buildroot}%{_datadir}/%{name}/wallpapers.json\n')

# Our patches go after the last PatchN: line in the header
last_patch_idx = max(i for i, line in enumerate(out) if re.match(r'^Patch\d+:', line)) \
    if any(re.match(r'^Patch\d+:', l) for l in out) else None
decls = [f'Patch{2000 + j}: {name}\n' for j, name in enumerate(patch_names)]
if last_patch_idx is None:
    last_patch_idx = next(i for i, l in enumerate(out) if l.startswith('BuildRequires:')) - 1
out = out[:last_patch_idx + 1] + decls + out[last_patch_idx + 1:]

with open(spec_path, 'w') as f:
    f.writelines(out)

print(f"Added {len(patch_names)} BlossomOS patch(es) to the spec")
PYEOF
}

main() {
    local srpm
    srpm="$(fetch_srpm)"
    if [[ "${FETCH_ONLY}" == 1 ]]; then
        echo "${srpm}"
        return
    fi

    rm -rf "${BUILD_DIR}/rpmbuild"
    mkdir -p "${BUILD_DIR}/rpmbuild/"{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}

    echo "==> Installing SRPM: $(basename "${srpm}")"
    rpm -ivh "${srpm}" --define "_topdir ${BUILD_DIR}/rpmbuild"

    local spec="${BUILD_DIR}/rpmbuild/SPECS/plasma-setup.spec"
    patch_spec "${spec}"

    echo "==> Installing build dependencies..."
    # CI runs as root in a plain Fedora container: no sudo, no rpm-ostree
    local sudo=()
    [[ "${EUID}" -ne 0 ]] && sudo=(sudo)
    if [[ -e /run/ostree-booted ]]; then
        "${sudo[@]}" rpm-ostree usroverlay || true
    fi
    "${sudo[@]}" dnf builddep -y "${spec}"

    echo "==> Building plasma-setup RPMs..."
    rpmbuild -ba "${spec}" \
        --define "_topdir ${BUILD_DIR}/rpmbuild" \
        --define "fedora ${FEDORA_VERSION}" \
        --define "dist .fc${FEDORA_VERSION}" \
        2>&1 | tee "${BUILD_DIR}/build.log"

    echo "==> Done. RPMs are in ${BUILD_DIR}/rpmbuild/RPMS/"
}

main
