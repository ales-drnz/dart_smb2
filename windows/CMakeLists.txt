cmake_minimum_required(VERSION 3.14)

set(PROJECT_NAME "dart_smb2")
project(${PROJECT_NAME} C)

cmake_policy(VERSION 3.14...3.25)

if(POLICY CMP0135)
  cmake_policy(SET CMP0135 NEW)
endif()

# ── libsmb2 Bundling ─────────────────────────────────────────────────────────
# libsmb2.dll is auto-downloaded from GitHub Releases per target arch. Two
# arches are supported (x86_64, arm64) and the binaries live in arch-scoped
# subdirectories: windows/libs/<arch>/libsmb2.dll. The CMake config detects
# the build's target arch and picks the matching subdir.
set(SMB2_RELEASE_VERSION "libsmb2-r7")
set(EXPECTED_SHA256_X86_64  "cae5ba03926771d01b4626ccbb64344751506243f928b50a0a7915d3601b0ed5")
set(EXPECTED_SHA256_ARM64  "637a7ae27c9437844a112c94cbfdf34915ea1cb8da18f9d34cc7c113d8e3d3ff")

if(CMAKE_SYSTEM_PROCESSOR MATCHES "^(ARM64|arm64|aarch64)$")
  set(_SMB2_ARCH         "arm64")
  set(_SMB2_RELEASE_NAME "libsmb2_windows-arm64.dll")
  set(_SMB2_EXPECTED_SHA "${EXPECTED_SHA256_ARM64}")
elseif(CMAKE_SYSTEM_PROCESSOR MATCHES "^(AMD64|x86_64|amd64)$")
  set(_SMB2_ARCH         "x86_64")
  set(_SMB2_RELEASE_NAME "libsmb2_windows-x86_64.dll")
  set(_SMB2_EXPECTED_SHA "${EXPECTED_SHA256_X86_64}")
else()
  message(FATAL_ERROR "[dart_smb2] Unsupported Windows arch: ${CMAKE_SYSTEM_PROCESSOR}. Supported: x86_64 (AMD64), arm64 (ARM64).")
endif()

set(_SMB2_LIB_DIR  "${CMAKE_CURRENT_SOURCE_DIR}/libs/${_SMB2_ARCH}")
set(_BUNDLED_SMB2  "${_SMB2_LIB_DIR}/libsmb2.dll")

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
  set(dart_smb2_bundled_libraries "${_BUNDLED_SMB2}" PARENT_SCOPE)
else()
  message(FATAL_ERROR "[dart_smb2] libsmb2.dll not found. It must be present at ${_BUNDLED_SMB2}")
endif()
