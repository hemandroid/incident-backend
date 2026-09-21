# incident-backend

Takes a captured production Flutter crash, decodes its stack trace, has a model
explain it, files a Jira Bug, and posts to Slack. Roughly four seconds from the
crash to a ticket a developer can act on.

Built for the flutterCon India 2026 talk *Beyond Crashlytics: Building
Autonomous Incident Intelligence for Flutter*. It is a small, readable service
rather than a product: about 1,200 lines of Dart with no framework, so you can
read the whole pipeline in one sitting and swap any stage for your own.

## What it does

```
POST /ingest  ->  symbolicate  ->  fingerprint  ->  dedupe  ->  analyse
                                                                   |
                                                      Jira Bug  <--+-->  Slack
```

- **Symbolicate** — Flutter release traces are stripped and obfuscated. This
  decodes them back to `file:line` using the DWARF from
  `--split-debug-info`, keyed by commit.
- **Fingerprint + dedupe** — tapping the same broken button twenty times files
  one ticket, not twenty, and it survives a restart.
- **Analyse** — any OpenAI-compatible endpoint. The ticket gets a bulleted root
  cause and, when a source checkout is available, real before/after code rather
  than prose.
- **File and notify** — a Jira Bug with the trace, breadcrumbs, route history
  and a redacted screenshot; a Slack message linking to it.

Every stage sits behind a contract in `lib/src/contracts.dart`, so replacing
Jira with Linear, or Groq with a local model, is one class.

## Bring your own model

`AI_ENDPOINT`, `AI_API_KEY`, `AI_MODEL` and `AI_AUTH_HEADER` are read at
startup, so the provider is configuration, not code:

| Provider | `AI_ENDPOINT` | `AI_AUTH_HEADER` |
|---|---|---|
| Groq, OpenAI, Together, OpenRouter | the provider's `/chat/completions` | `Authorization` |
| Azure AI Foundry | the deployment URL, plus `AI_API_VERSION` | `api-key` |
| Ollama, on your own machine | `http://localhost:11434/v1/chat/completions` | `Authorization` |

Ollama needs no key and costs nothing, which also means no incident text ever
leaves your network.

## Run it locally

Configuration comes from the environment. Nothing has a default, and a missing
secret stops the process with a message naming every variable it wanted, rather
than starting half-wired and filing nothing.

```bash
cp .env.example .env.local     # then fill it in
set -a && . ./.env.local && set +a
export SYMBOLS_DIR=$PWD/symbols
dart pub get
dart run bin/server.dart
```

`GET /health` answers `ok`. `POST /ingest` takes the SDK's JSON array behind
`Authorization: Bearer $INGEST_APP_TOKEN`.

```bash
dart test       # 134 tests, no network
dart analyze
```

## Run it in Docker

```bash
docker build -t incident-backend .
docker run --rm -p 8787:8787 --env-file .env.local \
  -v "$PWD/symbols:/symbols" -v incident-state:/state incident-backend
```

## Deploy it to Render

`render.yaml` is a Blueprint: **New > Blueprint**, point it at this repo, and
Render prompts for each secret. Or create a Web Service by hand with runtime
Docker and health check path `/health`.

Three things about the free plan will surprise you, so plan around them:

- **It spins down after 15 minutes idle and takes about a minute to wake.** If
  you are demoing live, open `/health` before you start talking.
- **There is no persistent disk.** `DEDUPE_PATH` resets on every spin-down, so
  a repeated crash can file a second ticket. Harmless, but not silent.
- **Render may restart the service at any time.**

Symbols are the one thing that does not survive a naive cloud deploy. See
below.

## Symbols

A release stack trace is meaningless until it is decoded, and the decoder needs
the exact debug info from the build that crashed. Build the app with:

```bash
SHA=$(git rev-parse --short HEAD)
flutter build apk --release \
  --split-debug-info=build/symbols/$SHA --obfuscate \
  --dart-define=COMMIT_SHA=$SHA
```

The per-commit subdirectory is not optional — it is how a trace is matched to
the build that produced it. A flat directory decodes against whichever build's
debug info is found first and yields line numbers that look right and are
wrong.

Locally, point `SYMBOLS_DIR` at `build/symbols` or mount it over `/symbols`.
For a cloud deploy with no disk to mount, copy the per-commit directory into
`symbols/` here and let the Docker build bake it in. If the symbols are
missing the backend still files the ticket — just with an undecoded trace — so
an empty `symbols/` looks like success until you read a ticket.

## Repository layout

```
bin/server.dart        composition root: the only file that knows which
                       concrete class stands behind each contract
lib/src/contracts.dart every seam in one file
lib/src/              symbolicator, fingerprint, dedupe, analyzer, Jira, Slack
test/                 134 tests, all offline
symbols/              per-commit Flutter debug info (see symbols/README.md)
render.yaml           Render Blueprint
```

## Licence

MIT. Take it apart.
