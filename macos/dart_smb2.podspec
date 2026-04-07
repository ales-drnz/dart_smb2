Pod::Spec.new do |s|
  s.name             = 'dart_smb2'
  s.version          = '0.0.1'
  s.summary          = 'SMB2/3 client for Dart — native macOS library.'
  s.homepage         = 'https://github.com/ales-drnz/dart_smb2'
  s.license          = { :type => 'BSD-3-Clause' }
  s.author           = { 'ales-drnz' => '' }
  s.source           = { :path => '.' }

  s.osx.deployment_target = '10.14'
  s.dependency 'FlutterMacOS'

  # CocoaPods requires at least one source file to create a framework target.
  # The actual native code is in the pre-built dylib.
  s.source_files = 'dummy.c'

  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }

  # ── Download pre-built dylib from GitHub Releases ────────────────────────
  # Runs during `pod install`.
  s.prepare_command = <<-CMD
    set -e
    RELEASE="libsmb2-r1"
    EXPECTED_SHA="0000000000000000000000000000000000000000000000000000000000000000"
    DEST="libs/libdart_smb2.dylib"

    if [ -f "$DEST" ]; then
      ACTUAL_SHA=$(shasum -a 256 "$DEST" | cut -d' ' -f1)
      if [ "$ACTUAL_SHA" = "$EXPECTED_SHA" ]; then
        echo "[dart_smb2] libdart_smb2.dylib is up to date."
        exit 0
      fi
      echo "[dart_smb2] SHA-256 mismatch, redownloading..."
      rm -f "$DEST"
    fi

    mkdir -p libs
    echo "[dart_smb2] Downloading libdart_smb2.dylib from GitHub Releases..."
    curl -L -f \
      "https://github.com/ales-drnz/dart_smb2/releases/download/${RELEASE}/dart_smb2_macos-universal.dylib" \
      -o "$DEST"

    ACTUAL_SHA=$(shasum -a 256 "$DEST" | cut -d' ' -f1)
    if [ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]; then
      rm -f "$DEST"
      echo "error: [dart_smb2] SHA-256 verification failed for libdart_smb2.dylib"
      exit 1
    fi
  CMD

  # ── Copy pre-built dylib into framework ──────────────────────────────────
  s.script_phases = [
    {
      :name               => 'Copy libdart_smb2 into Framework',
      :execution_position => :after_compile,
      :output_files       => [
        '${TARGET_BUILD_DIR}/${WRAPPER_NAME}/Versions/A/libdart_smb2.dylib',
      ],
      :script             => <<~SHELL,
        set -e
        DEST="${TARGET_BUILD_DIR}/${WRAPPER_NAME}/Versions/A"
        SRC="${PODS_TARGET_SRCROOT}/libs/libdart_smb2.dylib"

        if [ ! -f "$SRC" ]; then
          echo "error: libdart_smb2.dylib not found. Run pod install to download it."
          exit 1
        fi

        mkdir -p "$DEST"
        cp "$SRC" "$DEST/libdart_smb2.dylib"
        chmod +w "$DEST/libdart_smb2.dylib"

        install_name_tool -id "@rpath/libdart_smb2.dylib" "$DEST/libdart_smb2.dylib" 2>/dev/null
        codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:-}" \
          "$DEST/libdart_smb2.dylib" 2>/dev/null || \
        codesign --force --sign - "$DEST/libdart_smb2.dylib"
      SHELL
    }
  ]
end
