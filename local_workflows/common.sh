#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LOCAL_WORK_DIR="${LOCAL_WORK_DIR:-$REPO_ROOT/local_workflows/work}"
LOCAL_OUTPUT_DIR="${LOCAL_OUTPUT_DIR:-$REPO_ROOT/local_workflows/output}"
SDK_VERSION="${SDK_VERSION:-18.6}"
LOCAL_THEOS_DIR="${LOCAL_THEOS_DIR:-$REPO_ROOT/theos}"
LOCAL_TARGET="${LOCAL_TARGET:-iphone:clang:${SDK_VERSION}:13.0}"
LOCAL_WARNING_CFLAGS="${LOCAL_WARNING_CFLAGS:--Wno-error}"
export LOCAL_WORK_DIR LOCAL_OUTPUT_DIR SDK_VERSION LOCAL_THEOS_DIR LOCAL_TARGET LOCAL_WARNING_CFLAGS

log() {
  printf '[local_workflows] %s\n' "$*"
}

die() {
  printf '[local_workflows] error: %s\n' "$*" >&2
  exit 1
}

bool_value() {
  case "${1:-}" in
    true|TRUE|1|yes|YES|y|Y) printf 'true' ;;
    false|FALSE|0|no|NO|n|N) printf 'false' ;;
    *) die "invalid boolean value: ${1:-<empty>}" ;;
  esac
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
}

ensure_dirs() {
  mkdir -p "$LOCAL_WORK_DIR" "$LOCAL_OUTPUT_DIR"
}

new_run_dir() {
  local name="$1"
  ensure_dirs
  local run_dir="$LOCAL_WORK_DIR/${name}-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$run_dir"
  printf '%s\n' "$run_dir"
}

download_url() {
  local url="$1"
  local output="$2"
  require_cmd wget
  wget "$url" --quiet --no-verbose -O "$output"
}

resolve_ipa() {
  local ipa_url="$1"
  local ipa_path="$2"
  local output="$3"

  if [[ -n "$ipa_url" && -n "$ipa_path" ]]; then
    die "use only one of --ipa-url or --ipa-path"
  fi
  if [[ -z "$ipa_url" && -z "$ipa_path" ]]; then
    die "missing IPA input; pass --ipa-url URL or --ipa-path PATH"
  fi

  if [[ -n "$ipa_url" ]]; then
    log "Downloading IPA from URL"
    download_url "$ipa_url" "$output"
  else
    [[ -f "$ipa_path" ]] || die "IPA path does not exist: $ipa_path"
    log "Copying IPA from local path"
    cp "$ipa_path" "$output"
  fi

  validate_ipa "$output"
}

validate_ipa() {
  local ipa_file="$1"
  require_cmd file
  local file_type
  file_type="$(file --mime-type -b "$ipa_file")"
  if [[ "$file_type" != "application/x-ios-app" && "$file_type" != "application/zip" ]]; then
    die "validation failed: not a valid IPA. Detected type: $file_type"
  fi
}

validate_deb() {
  local deb_file="$1"
  require_cmd file
  local deb_type
  deb_type="$(file --mime-type -b "$deb_file")"
  if [[ "$deb_type" != "application/vnd.debian.binary-package" ]]; then
    die "validation failed: not a valid .deb. Detected type: $deb_type"
  fi
}

youtube_version_from_ipa() {
  local ipa_file="$1"
  local extract_dir="$2"
  require_cmd unzip
  rm -rf "$extract_dir"
  unzip -q "$ipa_file" -d "$extract_dir"

  local plist="$extract_dir/Payload/YouTube.app/Info.plist"
  [[ -f "$plist" ]] || die "Info.plist not found at $plist"

  if command -v plutil >/dev/null 2>&1; then
    plutil -extract CFBundleVersion raw -o - "$plist" 2>/dev/null || true
  else
    grep -A 1 '<key>CFBundleVersion</key>' "$plist" | grep '<string>' | awk -F'[><]' '{print $3}'
  fi
}

deb_version() {
  local deb_file="$1"
  local tmp_dir="$2"
  require_cmd ar
  require_cmd tar
  rm -rf "$tmp_dir"
  mkdir -p "$tmp_dir"
  cp "$deb_file" "$tmp_dir/package.deb"
  (
    cd "$tmp_dir"
    ar x package.deb >/dev/null 2>&1
    if [[ -f control.tar.gz ]]; then
      tar -xzf control.tar.gz ./control
    elif [[ -f control.tar.xz ]]; then
      tar -xJf control.tar.xz ./control
    elif [[ -f control.tar.zst ]]; then
      tar --zstd -xf control.tar.zst ./control
    else
      die "could not find control tarball in $deb_file"
    fi
    grep '^Version:' control | awk '{print $2}' | tr -d '\r[:space:]'
  )
}

ensure_homebrew_deps() {
  require_cmd brew
  brew install make ldid swiftlint dpkg
  export PATH="$(brew --prefix make)/libexec/gnubin:$PATH"
}

ensure_cyan() {
  require_cmd pipx
  pipx install --force https://github.com/asdfzxcvbn/pyzule-rw/archive/main.zip
}

ensure_tbd() {
  if [[ ! -x /usr/local/bin/tbd ]]; then
    require_cmd wget
    wget --quiet --no-verbose "https://github.com/inoahdev/tbd/releases/download/2.2/tbd-mac" -O /usr/local/bin/tbd
    chmod +x /usr/local/bin/tbd
  fi
}

ensure_theos() {
  export THEOS="$LOCAL_THEOS_DIR"
  if [[ ! -d "$THEOS" ]]; then
    require_cmd git
    git clone --quiet --depth=1 --recurse-submodules https://github.com/theos/theos.git "$THEOS"
  fi
  mkdir -p "$THEOS/sdks" "$THEOS/include"
}

ensure_ios_sdk() {
  ensure_theos
  if compgen -G "$THEOS/sdks/iPhoneOS${SDK_VERSION}.sdk" >/dev/null; then
    return
  fi
  require_cmd git
  local tmp="$LOCAL_WORK_DIR/iOS-SDKs-${SDK_VERSION}"
  rm -rf "$tmp"
  git clone --quiet --depth=1 -n --filter=tree:0 https://github.com/Tonwalter888/iOS-SDKs.git "$tmp"
  (
    cd "$tmp"
    git sparse-checkout set --no-cone "iPhoneOS${SDK_VERSION}.sdk"
    git checkout
    mv *.sdk "$THEOS/sdks"
  )
}

clone_sparse_appex() {
  local target_dir="$1"
  if [[ -d "$target_dir/OpenYouTubeSafariExtension.appex" ]]; then
    return
  fi
  require_cmd git
  local tmp="$target_dir/OpenYouTubeSafariExtension-src"
  rm -rf "$tmp"
  git clone --quiet -n --depth=1 --filter=tree:0 https://github.com/BillyCurtis/OpenYouTubeSafariExtension.git "$tmp"
  (
    cd "$tmp"
    git sparse-checkout set --no-cone OpenYouTubeSafariExtension.appex
    git checkout
    mv *.appex "$target_dir"
  )
}

clone_headers() {
  ensure_theos
  if [[ ! -d "$THEOS/include/YouTubeHeader" ]]; then
    git clone --quiet --depth=1 https://github.com/PoomSmart/YouTubeHeader.git "$THEOS/include/YouTubeHeader"
  fi
  if [[ "${DEMC:-false}" = "true" && ! -d "$THEOS/include/YTHeaders" ]]; then
    cp -r "$THEOS/include/YouTubeHeader" "$THEOS/include/YTHeaders"
  fi
  if [[ ! -d "$THEOS/include/PSHeader" ]]; then
    git clone --quiet --depth=1 https://github.com/PoomSmart/PSHeader.git "$THEOS/include/PSHeader"
  fi
}

suppress_deprecated_warnings() {
  local file
  while IFS= read -r file; do
    if grep -q 'LOCAL_WORKFLOWS_SUPPRESS_WARNINGS' "$file"; then
      continue
    fi
    perl -0pi -e 's/\A/#pragma clang diagnostic ignored "-Wdeprecated-declarations" \/\/ LOCAL_WORKFLOWS_SUPPRESS_WARNINGS\n#pragma clang diagnostic ignored "-Wunguarded-availability"\n#pragma clang diagnostic ignored "-Wunguarded-availability-new"\n/' "$file"
  done < <(find . -type f \( -name '*.m' -o -name '*.mm' -o -name '*.x' -o -name '*.xm' -o -name '*.xi' \))
}

build_make_deb() {
  local repo_url="$1"
  local repo_dir="$2"
  local output="$3"
  shift 3
  if [[ -f "$output" ]]; then
    log "Using existing $(basename "$output")"
    return
  fi
  git clone --quiet --depth=1 "$repo_url" "$repo_dir"
  (
    cd "$repo_dir"
    suppress_deprecated_warnings
    make clean package \
      THEOS="$THEOS" \
      TARGET="$LOCAL_TARGET" \
      DEBUG=0 \
      FINALPACKAGE=1 \
      CFLAGS+="$LOCAL_WARNING_CFLAGS" \
      OBJCFLAGS+="$LOCAL_WARNING_CFLAGS" \
      ADDITIONAL_CFLAGS+="$LOCAL_WARNING_CFLAGS" \
      ADDITIONAL_CCFLAGS+="$LOCAL_WARNING_CFLAGS" \
      ADDITIONAL_OBJCFLAGS+="$LOCAL_WARNING_CFLAGS" \
      "$@"
    mv packages/*.deb "$output"
  )
}

build_plain_deb() {
  local repo_url="$1"
  local repo_dir="$2"
  local output="$3"
  if [[ -f "$output" ]]; then
    log "Using existing $(basename "$output")"
    return
  fi
  git clone --quiet --depth=1 "$repo_url" "$repo_dir"
  (
    cd "$repo_dir"
    chmod -R 755 .
    dpkg-deb --root-owner-group -Zgzip --build . "$output"
  )
}

build_native_share_deb() {
  local output="$1"
  if [[ -f "$output" ]]; then
    log "Using existing $(basename "$output")"
    return
  fi
  git clone --quiet --depth=1 https://github.com/jkhsjdhjs/youtube-native-share.git youtube-native-share
  (
    cd youtube-native-share
    git clone --quiet --depth=1 https://github.com/protocolbuffers/protobuf.git
    suppress_deprecated_warnings
    make clean package \
      THEOS="$THEOS" \
      DEBUG=0 \
      FINALPACKAGE=1 \
      THEOS_PACKAGE_SCHEME=rootless \
      ARCHS=arm64 \
      CFLAGS+="$LOCAL_WARNING_CFLAGS" \
      OBJCFLAGS+="$LOCAL_WARNING_CFLAGS" \
      ADDITIONAL_CFLAGS+="$LOCAL_WARNING_CFLAGS" \
      ADDITIONAL_CCFLAGS+="$LOCAL_WARNING_CFLAGS" \
      ADDITIONAL_OBJCFLAGS+="$LOCAL_WARNING_CFLAGS"
    mv packages/*.deb "$output"
  )
}

collect_tweaks_arg() {
  local include_appex="$1"
  local tweaks=""
  if [[ "$include_appex" = "true" && -d OpenYouTubeSafariExtension.appex ]]; then
    tweaks="OpenYouTubeSafariExtension.appex"
  fi
  local f
  for f in *.deb; do
    [[ -f "$f" ]] && tweaks="$tweaks $f"
  done
  printf '%s\n' "$tweaks"
}

copy_output() {
  local ipa_file="$1"
  mkdir -p "$LOCAL_OUTPUT_DIR"
  cp "$ipa_file" "$LOCAL_OUTPUT_DIR/"
  log "Output: $LOCAL_OUTPUT_DIR/$(basename "$ipa_file")"
}

print_global_usage() {
  cat <<'USAGE'
Common options:
  --ipa-url URL          URL to the decrypted IPA
  --ipa-path PATH        Local path to the decrypted IPA
  --display-name NAME    App display name (default: YouTube)
  --bundle-id ID         Bundle ID (default: com.google.ios.youtube)
  --work-dir DIR         Work directory (default: local_workflows/work)
  --output-dir DIR       Output directory (default: local_workflows/output)
  --theos-dir DIR        Theos directory (default: ./theos)
  --target TARGET        Theos target (default: iphone:clang:18.6:13.0)
  --warning-cflags FLAGS Warning flags appended to make (default: -Wno-error)

Boolean options accept true/false/1/0/yes/no.
USAGE
}
