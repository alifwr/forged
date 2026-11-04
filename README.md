# Forged

Forged is a terminal coding assistant with a conversation-first interface. It
can inspect a project, edit files, run commands, and ask for approval when
needed.

## Run from source

Install the Rust toolchain, then from the repository root run:

```sh
cd codex-rs
cargo run --bin codex
```

The executable and configuration paths retain their upstream names for
compatibility. On first launch, follow the existing sign-in flow.

## Development

See [installation and build instructions](docs/install.md) for dependencies and
tests, and [updating Forged](docs/updating-forged.md) for merging upstream
changes into this fork.

Forged is based on [OpenAI Codex](https://github.com/openai/codex) and retains
the upstream [Apache 2.0 license](LICENSE) and [notices](NOTICE).
