Pod::Spec.new do |s|
  s.name             = 'dart_smb2'
  s.version          = '0.0.1'
  s.summary          = 'SMB2/3 client for Dart.'
  s.homepage         = 'https://github.com/ales-drnz/dart_smb2'
  s.license          = { :type => 'BSD-3-Clause' }
  s.author           = { 'ales-drnz' => '' }
  s.source           = { :path => '.' }

  s.ios.deployment_target = '12.0'

  # Pre-built xcframework downloaded from GitHub Releases during `pod install`.
  # Contains device (arm64) + simulator (arm64 + x86_64) slices.
  s.vendored_frameworks = 'libs/libsmb2_ios-arm64.xcframework'

  # DartSmb2ForceLink.m references all smb2w_* symbols so the linker
  # keeps them in the binary. Dart FFI needs them at runtime.
  s.source_files = 'Classes/**/*'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
  }

  # ── Download pre-built xcframework from GitHub Releases ──────────────────
  # Runs during `pod install`.
  # The xcframework is uploaded as a zip: libsmb2_ios-arm64.xcframework.zip
  s.prepare_command = <<-CMD
    set -e
    RELEASE="libsmb2-r1"
    EXPECTED_SHA="b47776fadb75651ff1b2a1bc226a7fe411af6a12dfd51a8802c3544cd9bcb7cb"
    ZIP="libs/libsmb2_ios-arm64.xcframework.zip"
    DEST="libs/libsmb2_ios-arm64.xcframework"

    if [ -d "$DEST" ] && [ -f "${DEST}.sha256" ]; then
      STORED_SHA=$(cat "${DEST}.sha256")
      if [ "$STORED_SHA" = "$EXPECTED_SHA" ]; then
        echo "[dart_smb2] libsmb2_ios-arm64.xcframework is up to date."
        exit 0
      fi
      echo "[dart_smb2] SHA-256 mismatch, redownloading..."
      rm -rf "$DEST" "${DEST}.sha256"
    fi

    mkdir -p libs
    echo "[dart_smb2] Downloading libsmb2_ios-arm64.xcframework.zip from GitHub Releases..."
    curl -L -f \
      "https://github.com/ales-drnz/dart_smb2/releases/download/${RELEASE}/libsmb2_ios-arm64.xcframework.zip" \
      -o "$ZIP"

    ACTUAL_SHA=$(shasum -a 256 "$ZIP" | cut -d' ' -f1)
    if [ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]; then
      rm -f "$ZIP"
      echo "error: [dart_smb2] SHA-256 verification failed for libsmb2_ios-arm64.xcframework.zip"
      exit 1
    fi

    unzip -o "$ZIP" -d libs/
    rm -f "$ZIP"
    echo "$EXPECTED_SHA" > "${DEST}.sha256"

    echo "[dart_smb2] xcframework ready."
  CMD
end
