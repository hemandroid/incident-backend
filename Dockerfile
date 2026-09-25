# Build the server to a native executable, then ship only that.
FROM dart:stable AS build
WORKDIR /app
COPY pubspec.* ./
RUN dart pub get
COPY . .
RUN dart pub get --offline && dart compile exe bin/server.dart -o bin/server

# Runtime carries no Dart SDK and no source: a smaller image and nothing to
# read if anyone gets a shell in it.
FROM scratch
COPY --from=build /runtime/ /
COPY --from=build /app/bin/server /app/bin/server

# Symbols are baked in AND mountable. Baked, because free-tier hosting has no
# persistent disk and no way to mount one — an empty /symbols there means every
# ticket quietly arrives with an undecoded stack trace. Mountable, because
# locally the symbols change with every app build and rebuilding the image per
# demo run would be absurd: `-v "$PWD/../build/symbols:/symbols"` masks the
# baked copy. See symbols/README.md.
COPY symbols/ /symbols/
VOLUME /symbols
ENV SYMBOLS_DIR=/symbols

# The app's source, so tickets carry real before/after code instead of a
# described fix. It sits at the SAME absolute path the app was built from,
# because a symbolicated frame names the build machine's path and
# SourceReader only opens files inside SOURCE_DIR (a forged frame must not
# read the server's own files). Re-copy `source/lib` whenever the app changes,
# exactly like the symbols: stale source quotes the wrong lines.
ENV SOURCE_DIR=/Users/hemasai/Mobile_Projects/Mobile_Projects/flutter_demos/rsod_demo
COPY source/ /Users/hemasai/Mobile_Projects/Mobile_Projects/flutter_demos/rsod_demo/

ENV DEDUPE_PATH=/state/dedupe.json
VOLUME /state

# Render overrides PORT; config.dart reads it and falls back to 8787.
EXPOSE 8787
CMD ["/app/bin/server"]
