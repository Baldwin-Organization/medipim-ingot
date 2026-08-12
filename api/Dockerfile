# Build from the REPO ROOT (the engine is a path dep one level up):
#   docker build -f api/Dockerfile -t golden-record-api .
FROM elixir:1.18-otp-27 AS build

ENV MIX_ENV=prod
RUN mix local.hex --force && mix local.rebar --force

WORKDIR /src
# the engine (path dep "..")
COPY mix.exs ./
COPY lib lib

WORKDIR /src/api
COPY api/mix.exs api/mix.lock ./
RUN mix deps.get --only prod && mix deps.compile

COPY api/config config
COPY api/lib lib
RUN mix release

# ── runtime ────────────────────────────────────────────────────────────────────
FROM postgres:16-bookworm

RUN apt-get update -y \
  && apt-get install -y --no-install-recommends libstdc++6 openssl libncurses6 locales ca-certificates curl \
  && apt-get clean && rm -rf /var/lib/apt/lists/* \
  && sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen

ENV LANG=en_US.UTF-8 LANGUAGE=en_US:en LC_ALL=en_US.UTF-8

WORKDIR /app
RUN useradd --create-home app && chown app /app
USER app

COPY --from=build --chown=app /src/api/_build/prod/rel/golden_record_api ./
COPY --chown=app api/scripts scripts

ENV PORT=4000
EXPOSE 4000

HEALTHCHECK --interval=15s --timeout=3s --start-period=10s \
  CMD ["/bin/sh", "-c", "curl --fail --silent --show-error http://localhost:${PORT}/ready >/dev/null"]

CMD ["bin/golden_record_api", "start"]
