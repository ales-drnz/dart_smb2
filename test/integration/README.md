# dart_smb2 integration tests

The suites in this folder run the `Smb2Client` and `Smb2Pool` API against a real Samba 4 server in Docker. A plain `dart test` skips them; CI runs them on every push.

## Running them

```bash
# From the dart_smb2 repo root: start the container and seed the share.
dart run test/integration/bootstrap.dart

# Run every suite, one file at a time (the dart_test.yaml preset).
dart test -P integration

# Only the integration suites.
dart test -P integration --tags integration
```

The bootstrap starts the container with `docker compose up --wait`, gives its `testuser` your uid so it can write to the share folder, and writes a 1 MiB seed file (`dart_smb2_seed.bin`). Running it again leaves a running container and a present seed alone. Each suite works in a scratch folder of its own on the share and removes it at the end.

The library comes from the build hook as in any app: the pinned release, or the binaries `hooks.user_defines` points at (see the package README).

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
docker compose --env-file .env.test.example down -v
rm -rf volumes                                     # the share's files
```

Nothing in `test/` ships to pub.dev.
