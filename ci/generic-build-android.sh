#!/usr/bin/env bash
set -xe

# Target Android API Version
: "${TARGET_ANDROID_API:=34}"
: "${TARGET_ARCH:=arm64}"

# Working dir
WORKING_DIR=${WORKING_DIR:=$(pwd)}

# Application versions to download (if we don't find a pre-existing install)
# Note: We do not overwrite an existing install, regardless if it's newer
#       Normally we have a clean instance (CI), this is optional to ease local development setup,
#       which may still require some
ANDROID_STUDIO_RELEASE=2025.1.1.13
CMD_TOOLS_RELEASE=13114758_latest

# Plugin versions to download
# Note: We will explicitly try and install these, to ensure consistency
PLUGIN_CMAKE_RELEASE=4.0.2
PLUGIN_NDK_RELEASE=29.0.13599879

# Locations to target
case $(uname -s) in
    Linux)
      ANDROID_SDK_ROOT=$HOME/.android/sdk
    ;;
    Darwin)
      ANDROID_SDK_ROOT=$HOME/Library/Android/sdk
    ;;
esac

# Extra build dependencies (mostly for Android Studio)
case $(uname -s) in
    Linux)
      sudo apt-get install -y wget default-jdk libssl-dev
    ;;
    Darwin)
      brew install java wget qt@5
    ;;
esac

# Download the command line tools plugin, if we do not find it @ ANDROID_SDK_ROOT
if [ -d "${ANDROID_SDK_ROOT}/cmdline-tools" ];
then
  echo "Found Command Line Tools Installation @ $ANDROID_SDK_ROOT/cmdline-tools, skipping installation"
else
  mkdir -p $ANDROID_SDK_ROOT

  case $(uname -s) in
      Linux)
        wget -cO /tmp/commandlinetools-linux-${CMD_TOOLS_RELEASE}.zip https://dl.google.com/android/repository/commandlinetools-linux-${CMD_TOOLS_RELEASE}.zip
        unzip -d $ANDROID_SDK_ROOT /tmp/commandlinetools-linux-${CMD_TOOLS_RELEASE}.zip
      ;;

      Darwin)
        wget -cO /tmp/commandlinetools-mac-${CMD_TOOLS_RELEASE}.zip https://dl.google.com/android/repository/commandlinetools-mac-${CMD_TOOLS_RELEASE}.zip
        unzip -d $ANDROID_SDK_ROOT /tmp/commandlinetools-mac-${CMD_TOOLS_RELEASE}.zip
      ;;
  esac
fi

## If the cmdline-tools plugin was installed via the UI it can end up in a sub dir,
## try and find it to support both our install and an existing development environment
if [ -x "${ANDROID_SDK_ROOT}/cmdline-tools/latest/bin/sdkmanager" ];
then
  ANDROID_SDK_MANAGER="${ANDROID_SDK_ROOT}/cmdline-tools/latest/bin/sdkmanager --sdk_root=${ANDROID_SDK_ROOT}"
else
  ANDROID_SDK_MANAGER="${ANDROID_SDK_ROOT}/cmdline-tools/bin/sdkmanager --sdk_root=${ANDROID_SDK_ROOT}"
fi
echo "Using SDK Manager @ $ANDROID_SDK_MANAGER"

# Download the plugins we require for building (NDK / CMAKE), if we do not find them in ANDROID_SDK_ROOT

## Accept the licenses for everything
## Note: This assumes they have been read and accepted by a human, based on our need to use them for building
echo "Ensuring all licenses are accepted for plugins"
yes | $ANDROID_SDK_MANAGER --licenses

if [ -d "${ANDROID_SDK_ROOT}/cmake/${PLUGIN_CMAKE_RELEASE}" ];
then
  echo "Found CMake plugin @ ${ANDROID_SDK_ROOT}/ndk/${PLUGIN_CMAKE_RELEASE}, skipping installation"
else
  echo "Installing CMake plugin @ $PLUGIN_CMAKE_RELEASE"
  echo $ANDROID_SDK_MANAGER --install "cmake;${PLUGIN_CMAKE_RELEASE}"
  $ANDROID_SDK_MANAGER --install "cmake;${PLUGIN_CMAKE_RELEASE}"
fi

if [ -d "${ANDROID_SDK_ROOT}/ndk/${PLUGIN_NDK_RELEASE}" ];
then
  echo "Found NDK plugin @ ${ANDROID_SDK_ROOT}/ndk/${PLUGIN_NDK_RELEASE}, skipping installation"
else
  echo "Installing NDK plugin @ ${PLUGIN_NDK_RELEASE}"
  $ANDROID_SDK_MANAGER --install "ndk;${PLUGIN_NDK_RELEASE}"
fi

if [ -d "${ANDROID_SDK_ROOT}/platforms/android-${TARGET_ANDROID_API}" ];
then
  echo "Found SDK @ {ANDROID_SDK_ROOT}/platforms/android-${TARGET_ANDROID_API}, skipping installation"
else
  echo "Installing SDK for ${TARGET_ANDROID_API}"
  $ANDROID_SDK_MANAGER --install "platform;android-${TARGET_ANDROID_API}"
fi

## Find the compiler path
case $(uname -s) in
    Linux)
      NDK_TOOLCHAIN="${ANDROID_SDK_ROOT}/ndk/${PLUGIN_NDK_RELEASE}/toolchains/llvm/prebuilt/linux-x86_64"
    ;;
    Darwin)
      NDK_TOOLCHAIN="${ANDROID_SDK_ROOT}/ndk/${PLUGIN_NDK_RELEASE}/toolchains/llvm/prebuilt/darwin-x86_64"
    ;;
esac

# Build the (C++) library
echo "Generating build configs for Android ${TARGET_ANDROID_API} (${TARGET_ARCH})"
mkdir -p "${WORKING_DIR}/build-android-${TARGET_ARCH}"
cd "${WORKING_DIR}/build-android-${TARGET_ARCH}"
$ANDROID_SDK_ROOT/cmake/$PLUGIN_CMAKE_RELEASE/bin/cmake \
  -DCMAKE_BUILD_TYPE=Release \
  -DOCPN_TARGET_TUPLE="Android-${TARGET_ARCH};${TARGET_ANDROID_API};${TARGET_ARCH}" \
  -Dtool_base="${NDK_TOOLCHAIN}" \
  ..

echo "Building core library"
make VERBOSE=1

# Build the App
mkdir -p "${WORKING_DIR}/apk_build"
cd "${WORKING_DIR}/apk_build"

case $TARGET_ARCH in
    arm64)
      QT_BASE="${WORKING_DIR}/cache/OCPNAndroidCoreBuildSupport/qt5/build_arm32_19_O3/qtbase"
    ;;
    armhf)
      QT_BASE="${WORKING_DIR}/cache/OCPNAndroidCoreBuildSupport/qt5/build_arm32_19_O3/qtbase"
    ;;
esac

## Build the library
echo "Generating build configs for QT"
$QT_BASE/bin/qmake \
  -makefile ../buildandroid/opencpn.pro \
  -o Makefile.android -r -spec android-clang CONFIG+=debug

exit
echo "Building QT library"
make -f Makefile.android
make -f Makefile.android install INSTALL_ROOT=./apk_build

## Build APK
echo "Building APK"
$QT_BASE/bin/androiddeployqt \
  --input ./android-libopencpn.so-deployment-settings.json \
  --output ./apk_build \
  --android-platform android-19 \
  --deployment bundled
