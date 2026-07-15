#!/usr/bin/env bash
# Package the ROS1 Noetic build as a reproducible Ultra-Fusion release .deb.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_ROOT="${ULTRAFUSION_SOURCE_ROOT:-}"
VERSION="${ULTRAFUSION_ROS1_VERSION:-0.1.2}"
PACKAGE_NAME="${ULTRAFUSION_ROS1_PACKAGE_NAME:-ultrafusion}"
OUTPUT_DIR="${ULTRAFUSION_ROS1_OUTPUT_DIR:-$(cd "$SCRIPT_DIR/../../.." && pwd)/releases}"
EXTRA_LIBRARY_DIRS="${ULTRAFUSION_ROS1_EXTRA_LIBRARY_DIRS:-}"
FORCE=0

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  --source DIR      Ultra-Fusion source tree with ROS1 build outputs
  --version VER     Debian package version, default ${VERSION}
  --output DIR      Directory for the .deb and .sha256 files
  --extra-lib-dir DIR
                    Extra directory used to resolve non-system runtime libs;
                    may be passed more than once
  --force           Replace an existing local output file
  -h, --help        Show this help message
EOF
}

die() {
  echo "Error: $*" >&2
  exit 1
}

join_by_colon() {
  local IFS=:
  echo "$*"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source) SOURCE_ROOT="${2:?--source requires a directory}"; shift 2 ;;
    --version) VERSION="${2:?--version requires a version}"; shift 2 ;;
    --output) OUTPUT_DIR="${2:?--output requires a directory}"; shift 2 ;;
    --extra-lib-dir)
      EXTRA_LIBRARY_DIRS="${EXTRA_LIBRARY_DIRS:+${EXTRA_LIBRARY_DIRS}:}${2:?--extra-lib-dir requires a directory}"
      shift 2
      ;;
    --force) FORCE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

[[ -n "$SOURCE_ROOT" ]] || die "--source DIR is required"

for command in dpkg dpkg-deb git ldd patchelf readelf strip; do
  command -v "$command" >/dev/null 2>&1 || die "$command is required"
done
dpkg --validate-version "$VERSION" >/dev/null 2>&1 ||
  die "invalid Debian version: $VERSION"
dpkg --validate-pkgname "$PACKAGE_NAME" >/dev/null 2>&1 ||
  die "invalid Debian package name: $PACKAGE_NAME"

GIT_SAFE_HOME="$(mktemp -d)"
trap 'rm -rf "$GIT_SAFE_HOME"' EXIT
HOME="$GIT_SAFE_HOME" git config --global --add safe.directory "$SOURCE_ROOT"
GIT=(env "HOME=$GIT_SAFE_HOME" git -C "$SOURCE_ROOT")
"${GIT[@]}" rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
  die "source is not a readable Git worktree: $SOURCE_ROOT"
"${GIT[@]}" diff --quiet ||
  die "source tree has unstaged tracked changes: $SOURCE_ROOT"
"${GIT[@]}" diff --cached --quiet ||
  die "source tree has staged tracked changes: $SOURCE_ROOT"
BUILD_DIR="$SOURCE_ROOT/build"
DEVEL_LIB="$BUILD_DIR/devel/lib"
UF_NODE="$DEVEL_LIB/ultrafusion/uf_node"
UF_LIB="$DEVEL_LIB/libultra_lib.so"
GNSS_LIB="$DEVEL_LIB/libgnss_comm.so"

for path in "$UF_NODE" "$UF_LIB" "$GNSS_LIB"; do
  [[ -f "$path" ]] || die "missing ROS1 build artifact: $path"
done
[[ -x "$UF_NODE" ]] || die "uf_node is not executable: $UF_NODE"

declare -a LIBRARY_SEARCH_DIRS=()

append_search_dir() {
  local dir="$1"
  [[ -n "$dir" && -d "$dir" ]] || return 0
  local existing
  for existing in "${LIBRARY_SEARCH_DIRS[@]}"; do
    [[ "$existing" == "$dir" ]] && return 0
  done
  LIBRARY_SEARCH_DIRS+=("$dir")
}

append_path_list() {
  local path_list="$1"
  local dir
  local old_ifs="$IFS"
  IFS=:
  for dir in $path_list; do
    append_search_dir "$dir"
  done
  IFS="$old_ifs"
}

append_runpath_dirs() {
  local elf="$1"
  local origin
  local runpath
  local dir
  origin="$(dirname "$elf")"
  runpath="$(readelf -d "$elf" 2>/dev/null |
    sed -n '/R.*PATH/s/.*\[\(.*\)\].*/\1/p' | head -n 1 || true)"
  [[ -n "$runpath" ]] || return 0

  local old_ifs="$IFS"
  IFS=:
  for dir in $runpath; do
    if [[ "$dir" == *'$ORIGIN'* ]]; then
      dir="${dir//\$ORIGIN/$origin}"
    fi
    append_search_dir "$dir"
  done
  IFS="$old_ifs"
}

resolve_library_path() {
  local soname="$1"
  shift
  local ld_path
  local artifact
  local path
  ld_path="$(join_by_colon "${LIBRARY_SEARCH_DIRS[@]}")"

  for artifact in "$@"; do
    path="$(LD_LIBRARY_PATH="$ld_path" ldd "$artifact" 2>/dev/null |
      awk -v lib="$soname" '$1 == lib && $2 == "=>" && $3 ~ /^\// {print $3; exit}')"
    if [[ -n "$path" && -e "$path" ]]; then
      readlink -f "$path"
      return 0
    fi
  done

  local dir
  for dir in "${LIBRARY_SEARCH_DIRS[@]}"; do
    if [[ -e "$dir/$soname" ]]; then
      readlink -f "$dir/$soname"
      return 0
    fi
  done
  return 1
}

copy_library_family() {
  local resolved_path="$1"
  shift
  local source_dir
  local real_path
  local real_name
  local name
  local source_path
  local target_name

  source_dir="$(dirname "$resolved_path")"
  real_path="$(readlink -f "$resolved_path")"
  real_name="$(basename "$real_path")"
  install -m 0644 "$real_path" "$PKG_DIR/opt/ultrafusion/lib/$real_name"

  for name in "$@"; do
    source_path="$source_dir/$name"
    if [[ -e "$source_path" ]]; then
      target_name="$(basename "$(readlink -f "$source_path")")"
      if [[ ! -e "$PKG_DIR/opt/ultrafusion/lib/$target_name" ]]; then
        install -m 0644 "$(readlink -f "$source_path")" \
          "$PKG_DIR/opt/ultrafusion/lib/$target_name"
      fi
      if [[ "$name" != "$target_name" ]]; then
        ln -sfn "$target_name" "$PKG_DIR/opt/ultrafusion/lib/$name"
      fi
    elif [[ "$name" != "$real_name" ]]; then
      ln -sfn "$real_name" "$PKG_DIR/opt/ultrafusion/lib/$name"
    fi
  done
}

validate_cpu_ceres() {
  local library="$1"
  if readelf -d "$library" 2>/dev/null |
      grep NEEDED | grep -Eq 'lib(cuda|cudart|cublas|cusolver|cusparse)\.so'; then
    die "Ceres has CUDA runtime dependencies and is not portable to the public CPU image: $library"
  fi
}

validate_profile_map_flag() {
  local config="$1"
  local key
  for key in enable output_directory translation_threshold_m \
      rotation_threshold_deg service_name; do
    awk -v wanted="$key" '
      /^map_pcd:[[:space:]]*$/ {in_map=1; next}
      in_map && /^[^[:space:]]/ {exit}
      in_map {
        line=$0
        sub(/^[[:space:]]+/, "", line)
        split(line, fields, /:[[:space:]]*/)
        if (fields[1] == wanted) found=1
      }
      END {exit found ? 0 : 1}
    ' "$config" || die "map_pcd.$key is missing from release profile: $config"
  done

  awk '
    /^map_pcd:[[:space:]]*$/ {in_map=1; next}
    in_map && /^[^[:space:]]/ {exit}
    in_map && /^[[:space:]]+enable:[[:space:]]*(false|0)[[:space:]]*$/ {found=1}
    END {exit found ? 0 : 1}
  ' "$config" || die "release profile must set map_pcd.enable: false: $config"
}

validate_release_runpath() {
  local artifact="$1"
  local expected="$2"
  local runpath
  runpath="$(readelf -d "$artifact" 2>/dev/null |
    sed -n '/R.*PATH/s/.*\[\(.*\)\].*/\1/p' | head -n 1 || true)"
  [[ "$runpath" == "$expected" ]] ||
    die "unexpected release RUNPATH in $artifact: ${runpath:-<empty>}"
}

validate_staged_linkage() {
  local artifact="$1"
  local ld_path
  local linkage
  ld_path="$PKG_DIR/opt/ultrafusion/lib:$(join_by_colon "${LIBRARY_SEARCH_DIRS[@]}")"
  linkage="$(LD_LIBRARY_PATH="$ld_path" ldd "$artifact" 2>&1)"
  if grep -q 'not found' <<<"$linkage"; then
    grep 'not found' <<<"$linkage" >&2
    die "unresolved runtime dependencies in staged artifact: $artifact"
  fi
}

append_path_list "$EXTRA_LIBRARY_DIRS"
append_path_list "${LD_LIBRARY_PATH:-}"
append_search_dir "$DEVEL_LIB"
append_search_dir "$(dirname "$UF_NODE")"
append_search_dir "/opt/ros/noetic/lib"
append_search_dir "/usr/local/lib"
append_search_dir "/usr/local/lib/x86_64-linux-gnu"
append_search_dir "/usr/lib/x86_64-linux-gnu"
append_runpath_dirs "$UF_NODE"
append_runpath_dirs "$UF_LIB"
append_runpath_dirs "$GNSS_LIB"

mkdir -p "$OUTPUT_DIR"
DEB_PATH="$OUTPUT_DIR/${PACKAGE_NAME}_${VERSION}_amd64.deb"
SHA_PATH="${DEB_PATH}.sha256"
if [[ "$FORCE" -ne 1 && ( -e "$DEB_PATH" || -e "$SHA_PATH" ) ]]; then
  die "output already exists; choose a new version/output or pass --force: $DEB_PATH"
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR" "$GIT_SAFE_HOME"' EXIT
PKG_DIR="$TMP_DIR/${PACKAGE_NAME}_${VERSION}_amd64"

mkdir -p \
  "$PKG_DIR/DEBIAN" \
  "$PKG_DIR/etc/ld.so.conf.d" \
  "$PKG_DIR/opt/ultrafusion/bin" \
  "$PKG_DIR/opt/ultrafusion/lib" \
  "$PKG_DIR/opt/ultrafusion/config" \
  "$PKG_DIR/opt/ultrafusion/rviz" \
  "$PKG_DIR/usr/bin"

install -m 0755 "$UF_NODE" "$PKG_DIR/opt/ultrafusion/bin/uf_node"
install -m 0644 "$UF_LIB" "$PKG_DIR/opt/ultrafusion/lib/libultra_lib.so"
install -m 0644 "$GNSS_LIB" "$PKG_DIR/opt/ultrafusion/lib/libgnss_comm.so"
echo "/opt/ultrafusion/lib" >"$PKG_DIR/etc/ld.so.conf.d/ultrafusion.conf"

CERES_LIB="$(resolve_library_path libceres.so.3 "$UF_NODE" "$UF_LIB" || true)"
[[ -n "$CERES_LIB" ]] ||
  die "libceres.so.3 was not found; package in the public Noetic image or pass --extra-lib-dir"
validate_cpu_ceres "$CERES_LIB"
copy_library_family "$CERES_LIB" libceres.so libceres.so.3

YAML_LIB="$(resolve_library_path libyaml-cpp.so.0.8 "$UF_LIB" || true)"
[[ -n "$YAML_LIB" ]] ||
  die "libyaml-cpp.so.0.8 was not found; package in the public Noetic image or pass --extra-lib-dir"
copy_library_family "$YAML_LIB" libyaml-cpp.so libyaml-cpp.so.0.8

strip --strip-unneeded "$PKG_DIR/opt/ultrafusion/bin/uf_node"
strip --strip-unneeded "$PKG_DIR/opt/ultrafusion/lib/libultra_lib.so"
strip --strip-unneeded "$PKG_DIR/opt/ultrafusion/lib/libgnss_comm.so"
strip --strip-unneeded "$(readlink -f "$PKG_DIR/opt/ultrafusion/lib/libceres.so.3")"
strip --strip-unneeded "$(readlink -f "$PKG_DIR/opt/ultrafusion/lib/libyaml-cpp.so.0.8")"

BIN_RPATH='$ORIGIN/../lib:/opt/ultrafusion/lib:/opt/ros/noetic/lib:/usr/local/lib'
LIB_RPATH='$ORIGIN:/opt/ultrafusion/lib:/opt/ros/noetic/lib:/usr/local/lib'
patchelf --set-rpath "$BIN_RPATH" "$PKG_DIR/opt/ultrafusion/bin/uf_node"
patchelf --set-rpath "$LIB_RPATH" "$PKG_DIR/opt/ultrafusion/lib/libultra_lib.so"
patchelf --set-rpath "$LIB_RPATH" "$PKG_DIR/opt/ultrafusion/lib/libgnss_comm.so"
validate_release_runpath "$PKG_DIR/opt/ultrafusion/bin/uf_node" "$BIN_RPATH"
validate_release_runpath "$PKG_DIR/opt/ultrafusion/lib/libultra_lib.so" "$LIB_RPATH"
validate_release_runpath "$PKG_DIR/opt/ultrafusion/lib/libgnss_comm.so" "$LIB_RPATH"

PROFILE_FILES=(
  groundtour/uf_groundtour.yaml
  groundtour/uf_groundtour_arc2.yaml
  groundtour/uf_groundtour_livox.yaml
  kaist/uf_kaist.yaml
  kaist/uf_kaist_urban23.yaml
  kaist/uf_kaist_wio.yaml
  lvig/uf_lvig.yaml
  lvig/uf_lvig_hkairport01.yaml
  lvig/uf_lvig_hkisland03.yaml
  lvig/uf_lvig_lio.yaml
  m2p/uf_m2p.yaml
  m3dgr/uf_m3dgr.yaml
  m3dgr/uf_m3dgr_corridor.yaml
  m3dgr/uf_m3dgr_elevator.yaml
  m3dgr/uf_m3dgr_lio.yaml
  m3dgr/uf_m3dgr_longtime02_lvwio.yaml
  m3dgr/uf_m3dgr_lvio.yaml
  m3dgr/uf_m3dgr_lwio.yaml
  visual_life/config.yaml
)
SUPPORT_FILES=(
  groundtour/zed2i_left.yaml
  kaist/left_kaist.yaml
  lvig/color.yaml
  lvig/lvig_camera.yaml
  lvig/lvig_camera_am.yaml
  m2p/wt_cam.yaml
  m3dgr/color.yaml
  visual_life/cameraA.yaml
  visual_life/cameraB.yaml
  visual_life/cameraC.yaml
  visual_life/vins_multi_config.yaml
)

for relative in "${PROFILE_FILES[@]}"; do
  source_config="$SOURCE_ROOT/config/$relative"
  [[ -f "$source_config" ]] || die "missing ROS1 release profile: $source_config"
  validate_profile_map_flag "$source_config"
  mkdir -p "$PKG_DIR/opt/ultrafusion/config/$(dirname "$relative")"
  install -m 0644 "$source_config" "$PKG_DIR/opt/ultrafusion/config/$relative"
done
for relative in "${SUPPORT_FILES[@]}"; do
  source_config="$SOURCE_ROOT/config/$relative"
  [[ -f "$source_config" ]] || die "missing ROS1 support config: $source_config"
  mkdir -p "$PKG_DIR/opt/ultrafusion/config/$(dirname "$relative")"
  install -m 0644 "$source_config" "$PKG_DIR/opt/ultrafusion/config/$relative"
done

for rviz_config in lio.rviz uf_google_map_overlay.rviz \
    uf_static_pcd_google_map_overlay.rviz; do
  [[ -f "$SOURCE_ROOT/rviz/$rviz_config" ]] ||
    die "missing RViz release layout: $SOURCE_ROOT/rviz/$rviz_config"
  install -m 0644 "$SOURCE_ROOT/rviz/$rviz_config" \
    "$PKG_DIR/opt/ultrafusion/rviz/$rviz_config"
done
install -m 0644 "$SOURCE_ROOT/package.xml" "$PKG_DIR/opt/ultrafusion/package.xml"

cat >"$PKG_DIR/opt/ultrafusion/BUILD_INFO" <<EOF
Ultra-Fusion ROS1 Noetic runtime package
Version: ${VERSION}
Build contract: public Ubuntu 20.04 / ROS Noetic image
EOF

cat >"$PKG_DIR/usr/bin/uf-node" <<'EOF'
#!/usr/bin/env bash
set -eo pipefail
source /opt/ros/noetic/setup.bash
set -u

export LD_LIBRARY_PATH="/opt/ultrafusion/lib:${LD_LIBRARY_PATH:-}"
export ROS_PACKAGE_PATH="/opt/ultrafusion:/opt/ros/noetic/share:${ROS_PACKAGE_PATH:-}"
export ROS_MASTER_URI="${ROS_MASTER_URI:-http://127.0.0.1:11311}"

if [[ $# -eq 0 ]]; then
  exec /opt/ultrafusion/bin/uf_node /opt/ultrafusion/config/m3dgr/uf_m3dgr.yaml
fi

case "$1" in
  m3dgr) config=m3dgr/uf_m3dgr.yaml ;;
  m3dgr-lio) config=m3dgr/uf_m3dgr_lio.yaml ;;
  m3dgr-longtime02-lvwio) config=m3dgr/uf_m3dgr_longtime02_lvwio.yaml ;;
  m3dgr-lvio) config=m3dgr/uf_m3dgr_lvio.yaml ;;
  m3dgr-lwio) config=m3dgr/uf_m3dgr_lwio.yaml ;;
  m2p|m2dgr-plus) config=m2p/uf_m2p.yaml ;;
  lvig) config=lvig/uf_lvig.yaml ;;
  lvig-lio) config=lvig/uf_lvig_lio.yaml ;;
  kaist) config=kaist/uf_kaist.yaml ;;
  kaist-wio) config=kaist/uf_kaist_wio.yaml ;;
  groundtour) config=groundtour/uf_groundtour.yaml ;;
  groundtour-arc2) config=groundtour/uf_groundtour_arc2.yaml ;;
  groundtour-livox) config=groundtour/uf_groundtour_livox.yaml ;;
  visual_life|visual-life|d360) config=visual_life/config.yaml ;;
  *) exec /opt/ultrafusion/bin/uf_node "$@" ;;
esac
shift
exec /opt/ultrafusion/bin/uf_node "/opt/ultrafusion/config/$config" "$@"
EOF
chmod 0755 "$PKG_DIR/usr/bin/uf-node"
ln -s uf-node "$PKG_DIR/usr/bin/uf_node"

for artifact in \
    "$PKG_DIR/opt/ultrafusion/bin/uf_node" \
    "$PKG_DIR/opt/ultrafusion/lib/libultra_lib.so" \
    "$PKG_DIR/opt/ultrafusion/lib/libgnss_comm.so" \
    "$PKG_DIR/opt/ultrafusion/lib/libceres.so.3" \
    "$PKG_DIR/opt/ultrafusion/lib/libyaml-cpp.so.0.8"; do
  validate_staged_linkage "$artifact"
done

INSTALLED_SIZE="$(du -sk "$PKG_DIR" | awk '{print $1}')"
cat >"$PKG_DIR/DEBIAN/control" <<EOF
Package: ${PACKAGE_NAME}
Version: ${VERSION}
Section: robotics
Priority: optional
Architecture: amd64
Installed-Size: ${INSTALLED_SIZE}
Maintainer: Ultra-Fusion Team <sjtuyinjie@sjtu.edu.cn>
Depends: ros-noetic-roscpp, ros-noetic-rosservice, ros-noetic-std-msgs, ros-noetic-std-srvs, ros-noetic-sensor-msgs, ros-noetic-geometry-msgs, ros-noetic-nav-msgs, ros-noetic-tf, ros-noetic-cv-bridge, ros-noetic-image-transport, ros-noetic-image-transport-plugins, libc6, libgcc-s1, libstdc++6, libgomp1, libopencv-core4.2, libopencv-imgproc4.2, libopencv-imgcodecs4.2, libopencv-calib3d4.2, libopencv-features2d4.2, libopencv-highgui4.2, libopencv-video4.2, libpcl-common1.10, libpcl-kdtree1.10, libpcl-search1.10, libpcl-filters1.10, libpcl-features1.10, libpcl-segmentation1.10, libpcl-io1.10, libgoogle-glog0v5, libgflags2.2, libatlas3-base, libcholmod3, libcxsparse3, libspqr2, libunwind8, libtbb2, libx11-6
Description: Ultra-Fusion ROS1 Noetic runtime
 Prebuilt ROS1 Noetic runtime with public benchmark and multi-camera profiles.
EOF

for maintainer_script in postinst postrm; do
  cat >"$PKG_DIR/DEBIAN/$maintainer_script" <<'EOF'
#!/usr/bin/env bash
set -e
ldconfig
exit 0
EOF
  chmod 0755 "$PKG_DIR/DEBIAN/$maintainer_script"
done

rm -f "$DEB_PATH" "$SHA_PATH"
dpkg-deb --root-owner-group --build "$PKG_DIR" "$DEB_PATH"
(
  cd "$OUTPUT_DIR"
  sha256sum "$(basename "$DEB_PATH")" >"$(basename "$SHA_PATH")"
)

echo "Wrote:"
echo "  $DEB_PATH"
echo "  $SHA_PATH"
