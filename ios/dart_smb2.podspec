Pod::Spec.new do |s|
  s.name             = 'dart_smb2'
  s.version          = '0.0.2'
  s.summary          = 'SMB2/3 client for Dart.'
  s.homepage         = 'https://github.com/ales-drnz/dart_smb2'
  s.license          = { :type => 'BSD-3-Clause' }
  s.author           = { 'ales-drnz' => '' }
  s.source           = { :path => '.' }

  s.ios.deployment_target = '12.0'
  s.dependency 'Flutter'
  s.swift_version = '5.0'

  # Pre-built xcframework downloaded from GitHub Releases during `pod install`.
  # Contains device (arm64) + simulator (arm64 + x86_64) slices.
  s.vendored_frameworks = 'libs/libsmb2_ios-arm64.xcframework'

  s.source_files = 'dart_smb2/Sources/dart_smb2/**/*'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
  }

  # ── Download pre-built xcframework from GitHub Releases ──────────────────
  # Runs during `pod install`.
  # The xcframework is uploaded as a zip: libsmb2_ios-arm64.xcframework.zip
  s.prepare_command = <<-CMD
    set -e
    RELEASE="libsmb2-r2"
    EXPECTED_SHA="86e257d6784d54ebbb82557e0c807bab9929ceb60d76ff4b79248e10522cf124"
    URL="https://github.com/ales-drnz/dart_smb2/releases/download/${RELEASE}/libsmb2_ios-arm64.xcframework.zip"

    mkdir -p libs
    ZIP="libs/libsmb2_ios-arm64.xcframework.zip"
    DOWNLOAD_NEEDED=1

    if [ -f "libs/libsmb2_ios-arm64.xcframework/Info.plist" ] && [ -f "$ZIP" ]; then
      ACTUAL_SHA=$(shasum -a 256 "$ZIP" | awk '{ print $1 }')
      if [ "$ACTUAL_SHA" = "$EXPECTED_SHA" ]; then
        DOWNLOAD_NEEDED=0
      else
        echo "[dart_smb2] SHA-256 mismatch, redownloading..."
        rm -rf "libs/libsmb2_ios-arm64.xcframework"
        rm -f "$ZIP"
      fi
    elif [ -d "libs/libsmb2_ios-arm64.xcframework" ] && [ ! -f "$ZIP" ]; then
      DOWNLOAD_NEEDED=0
    fi

    if [ $DOWNLOAD_NEEDED -eq 1 ]; then
      echo "[dart_smb2] Downloading libsmb2_ios-arm64.xcframework.zip..."
      curl -L -f -o "$ZIP" "$URL"

      ACTUAL_SHA=$(shasum -a 256 "$ZIP" | awk '{ print $1 }')
      if [ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]; then
        rm -f "$ZIP"
        echo "error: [dart_smb2] SHA-256 verification failed!"
        exit 1
      fi

      unzip -o "$ZIP" -d libs/
      rm -f "$ZIP"
    fi
  CMD
end
