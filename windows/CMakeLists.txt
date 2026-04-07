cmake_minimum_required(VERSION 3.14)

set(PROJECT_NAME "dart_smb2")
project(${PROJECT_NAME} C)

cmake_policy(VERSION 3.14...3.25)

if(POLICY CMP0135)
  cmake_policy(SET CMP0135 NEW)
endif()

# ── dart_smb2 DLL Bundling ───────────────────────────────────────────────────
# The pre-built DLL is automatically downloaded from GitHub Releases if
# missing or if the checksum does not match the expected value.

set(_SMB2_DLL "${CMAKE_CURRENT_SOURCE_DIR}/libs/libsmb2.dll")
set(SMB2_RELEASE_VERSION "libsmb2-r1")
set(EXPECTED_SHA256 "863e44067e773db7301ed722806ad84439b1a249e65aebc5accb01c3376941b1")

set(DOWNLOAD_NEEDED TRUE)

if(EXISTS "${_SMB2_DLL}")
  file(SHA256 "${_SMB2_DLL}" ACTUAL_SHA256)
  if(ACTUAL_SHA256 STREQUAL EXPECTED_SHA256)
    set(DOWNLOAD_NEEDED FALSE)
  else()
    message(STATUS "[dart_smb2] SHA-256 mismatch! Expected ${EXPECTED_SHA256} but got ${ACTUAL_SHA256}. Redownloading...")
    file(REMOVE "${_SMB2_DLL}")
  endif()
endif()

if(DOWNLOAD_NEEDED)
  message(STATUS "[dart_smb2] Downloading libsmb2_windows-x86_64.dll from GitHub Releases...")
  file(MAKE_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/libs")
  file(DOWNLOAD
    "https://github.com/ales-drnz/dart_smb2/releases/download/${SMB2_RELEASE_VERSION}/libsmb2_windows-x86_64.dll"
    "${_SMB2_DLL}"
    SHOW_PROGRESS
    EXPECTED_HASH SHA256=${EXPECTED_SHA256}
    STATUS DOWNLOAD_STATUS
  )
  list(GET DOWNLOAD_STATUS 0 STATUS_CODE)
  if(NOT STATUS_CODE EQUAL 0)
    list(GET DOWNLOAD_STATUS 1 ERROR_MSG)
    message(FATAL_ERROR "[dart_smb2] Failed to download libsmb2.dll: ${ERROR_MSG}")
  endif()
endif()

if(EXISTS "${_SMB2_DLL}")
  set(dart_smb2_bundled_libraries "${_SMB2_DLL}" PARENT_SCOPE)
else()
  message(FATAL_ERROR "[dart_smb2] libsmb2.dll not found. It must be present in windows/libs/libsmb2.dll")
endif()
