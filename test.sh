#!/bin/bash

# Set Working Dir
sudo mkdir -p /opt/ffmpeg_build
sudo chmod 777 /opt/ffmpeg_build -R
sudo chown runner:docker /opt/ffmpeg_build -R

# Update Apt-cache
sudo apt-fast update -qqy

echo "::group:: Change GCC Version to 10"
sudo update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-10 100
sudo update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-9 90
sudo update-alternatives --install /usr/bin/g++ g++ /usr/bin/g++-10 100
sudo update-alternatives --install /usr/bin/g++ g++ /usr/bin/g++-9 90
sudo update-alternatives --install /usr/bin/cpp cpp /usr/bin/cpp-10 100
sudo update-alternatives --install /usr/bin/cpp cpp /usr/bin/cpp-9 90
sudo update-alternatives --install /usr/bin/gcov gcov /usr/bin/gcov-10 100
sudo update-alternatives --install /usr/bin/gcov gcov /usr/bin/gcov-9 90
sudo update-alternatives --install /usr/bin/gcov-dump gcov-dump /usr/bin/gcov-dump-10 100
sudo update-alternatives --install /usr/bin/gcov-dump gcov-dump /usr/bin/gcov-dump-9 90
sudo update-alternatives --install /usr/bin/gcov-tool gcov-tool /usr/bin/gcov-tool-10 100
sudo update-alternatives --install /usr/bin/gcov-tool gcov-tool /usr/bin/gcov-tool-9 90
sudo update-alternatives --install /usr/bin/gcc-ar gcc-ar /usr/bin/gcc-ar-10 100
sudo update-alternatives --install /usr/bin/gcc-ar gcc-ar /usr/bin/gcc-ar-9 90
sudo update-alternatives --install /usr/bin/gcc-nm gcc-nm /usr/bin/gcc-nm-10 100
sudo update-alternatives --install /usr/bin/gcc-nm gcc-nm /usr/bin/gcc-nm-9 90
sudo update-alternatives --install /usr/bin/gcc-ranlib gcc-ranlib /usr/bin/gcc-ranlib-10 100
sudo update-alternatives --install /usr/bin/gcc-ranlib gcc-ranlib /usr/bin/gcc-ranlib-9 90
echo "::endgroup::"

cd /opt/ffmpeg_build
echo "::group:: Prepare ffmpeg dependencies"
sudo apt-fast -qqy install \
  build-essential cmake m4 libtool make automake curl ca-certificates libva-dev libvdpau-dev libmfx-dev libnuma-dev libdrm-dev \
  intel-microcode intel-gpu-tools intel-opencl-icd intel-media-va-driver ocl-icd-opencl-dev opencl-headers \
  libwayland-dev mesa-va-drivers mesa-vdpau-drivers mesa-vulkan-drivers mesa-utils mesa-utils-extra \
  libglx-dev libgl1-mesa-glx libgl1-mesa-dev ninja-build yasm nasm xmlto asciidoc yasm nasm
sudo -EH pip3 install meson
echo "::endgroup::"

echo "::group:: Test Build Partial Codec"

VERSION=1.28.1
CWD=$(pwd)
PACKAGES="$CWD/packages"
WORKSPACE="$CWD/workspace"
CFLAGS="-I$WORKSPACE/include"
LDFLAGS="-L$WORKSPACE/lib"
LDEXEFLAGS=""
EXTRALIBS="-ldl -lpthread -lm -lz"
MACOS_M1=false
CONFIGURE_OPTIONS=()
NONFREE_AND_GPL=false

# Check for Apple Silicon
if [[ ("$(uname -m)" == "arm64") && ("$OSTYPE" == "darwin"*) ]]; then
  # If arm64 AND darwin (macOS)
  export ARCH=arm64
  export MACOSX_DEPLOYMENT_TARGET=11.0
  MACOS_M1=true
fi

# Speed up the process
# Env Var NUMJOBS overrides automatic detection
NUMJOBS=8
if [[ -n "$NUMJOBS" ]]; then
  MJOBS="$NUMJOBS"
elif [[ -f /proc/cpuinfo ]]; then
  MJOBS=$(grep -c processor /proc/cpuinfo)
elif [[ "$OSTYPE" == "darwin"* ]]; then
  MJOBS=$(sysctl -n machdep.cpu.thread_count)
  CONFIGURE_OPTIONS=("--enable-videotoolbox")
else
  MJOBS=4
fi

make_dir() {
  remove_dir "$1"
  if ! mkdir "$1"; then
    printf "\n Failed to create dir %s" "$1"
    exit 1
  fi
}

remove_dir() {
  if [ -d "$1" ]; then
    rm -r "$1"
  fi
}

download() {
  # download url [filename[dirname]]

  DOWNLOAD_PATH="$PACKAGES"
  DOWNLOAD_FILE="${2:-"${1##*/}"}"

  if [[ "$DOWNLOAD_FILE" =~ tar. ]]; then
    TARGETDIR="${DOWNLOAD_FILE%.*}"
    TARGETDIR="${3:-"${TARGETDIR%.*}"}"
  else
    TARGETDIR="${3:-"${DOWNLOAD_FILE%.*}"}"
  fi

  if [ ! -f "$DOWNLOAD_PATH/$DOWNLOAD_FILE" ]; then
    echo "Downloading $1 as $DOWNLOAD_FILE"
    curl -L --silent -o "$DOWNLOAD_PATH/$DOWNLOAD_FILE" "$1"

    EXITCODE=$?
    if [ $EXITCODE -ne 0 ]; then
      echo ""
      echo "Failed to download $1. Exitcode $EXITCODE. Retrying in 10 seconds"
      sleep 10
      curl -L --silent -o "$DOWNLOAD_PATH/$DOWNLOAD_FILE" "$1"
    fi

    EXITCODE=$?
    if [ $EXITCODE -ne 0 ]; then
      echo ""
      echo "Failed to download $1. Exitcode $EXITCODE"
      exit 1
    fi

    echo "... Done"
  else
    echo "$DOWNLOAD_FILE has already downloaded."
  fi

  make_dir "$DOWNLOAD_PATH/$TARGETDIR"

  if [ -n "$3" ]; then
    if ! tar -xvf "$DOWNLOAD_PATH/$DOWNLOAD_FILE" -C "$DOWNLOAD_PATH/$TARGETDIR" 2>/dev/null >/dev/null; then
      echo "Failed to extract $DOWNLOAD_FILE"
      exit 1
    fi
  else
    if ! tar -xvf "$DOWNLOAD_PATH/$DOWNLOAD_FILE" -C "$DOWNLOAD_PATH/$TARGETDIR" --strip-components 1 2>/dev/null >/dev/null; then
      echo "Failed to extract $DOWNLOAD_FILE"
      exit 1
    fi
  fi

  echo "Extracted $DOWNLOAD_FILE"

  cd "$DOWNLOAD_PATH/$TARGETDIR" || (
    echo "Error has occurred."
    exit 1
  )
}

execute() {
  echo "$ $*"

  OUTPUT=$("$@" 2>&1)

  # shellcheck disable=SC2181
  if [ $? -ne 0 ]; then
    echo "$OUTPUT"
    echo ""
    echo "Failed to Execute $*" >&2
    exit 1
  fi
}

build() {
  echo ""
  echo "building $1"
  echo "==========================="

  if [ -f "$PACKAGES/$1.done" ]; then
    echo "$1 already built. Remove $PACKAGES/$1.done lockfile to rebuild it."
    return 1
  fi

  return 0
}

command_exists() {
  if ! [[ -x $(command -v "$1") ]]; then
    return 1
  fi

  return 0
}

library_exists() {
  if ! [[ -x $(pkg-config --exists --print-errors "$1" 2>&1 >/dev/null) ]]; then
    return 1
  fi

  return 0
}

build_done() {
  touch "$PACKAGES/$1.done"
}

verify_binary_type() {
  if ! command_exists "file"; then
    return
  fi

  BINARY_TYPE=$(file "$WORKSPACE/bin/ffmpeg" | sed -n 's/^.*\:\ \(.*$\)/\1/p')
  echo ""
  case $BINARY_TYPE in
  "Mach-O 64-bit executable arm64")
    echo "Successfully built Apple Silicon (M1) for ${OSTYPE}: ${BINARY_TYPE}"
    ;;
  *)
    echo "Successfully built binary for ${OSTYPE}: ${BINARY_TYPE}"
    ;;
  esac
}

cleanup() {
  remove_dir "$PACKAGES"
  remove_dir "$WORKSPACE"
  echo "Cleanup done."
  echo ""
}

usage() {
  echo "Usage: $PROGNAME [OPTIONS]"
  echo "Options:"
  echo "  -h, --help                     Display usage information"
  echo "      --version                  Display version information"
  echo "  -b, --build                    Starts the build process"
  echo "      --enable-gpl-and-non-free  Enable GPL and non-free codecs  - https://ffmpeg.org/legal.html"
  echo "  -c, --cleanup                  Remove all working dirs"
  echo "      --full-static              Build a full static FFmpeg binary (eg. glibc, pthreads etc...) **only Linux**"
  echo "                                 Note: Because of the NSS (Name Service Switch), glibc does not recommend static links."
  echo ""
}

echo "ffmpeg-build-script v$VERSION"
echo "============================="
echo ""

bflag='-b'

LDEXEFLAGS="-static"


echo "Using $MJOBS make jobs simultaneously."

if $NONFREE_AND_GPL; then
  echo "With GPL and non-free codecs"
fi

if [ -n "$LDEXEFLAGS" ]; then
  echo "Start the build in full static mode."
fi

mkdir -p "$PACKAGES"
mkdir -p "$WORKSPACE"

export PATH="${WORKSPACE}/bin:$PATH"
PKG_CONFIG_PATH="/usr/local/lib/x86_64-linux-gnu/pkgconfig:/usr/local/lib/pkgconfig"
PKG_CONFIG_PATH+=":/usr/local/share/pkgconfig:/usr/lib/x86_64-linux-gnu/pkgconfig:/usr/lib/pkgconfig:/usr/share/pkgconfig:/usr/lib64/pkgconfig"
export PKG_CONFIG_PATH

if build "pkg-config"; then
  download "https://pkgconfig.freedesktop.org/releases/pkg-config-0.29.2.tar.gz"
  execute ./configure --silent --prefix="${WORKSPACE}" --with-pc-path="${WORKSPACE}"/lib/pkgconfig --with-internal-glib
  execute make -j $MJOBS
  execute make install
  build_done "pkg-config"
fi

if build "x265"; then
  execute hg clone http://hg.videolan.org/x265 ${PACKAGES}/x265
  cd ${PACKAGES}/x265/build/linux || exit
  mkdir -p 8bit 10bit 12bit
  cd 12bit
  execute cmake -DCMAKE_INSTALL_PREFIX="${WORKSPACE}" -DCMAKE_BUILD_TYPE=Release -DHIGH_BIT_DEPTH=ON -DEXPORT_C_API=OFF -DENABLE_SHARED=OFF -DBUILD_SHARED_LIBS=OFF  -DENABLE_CLI=OFF -DMAIN12=ON -DENABLE_HDR10_PLUS=ON ../../../source
  execute make -j $MJOBS
  cd ../10bit
  execute cmake -DCMAKE_INSTALL_PREFIX="${WORKSPACE}" -DCMAKE_BUILD_TYPE=Release -DHIGH_BIT_DEPTH=ON -DEXPORT_C_API=OFF -DENABLE_SHARED=OFF -DBUILD_SHARED_LIBS=OFF  -DENABLE_CLI=OFF ../../../source
  execute make -j $MJOBS
  cd ../8bit
  ln -sf ../10bit/libx265.a libx265_main10.a
  ln -sf ../12bit/libx265.a libx265_main12.a
  ln -sf ../12bit/libhdr10plus.a libhdr10plus.a
  execute cmake -DCMAKE_INSTALL_PREFIX="${WORKSPACE}" -DCMAKE_BUILD_TYPE=Release -DENABLE_SHARED=OFF -DBUILD_SHARED_LIBS=OFF -DEXTRA_LIB="x265_main10.a;x265_main12.a;libhdr10plus.a;-ldl" -DEXTRA_LINK_FLAGS=-L. -DLINKED_10BIT=ON -DLINKED_12BIT=ON ../../../source
  execute make -j $MJOBS
  mv libx265.a libx265_main.a
  ls -lA .
  if [[ "$OSTYPE" == "darwin"* ]]; then
    execute libtool -static -o libx265.a libx265_main.a libx265_main10.a libx265_main12.a 2>/dev/null
  else
    execute ar -M <<EOF
CREATE libx265.a
ADDLIB libx265_main.a
ADDLIB libx265_main10.a
ADDLIB libx265_main12.a
SAVE
END
EOF
  fi
  ls -lA .
  
  execute make install
  ls -lA "${WORKSPACE}"/bin/
  if [[ "$OSTYPE" == "darwin"* ]]; then
    otool -L "${WORKSPACE}"/bin/x265
  else
    ldd "${WORKSPACE}"/bin/x265
  fi

  if [ -n "$LDEXEFLAGS" ]; then
    sed -i.backup 's/-lgcc_s/-lgcc_eh/g' "${WORKSPACE}/lib/pkgconfig/x265.pc" # The -i.backup is intended and required on MacOS: https://stackoverflow.com/questions/5694228/sed-in-place-flag-that-works-both-on-mac-bsd-and-linux
  fi

  build_done "x265"
fi

echo "::endgroup::"
