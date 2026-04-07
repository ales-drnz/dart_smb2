cmake_minimum_required(VERSION 3.10)

set(PROJECT_NAME "dart_smb2")
project(${PROJECT_NAME} C)

if(POLICY CMP0135)
  cmake_policy(SET CMP0135 NEW)
endif()

# ── dart_smb2 SO Bundling ────────────────────────────────────────────────────
# The pre-built shared library is automatically downloaded from GitHub Releases
# if missing or if the checksum does not match the expected value.

set(_SMB2_SO "${CMAKE_CURRENT_SOURCE_DIR}/libs/libsmb2.so")
set(SMB2_RELEASE_VERSION "libsmb2-r1")
set(EXPECTED_SHA256 "5036560dcc3e4004e4417562d217d08835008071536b84e2a83313ef43ad54b6")

set(DOWNLOAD_NEEDED TRUE)

if(EXISTS "${_SMB2_SO}")
  file(SHA256 "${_SMB2_SO}" ACTUAL_SHA256)
  if(ACTUAL_SHA256 STREQUAL EXPECTED_SHA256)
    set(DOWNLOAD_NEEDED FALSE)
  else()
    message(STATUS "[dart_smb2] SHA-256 mismatch! Expected ${EXPECTED_SHA256} but got ${ACTUAL_SHA256}. Redownloading...")
    file(REMOVE "${_SMB2_SO}")
  endif()
endif()

if(DOWNLOAD_NEEDED)
  message(STATUS "[dart_smb2] Downloading libsmb2_linux-x86_64.so from GitHub Releases...")
  file(MAKE_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/libs")
  file(DOWNLOAD
    "https://github.com/ales-drnz/dart_smb2/releases/download/${SMB2_RELEASE_VERSION}/libsmb2_linux-x86_64.so"
    "${_SMB2_SO}"
    SHOW_PROGRESS
    EXPECTED_HASH SHA256=${EXPECTED_SHA256}
    STATUS DOWNLOAD_STATUS
  )
  list(GET DOWNLOAD_STATUS 0 STATUS_CODE)
  if(NOT STATUS_CODE EQUAL 0)
    list(GET DOWNLOAD_STATUS 1 ERROR_MSG)
    message(FATAL_ERROR "[dart_smb2] Failed to download libsmb2.so: ${ERROR_MSG}")
  endif()
endif()

if(EXISTS "${_SMB2_SO}")
  message(STATUS "[dart_smb2] Using bundled libsmb2: ${_SMB2_SO}")
  set(dart_smb2_bundled_libraries "${_SMB2_SO}" PARENT_SCOPE)
else()
  message(FATAL_ERROR "[dart_smb2] libsmb2.so not found. It must be present in linux/libs/libsmb2.so")
endif()
