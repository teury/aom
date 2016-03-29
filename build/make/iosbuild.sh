#!/bin/sh
## Copyright (c) 2016, Alliance for Open Media. All rights reserved
##
## This source code is subject to the terms of the BSD 2 Clause License and
## the Alliance for Open Media Patent License 1.0. If the BSD 2 Clause License
## was not distributed with this source code in the LICENSE file, you can
## obtain it at www.aomedia.org/license/software. If the Alliance for Open
## Media Patent License 1.0 was not distributed with this source code in the
## PATENTS file, you can obtain it at www.aomedia.org/license/patent.
##
## This script generates 'AOM.framework'. An iOS app can encode and decode VPx
## video by including 'AOM.framework'.
##
## Run iosbuild.sh to create 'AOM.framework' in the current directory.
##
set -e
devnull='> /dev/null 2>&1'

BUILD_ROOT="_iosbuild"
CONFIGURE_ARGS="--disable-docs
                --disable-examples
                --disable-libyuv
                --disable-unit-tests"
DIST_DIR="_dist"
FRAMEWORK_DIR="AOM.framework"
HEADER_DIR="${FRAMEWORK_DIR}/Headers/aom"
SCRIPT_DIR=$(dirname "$0")
LIBAOM_SOURCE_DIR=$(cd ${SCRIPT_DIR}/../..; pwd)
LIPO=$(xcrun -sdk iphoneos${SDK} -find lipo)
ORIG_PWD="$(pwd)"
ARM_TARGETS="arm64-darwin-gcc
             armv7-darwin-gcc
             armv7s-darwin-gcc"
SIM_TARGETS="x86-iphonesimulator-gcc
             x86_64-iphonesimulator-gcc"
OSX_TARGETS="x86-darwin15-gcc
             x86_64-darwin15-gcc"
TARGETS="${ARM_TARGETS} ${SIM_TARGETS}"

# Configures for the target specified by $1, and invokes make with the dist
# target using $DIST_DIR as the distribution output directory.
build_target() {
  local target="$1"
  local old_pwd="$(pwd)"
  local target_specific_flags=""

  vlog "***Building target: ${target}***"

  case "${target}" in
    x86-*)
      target_specific_flags="--enable-pic"
      vlog "Enabled PIC for ${target}"
      ;;
  esac

  mkdir "${target}"
  cd "${target}"
  eval "${LIBAOM_SOURCE_DIR}/configure" --target="${target}" \
    ${CONFIGURE_ARGS} ${EXTRA_CONFIGURE_ARGS} ${target_specific_flags} \
    ${devnull}
  export DIST_DIR
  eval make dist ${devnull}
  cd "${old_pwd}"

  vlog "***Done building target: ${target}***"
}

# Returns the preprocessor symbol for the target specified by $1.
target_to_preproc_symbol() {
  target="$1"
  case "${target}" in
    arm64-*)
      echo "__aarch64__"
      ;;
    armv7-*)
      echo "__ARM_ARCH_7A__"
      ;;
    armv7s-*)
      echo "__ARM_ARCH_7S__"
      ;;
    x86-*)
      echo "__i386__"
      ;;
    x86_64-*)
      echo "__x86_64__"
      ;;
    *)
      echo "#error ${target} unknown/unsupported"
      return 1
      ;;
  esac
}

# Create a aom_config.h shim that, based on preprocessor settings for the
# current target CPU, includes the real aom_config.h for the current target.
# $1 is the list of targets.
create_aom_framework_config_shim() {
  local targets="$1"
  local config_file="${HEADER_DIR}/aom_config.h"
  local preproc_symbol=""
  local target=""
  local include_guard="AOM_FRAMEWORK_HEADERS_AOM_AOM_CONFIG_H_"

  local file_header="/*
 * Copyright (c) $(date +%Y) Alliance for Open Media. All rights reserved
 *
 * This source code is subject to the terms of the BSD 2 Clause License and
 * the Alliance for Open Media Patent License 1.0. If the BSD 2 Clause License
 * was not distributed with this source code in the LICENSE file, you can
 * obtain it at www.aomedia.org/license/software. If the Alliance for Open
 * Media Patent License 1.0 was not distributed with this source code in the
 * PATENTS file, you can obtain it at www.aomedia.org/license/patent.
 */

/* GENERATED FILE: DO NOT EDIT! */

#ifndef ${include_guard}
#define ${include_guard}

#if defined"

  printf "%s" "${file_header}" > "${config_file}"
  for target in ${targets}; do
    preproc_symbol=$(target_to_preproc_symbol "${target}")
    printf " ${preproc_symbol}\n" >> "${config_file}"
    printf "#define AOM_FRAMEWORK_TARGET \"${target}\"\n" >> "${config_file}"
    printf "#include \"AOM/aom/${target}/aom_config.h\"\n" >> "${config_file}"
    printf "#elif defined" >> "${config_file}"
    mkdir "${HEADER_DIR}/${target}"
    cp -p "${BUILD_ROOT}/${target}/aom_config.h" "${HEADER_DIR}/${target}"
  done

  # Consume the last line of output from the loop: We don't want it.
  sed -i '' -e '$d' "${config_file}"

  printf "#endif\n\n" >> "${config_file}"
  printf "#endif  // ${include_guard}" >> "${config_file}"
}

# Configures and builds each target specified by $1, and then builds
# AOM.framework.
build_framework() {
  local lib_list=""
  local targets="$1"
  local target=""
  local target_dist_dir=""

  # Clean up from previous build(s).
  rm -rf "${BUILD_ROOT}" "${FRAMEWORK_DIR}"

  # Create output dirs.
  mkdir -p "${BUILD_ROOT}"
  mkdir -p "${HEADER_DIR}"

  cd "${BUILD_ROOT}"

  for target in ${targets}; do
    build_target "${target}"
    target_dist_dir="${BUILD_ROOT}/${target}/${DIST_DIR}"
    lib_list="${lib_list} ${target_dist_dir}/lib/libaom.a"
  done

  cd "${ORIG_PWD}"

  # The basic libaom API includes are all the same; just grab the most recent
  # set.
  cp -p "${target_dist_dir}"/include/aom/* "${HEADER_DIR}"

  # Build the fat library.
  ${LIPO} -create ${lib_list} -output ${FRAMEWORK_DIR}/AOM

  # Create the aom_config.h shim that allows usage of aom_config.h from
  # within AOM.framework.
  create_aom_framework_config_shim "${targets}"

  # Copy in aom_version.h.
  cp -p "${BUILD_ROOT}/${target}/aom_version.h" "${HEADER_DIR}"

  vlog "Created fat library ${FRAMEWORK_DIR}/AOM containing:"
  for lib in ${lib_list}; do
    vlog "  $(echo ${lib} | awk -F / '{print $2, $NF}')"
  done

  # TODO(tomfinegan): Verify that expected targets are included within
  # AOM.framework/AOM via lipo -info.
}

# Trap function. Cleans up the subtree used to build all targets contained in
# $TARGETS.
cleanup() {
  local readonly res=$?
  cd "${ORIG_PWD}"

  if [ $res -ne 0 ]; then
    elog "build exited with error ($res)"
  fi

  if [ "${PRESERVE_BUILD_OUTPUT}" != "yes" ]; then
    rm -rf "${BUILD_ROOT}"
  fi
}

print_list() {
  local indent="$1"
  shift
  local list="$@"
  for entry in ${list}; do
    echo "${indent}${entry}"
  done
}

iosbuild_usage() {
cat << EOF
  Usage: ${0##*/} [arguments]
    --help: Display this message and exit.
    --extra-configure-args <args>: Extra args to pass when configuring libaom.
    --macosx: Uses darwin15 targets instead of iphonesimulator targets for x86
              and x86_64. Allows linking to framework when builds target MacOSX
              instead of iOS.
    --preserve-build-output: Do not delete the build directory.
    --show-build-output: Show output from each library build.
    --targets <targets>: Override default target list. Defaults:
$(print_list "        " ${TARGETS})
    --test-link: Confirms all targets can be linked. Functionally identical to
                 passing --enable-examples via --extra-configure-args.
    --verbose: Output information about the environment and each stage of the
               build.
EOF
}

elog() {
  echo "${0##*/} failed because: $@" 1>&2
}

vlog() {
  if [ "${VERBOSE}" = "yes" ]; then
    echo "$@"
  fi
}

trap cleanup EXIT

# Parse the command line.
while [ -n "$1" ]; do
  case "$1" in
    --extra-configure-args)
      EXTRA_CONFIGURE_ARGS="$2"
      shift
      ;;
    --help)
      iosbuild_usage
      exit
      ;;
    --preserve-build-output)
      PRESERVE_BUILD_OUTPUT=yes
      ;;
    --show-build-output)
      devnull=
      ;;
    --test-link)
      EXTRA_CONFIGURE_ARGS="${EXTRA_CONFIGURE_ARGS} --enable-examples"
      ;;
    --targets)
      TARGETS="$2"
      shift
      ;;
    --macosx)
      TARGETS="${ARM_TARGETS} ${OSX_TARGETS}"
      ;;
    --verbose)
      VERBOSE=yes
      ;;
    *)
      iosbuild_usage
      exit 1
      ;;
  esac
  shift
done

if [ "${VERBOSE}" = "yes" ]; then
cat << EOF
  BUILD_ROOT=${BUILD_ROOT}
  DIST_DIR=${DIST_DIR}
  CONFIGURE_ARGS=${CONFIGURE_ARGS}
  EXTRA_CONFIGURE_ARGS=${EXTRA_CONFIGURE_ARGS}
  FRAMEWORK_DIR=${FRAMEWORK_DIR}
  HEADER_DIR=${HEADER_DIR}
  LIBAOM_SOURCE_DIR=${LIBAOM_SOURCE_DIR}
  LIPO=${LIPO}
  MAKEFLAGS=${MAKEFLAGS}
  ORIG_PWD=${ORIG_PWD}
  PRESERVE_BUILD_OUTPUT=${PRESERVE_BUILD_OUTPUT}
  TARGETS="$(print_list "" ${TARGETS})"
  OSX_TARGETS="${OSX_TARGETS}"
  SIM_TARGETS="${SIM_TARGETS}"
EOF
fi

build_framework "${TARGETS}"
echo "Successfully built '${FRAMEWORK_DIR}' for:"
print_list "" ${TARGETS}
