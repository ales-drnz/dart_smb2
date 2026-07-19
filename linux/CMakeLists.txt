cmake_minimum_required(VERSION 3.10)

set(PROJECT_NAME "dart_smb2")
project(${PROJECT_NAME} C)

if(POLICY CMP0135)
  cmake_policy(SET CMP0135 NEW)
endif()

# ── libsmb2 Bundling ─────────────────────────────────────────────────────────
# libsmb2.so is auto-downloaded from GitHub Releases per target arch. Two
# arches are supported (x86_64, aarch64) and the binaries live in arch-scoped
# subdirectories: linux/libs/<arch>/libsmb2.so. The CMake config detects the
# build's target arch and picks the matching subdir.
set(SMB2_RELEASE_VERSION "libsmb2-r6")
set(EXPECTED_SHA256_X86_64  "56540e03d398abdcfc0f9fe643d06dd98633a4c3cb99cf7e19fd8c24c9a05ae1")
set(EXPECTED_SHA256_AARCH64  "530e7dee84dae5f5ec4b802e00b1cde6aceb62c9ba2cff125fe937de97f063a1")

if(CMAKE_SYSTEM_PROCESSOR MATCHES "^(aarch64|arm64)$")
  set(_SMB2_ARCH         "aarch64")
  set(_SMB2_RELEASE_NAME "libsmb2_linux-aarch64.so")
  set(_SMB2_EXPECTED_SHA "${EXPECTED_SHA256_AARCH64}")
elseif(CMAKE_SYSTEM_PROCESSOR MATCHES "^(x86_64|amd64|AMD64)$")
  set(_SMB2_ARCH         "x86_64")
  set(_SMB2_RELEASE_NAME "libsmb2_linux-x86_64.so")
  set(_SMB2_EXPECTED_SHA "${EXPECTED_SHA256_X86_64}")
else()
  message(FATAL_ERROR "[dart_smb2] Unsupported Linux arch: ${CMAKE_SYSTEM_PROCESSOR}. Supported: x86_64, aarch64.")
endif()

set(_SMB2_LIB_DIR  "${CMAKE_CURRENT_SOURCE_DIR}/libs/${_SMB2_ARCH}")
set(_BUNDLED_SMB2  "${_SMB2_LIB_DIR}/libsmb2.so")

set(DOWNLOAD_NEEDED TRUE)
if(EXISTS "${_BUNDLED_SMB2}")
  file(SHA256 "${_BUNDLED_SMB2}" ACTUAL_SHA256)
  if(ACTUAL_SHA256 STREQUAL _SMB2_EXPECTED_SHA)
    set(DOWNLOAD_NEEDED FALSE)
  else()
    message(STATUS "[dart_smb2] SHA-256 mismatch for ${_SMB2_ARCH}: expected ${_SMB2_EXPECTED_SHA} but got ${ACTUAL_SHA256}. Redownloading...")
    file(REMOVE "${_BUNDLED_SMB2}")
  endif()
endif()

if(DOWNLOAD_NEEDED)
  message(STATUS "[dart_smb2] Downloading ${_SMB2_RELEASE_NAME} from GitHub Releases...")
  file(MAKE_DIRECTORY "${_SMB2_LIB_DIR}")
  file(DOWNLOAD
    "https://github.com/ales-drnz/dart_smb2/releases/download/${SMB2_RELEASE_VERSION}/${_SMB2_RELEASE_NAME}"
    "${_BUNDLED_SMB2}"
    SHOW_PROGRESS
    EXPECTED_HASH SHA256=${_SMB2_EXPECTED_SHA}
    STATUS DOWNLOAD_STATUS
  )
  list(GET DOWNLOAD_STATUS 0 STATUS_CODE)
  if(NOT STATUS_CODE EQUAL 0)
    list(GET DOWNLOAD_STATUS 1 ERROR_MSG)
    message(FATAL_ERROR "[dart_smb2] Failed to download ${_SMB2_RELEASE_NAME}: ${ERROR_MSG}. Place it manually at ${_BUNDLED_SMB2}")
  endif()
endif()

if(EXISTS "${_BUNDLED_SMB2}")
  message(STATUS "[dart_smb2] Using bundled libsmb2: ${_BUNDLED_SMB2}")
  set(dart_smb2_bundled_libraries "${_BUNDLED_SMB2}" PARENT_SCOPE)
else()
  message(FATAL_ERROR "[dart_smb2] libsmb2.so not found. It must be present at ${_BUNDLED_SMB2}")
endif()
