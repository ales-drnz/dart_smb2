Pod::Spec.new do |s|
  s.name             = 'dart_smb2'
  s.version          = '0.0.4'
  s.summary          = 'SMB2/3 client for Dart.'
  s.homepage         = 'https://github.com/ales-drnz/dart_smb2'
  s.license          = { :type => 'BSD-3-Clause' }
  s.author           = { 'ales-drnz' => '' }
  s.source           = { :path => '.' }

  s.osx.deployment_target = '10.14'
  s.dependency 'FlutterMacOS'
  s.swift_version = '5.0'

  s.source_files = 'dart_smb2/Sources/dart_smb2/**/*'

  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }

  # ── Download pre-built dylib from GitHub Releases ────────────────────────
  # Runs during `pod install`.
  s.prepare_command = <<-CMD
    set -e
    RELEASE="libsmb2-r3"
    EXPECTED_SHA="cf4c3027c8104a12223fd013e0c5f101a49f7a926143b1da29b1bb1bceb58926"
    DEST="libs/libsmb2.dylib"

    if [ -f "$DEST" ]; then
      ACTUAL_SHA=$(shasum -a 256 "$DEST" | cut -d' ' -f1)
      if [ "$ACTUAL_SHA" = "$EXPECTED_SHA" ]; then
        echo "[dart_smb2] libsmb2.dylib is up to date."
        exit 0
      fi
      echo "[dart_smb2] SHA-256 mismatch, redownloading..."
      rm -f "$DEST"
    fi

    mkdir -p libs
    echo "[dart_smb2] Downloading libsmb2.dylib from GitHub Releases..."
    curl -L -f \
      "https://github.com/ales-drnz/dart_smb2/releases/download/${RELEASE}/libsmb2_macos-arm64.dylib" \
      -o "$DEST"

    ACTUAL_SHA=$(shasum -a 256 "$DEST" | cut -d' ' -f1)
    if [ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]; then
      rm -f "$DEST"
      echo "error: [dart_smb2] SHA-256 verification failed for libsmb2.dylib"
      exit 1
    fi
  CMD

  # ── Copy pre-built dylib into framework ──────────────────────────────────
  s.script_phases = [
    {
      :name               => 'Copy libsmb2 into Framework',
      :execution_position => :after_compile,
      :output_files       => [
        '${TARGET_BUILD_DIR}/${WRAPPER_NAME}/Versions/A/libsmb2.dylib',
      ],
      :script             => <<~SHELL,
        set -e
        DEST="${TARGET_BUILD_DIR}/${WRAPPER_NAME}/Versions/A"
        SRC="${PODS_TARGET_SRCROOT}/libs/libsmb2.dylib"

        if [ ! -f "$SRC" ]; then
          echo "error: libsmb2.dylib not found. Run pod install to download it."
          exit 1
        fi

        mkdir -p "$DEST"
        cp "$SRC" "$DEST/libsmb2.dylib"
        chmod +w "$DEST/libsmb2.dylib"

        install_name_tool -id "@rpath/libsmb2.dylib" "$DEST/libsmb2.dylib" 2>/dev/null
        codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:-}" \
          "$DEST/libsmb2.dylib" 2>/dev/null || \
        codesign --force --sign - "$DEST/libsmb2.dylib"
      SHELL
    }
  ]
end
