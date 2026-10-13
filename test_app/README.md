# dart_smb2_test_app

Internal harness for dart_smb2's on-device integration tests. It is a
minimal Flutter app that depends on the package by path, so its build hook
bundles libsmb2 exactly as in an app, and `integration_test/smoke_test.dart`
drives it on the device. Not a demo and not published: the user-facing
example is `../example/example.dart`.

## Running

```bash
cd test_app
flutter pub get

# Offline: libsmb2 loads, in worker isolates too, and failures classify.
flutter test integration_test -d <device>

# Against a server: start the Samba container from the package root first
# (dart run test/integration/bootstrap.dart).
flutter test integration_test -d linux --dart-define=SMB2_TEST_HOST=127.0.0.1
flutter test integration_test -d emulator-5554 --dart-define=SMB2_TEST_HOST=10.0.2.2
```

`SMB2_TEST_SHARE`, `SMB2_TEST_USER` and `SMB2_TEST_PASS` default to the
container's `public`, `testuser` and `testpass`; any share that holds the
1 MiB `dart_smb2_seed.bin` works, a NAS included. A physical iPhone asks for
local network access the first time.

Before a libsmb2 release is published, point the hook at local binaries in
this app's `pubspec.yaml` (`hooks.user_defines.dart_smb2.libsmb2`), as the
package README describes.

CI runs the suite on every platform (`device` job of
`.github/workflows/ci.yml`): Android and Linux against the Samba container,
iOS, macOS and Windows offline.
