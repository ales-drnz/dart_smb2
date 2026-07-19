Pod::Spec.new do |s|
  s.name             = 'dart_smb2'
  s.version          = '0.1.1'
  s.summary          = 'SMB2/3 client for Dart.'
  s.homepage         = 'https://github.com/ales-drnz/dart_smb2'
  s.license          = { :type => 'BSD-3-Clause' }
  s.author           = { 'ales-drnz' => '' }
  s.source           = { :path => '.' }
  s.source_files     = 'dart_smb2/Sources/dart_smb2/**/*'
  s.dependency 'Flutter'
  s.platform         = :ios, '15.0'
  s.swift_version    = '5.0'

  # ── Download pre-built dynamic libsmb2.xcframework from GitHub Releases ────
  # Runs during `pod install`. The xcframework contains a dynamic
  # libsmb2.framework with @rpath install name, signed by CocoaPods at build
  # time alongside the rest of the app's frameworks.
  s.prepare_command = <<-CMD
    set -e
    RELEASE="libsmb2-r6"
    EXPECTED_SHA="c1021ba1c8c5f93e6260044fb1350c1645c9dff614d3dc512eaf188564ef5631"
    URL="https://github.com/ales-drnz/dart_smb2/releases/download/${RELEASE}/libsmb2_ios.xcframework.zip"

    mkdir -p dart_smb2/Frameworks
    ZIP="dart_smb2/Frameworks/libsmb2_xcframework.zip"
    DOWNLOAD_NEEDED=1

    if [ -f "dart_smb2/Frameworks/libsmb2.xcframework/Info.plist" ] && [ -f "$ZIP" ]; then
      ACTUAL_SHA=$(shasum -a 256 "$ZIP" | awk '{ print $1 }')
      if [ "$ACTUAL_SHA" = "$EXPECTED_SHA" ]; then
        DOWNLOAD_NEEDED=0
      else
        echo "[dart_smb2] SHA-256 mismatch, redownloading..."
        rm -rf "dart_smb2/Frameworks/libsmb2.xcframework"
        rm -f "$ZIP"
      fi
    elif [ -d "dart_smb2/Frameworks/libsmb2.xcframework" ] && [ ! -f "$ZIP" ]; then
      DOWNLOAD_NEEDED=0
    fi

    if [ $DOWNLOAD_NEEDED -eq 1 ]; then
      echo "[dart_smb2] Downloading libsmb2_ios.xcframework.zip..."
      curl -L -f -o "$ZIP" "$URL"

      ACTUAL_SHA=$(shasum -a 256 "$ZIP" | awk '{ print $1 }')
      if [ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]; then
        rm -f "$ZIP"
        echo "error: [dart_smb2] SHA-256 verification failed!"
        exit 1
      fi

      unzip -o "$ZIP" -d dart_smb2/Frameworks/
      rm -f "$ZIP"
    fi
  CMD

  s.vendored_frameworks = 'dart_smb2/Frameworks/libsmb2.xcframework'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'ENABLE_BITCODE' => 'NO',
  }
end
