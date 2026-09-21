# symbols/

Per-commit Flutter debug info, baked into the Docker image at build time.

A Flutter release build strips and obfuscates its stack traces. Without the
matching DWARF here, a ticket carries frames like `#0 ...+0x1a4` and the
"root cause" section has nothing to point at. The backend degrades quietly in
that case — it still files the ticket, just without file:line — so an empty
directory looks like success until you read a ticket.

Populate it from the app repo, keyed by the same commit the app reports:

```bash
SHA=$(git rev-parse --short HEAD)
flutter build apk --release \
  --split-debug-info=build/symbols/$SHA --obfuscate \
  --dart-define=COMMIT_SHA=$SHA
cp -R build/symbols/$SHA /path/to/incident-backend/symbols/
```

The per-commit subdirectory is not optional: a flat layout makes the
symbolicator decode a trace against whichever build's debug info it finds
first, which yields line numbers that look right and are wrong.

Running locally, mount a directory over `/symbols` instead of committing
anything — see the README.
