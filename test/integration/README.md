# dart_smb2 integration tests

The suites in this folder run the `Smb2Client` and `Smb2Pool` API against a real Samba 4 server in Docker. A plain `dart test` skips them; CI runs them on pushes to `main` and `release/**` and on pull requests.

## Running them

```bash
# From the dart_smb2 repo root: start the container and seed the share.
dart run test/integration/bootstrap.dart

# Run every suite, one file at a time (the dart_test.yaml preset).
dart test -P integration

# Only the integration suites.
dart test -P integration test/integration
```

The bootstrap starts the container with `docker compose up --wait`, gives its `testuser` your uid so it can write to the share folder, and writes a 1 MiB seed file (`dart_smb2_seed.bin`). Running it again leaves a running container and a present seed alone. Each suite works in a scratch folder of its own on the share (`zz_<suite>_<random>`) and removes it at the end; the bootstrap removes the ones an interrupted run left behind, once they are ten minutes old.

`pool_network_test.dart` puts a TCP proxy of its own (`TcpProxy` in `_fixture.dart`) between the pool and the container, to cut, freeze and refuse connections.

The library comes from the build hook as in any app: the pinned release, or the binaries `hooks.user_defines` points at (see the package README).

## On the device

These suites run on the host. `test_app/` holds the on-device ones: a
Flutter app that bundles libsmb2 through the hook and runs
`integration_test/smoke_test.dart` on Android, iOS, Linux, macOS and
Windows, offline and, with `--dart-define=SMB2_TEST_HOST=...`, against
this container. See `test_app/README.md`.

## Settings

The container and the tests read `test/integration/.env.test`, or `.env.test.example` when there is none:

```env
SMB2_HOST_PORT=445
SMB2_SHARE=public
SMB2_USER=testuser
SMB2_PASS=testpass
```

The container binds `127.0.0.1` only. If port 445 is taken (macOS File Sharing, another SMB server), set another `SMB2_HOST_PORT` in `.env.test`: the tests connect to `127.0.0.1:<port>`.

## Teardown

```bash
cd test/integration
docker compose --env-file .env.test.example down   # stop, keep the share's files
rm -rf volumes                                     # the share's files (a bind mount)
```

Nothing in `test/` ships to pub.dev.
