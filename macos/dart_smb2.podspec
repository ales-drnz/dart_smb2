Pod::Spec.new do |s|
  s.name             = 'dart_smb2'
  s.version          = '0.1.3'
  s.summary          = 'SMB2/3 client for Dart.'
  s.homepage         = 'https://github.com/ales-drnz/dart_smb2'
  s.license          = { :type => 'BSD-3-Clause' }
  s.author           = { 'ales-drnz' => '' }
  s.source           = { :path => '.' }
  s.source_files     = 'dart_smb2/Sources/dart_smb2/**/*'
  s.dependency 'FlutterMacOS'
  s.platform         = :osx, '12.0'
  s.swift_version    = '5.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }

  # ── Download pre-built dynamic libsmb2.xcframework from GitHub Releases ────
  # Runs during `pod install`. The xcframework contains a dynamic
  # libsmb2.framework with @rpath install name; CocoaPods handles install_name
  # rewriting + codesigning at build time.
  s.prepare_command = <<-CMD
    set -e
    RELEASE="libsmb2-r8"
    EXPECTED_SHA="97feb9667c80a16840518a7d13749cb9b3c2feb5e306fbacb1203b617eea798e"
    URL="https://github.com/ales-drnz/dart_smb2/releases/download/${RELEASE}/libsmb2_macos.xcframework.zip"

    mkdir -p dart_smb2/Frameworks
    ZIP="dart_smb2/Frameworks/libsmb2_xcframework.zip"
    # SHA-256 check + remote download — toggled by libsmb2-scripts' "Libs"
    # actions: active in REMOTE mode (fetch from GitHub when the vendored
    # xcframework is absent / stale), commented out in LOCAL mode (use the
    # vendored copy only — never download, never replace it). The kit
    # comments/uncomments this block — do not hand-edit the smb2kit: markers.
    # smb2kit:remote:begin
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
      echo "[dart_smb2] Downloading libsmb2_macos.xcframework.zip..."
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
    # smb2kit:remote:end
  CMD

  s.vendored_frameworks = 'dart_smb2/Frameworks/libsmb2.xcframework'
end
