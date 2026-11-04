# Forged

Forged is a terminal coding assistant with a conversation-first interface. It
can inspect a project, edit files, run commands, and ask for approval when
needed.

## Install

On Linux or macOS, with Git, Python 3.10 or later, a Rust toolchain, and a C build
environment installed, run from this checkout:

```sh
FORGED_SOURCE_DIR="$PWD" sh scripts/install-forged.sh
```

The installer builds Forged and its runtime helpers from source and installs a
`forged` command in `~/.local/bin`. It may take a while and needs network
access for build dependencies. Add that directory to your `PATH` if necessary.
On Linux, the sandbox build also needs `pkg-config` and the libcap development
headers (for example, the `libcap-dev` package on Debian or Ubuntu).
The installer uses one Cargo job by default to limit memory use; set
`CARGO_BUILD_JOBS` to a higher value if your machine has enough memory.

Once this installer and the `forged` build target have been pushed to
`alifwr/forged`, you can install from another machine with:

```sh
curl -fsSL https://raw.githubusercontent.com/alifwr/forged/main/scripts/install-forged.sh | sh
```

The installer builds from the fork's `main` branch; it does not download a
prebuilt release. Set `FORGED_INSTALL_DIR` to change the command directory or
`FORGED_SOURCE_DIR` to build a specific local checkout. Re-running it installs
a new build without changing existing Codex data.

## Run from source

Install the Rust toolchain, then from the repository root run:

```sh
cd codex-rs
cargo run --bin forged
```

On first launch, follow the existing sign-in flow. Forged reads the same
`~/.codex` directory and `CODEX_HOME` override as the upstream CLI, so existing
sessions, authentication, and configuration remain available. The legacy
`codex` build target remains available for upstream tooling compatibility.
Update Forged from this repository and rebuild it; the upstream automatic
updater would install a different application.

To build the executable and use it from another project:

```sh
cargo build --release --bin forged
cd /path/to/your/project
/path/to/forged/codex-rs/target/release/forged
```

## Development

See [installation and build instructions](docs/install.md) for dependencies and
tests, and [updating Forged](docs/updating-forged.md) for merging upstream
changes into this fork.

Forged is based on [OpenAI Codex](https://github.com/openai/codex) and retains
the upstream [Apache 2.0 license](LICENSE) and [notices](NOTICE).
