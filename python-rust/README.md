# python-rust/

Hybrid Python + Rust devcontainer template. Use when your project has (or will have, in weeks) Rust crates alongside Python code — for example, accelerating a Python hot-path with a native binary called via subprocess, or a PyO3 module.

## What's inside

| Layer | Tools |
|---|---|
| Python | 3.13-slim, uv, ruff (via setup-hooks) |
| Rust | rustup stable + clippy + rustfmt + rust-analyzer |
| Native build | pkg-config, libssl-dev, libasound2-dev, build-essential |
| Web (optional) | Chromium (Chrome DevTools MCP), Node 22 |
| Audio (opt-in) | ffmpeg, libsndfile1, libsox-fmt-all — uncomment the OPTIONAL `RUN` block in `Dockerfile` to enable |
| Dev infra | Docker CLI via host socket, zsh + persistent history, Claude Code |
| Caches (volumes) | cargo registry/git, cargo target, HF_HOME, TORCH_HOME |

## When to use this template

- **`python-rust/`** — your project HAS or WILL HAVE Rust crates. The `rust/` directory and `cargo target/` volume are part of the lifecycle.
- **`python/`** — Python only. Smaller image, faster build.
- **`node/`** — Node only.

Don't pick `python-rust/` "just in case". The Rust toolchain costs ~600 MB of image size and a handful of extra apt packages.

### If you process audio

Uncomment the `OPTIONAL: audio processing libs` block in `Dockerfile` (~85 MB extra). Adds `ffmpeg`, `libsndfile1`, and `libsox-fmt-all` for `pydub` / `soundfile` / `symphonia` / `sox` consumers. The first consumer of this template (`bot202102/audio-a-texto`) does this; most other Python+Rust projects do not need it.

## Layout convention

The template assumes (but does not enforce) this layout in your project:

```
your-project/
├── .devcontainer/        # copy this directory
├── python/               # Python source + pyproject.toml
└── rust/                 # Cargo workspace
    ├── Cargo.toml
    └── crates/
        └── your-crate/
```

The `docker-compose.yml` mounts `${PROJECT_NAME:-app}-target` as a volume at `/workspace/rust/target` — keeping cargo build artifacts off the bind-mount for speed.

## Usage

### 1. Copy the template

```bash
cp -r python-rust/.devcontainer your-project/
cd your-project
```

**Rename the volume prefix** to avoid cache/history collisions when multiple projects use this template simultaneously:

```bash
sed -i 's/pyrust-/your-project-/g' .devcontainer/docker-compose.yml
```

(The default prefix `pyrust-` is a placeholder. Two projects sharing it would mix cargo registry caches, shell history, and HF model caches.)

### 2. Open in VS Code

VS Code → "Reopen in Container". The first build downloads ~1.5 GB and takes 5-10 minutes (Python + Rust + Chromium). Subsequent rebuilds are mostly cached.

### 3. Set up commit-time quality gates (one-time per project)

Inside the container:

```bash
bash .devcontainer/setup-hooks.sh
```

Installs `pre-commit` and configures hooks for ruff (Python) + cargo fmt/clippy (Rust). Hooks run only on staged files at commit time. Zero background CPU.

### 4. Install your Python deps

If your project has `python/pyproject.toml`:
```bash
cd python && sudo uv pip install --system -e .
```

Or with `requirements.txt` at the repo root:
```bash
sudo uv pip install --system -r requirements.txt
```

`sudo` is required because the container installs into the system Python at `/usr/local/lib/python3.13/site-packages` (owned by root). The non-root `dev` user has passwordless sudo, so this is friction-free. The `postCreateCommand` in `devcontainer.json` does this automatically on first build (it tries `python/pyproject.toml` first, falls back to `requirements.txt` at root).

### 5. Build your Rust crates

```bash
cd rust && cargo build --release
```

To install a crate's binary into the container's PATH:
```bash
cargo install --path rust/crates/your-crate
```

## Optional services

The `docker-compose.yml` includes commented-out blocks for Postgres, Redis, Qdrant, Minio, and a Python worker service. Uncomment what you need and update `services.app.depends_on` accordingly. See the comments at the top of the file for port-conflict guidance.

## Persistent caches

Models from HuggingFace and Torch are large. The template mounts them as named volumes:

| Env var | Container path | Volume |
|---|---|---|
| `HF_HOME` | `/home/dev/.cache/huggingface` | `${PROJECT_NAME:-app}-hf-cache` |
| `TORCH_HOME` | `/home/dev/.cache/torch` | `${PROJECT_NAME:-app}-torch-cache` |
| Cargo registry | `/home/dev/.cargo/registry` | `${PROJECT_NAME:-app}-cargo-registry` |
| Cargo git | `/home/dev/.cargo/git` | `${PROJECT_NAME:-app}-cargo-git` |
| Cargo target | `/workspace/rust/target` | `${PROJECT_NAME:-app}-target` |

Models and crate dependencies survive container rebuilds.

## Compatibility

Inherits the troubleshooting fixes documented in the parent repo's [README.md](../README.md):
- WSL PATH injection (Dockerfile uses hardcoded PATH)
- Docker Desktop "No space left on device" (`initializeCommand` cleans VS Code Server residue)
- `userEnvProbe: "none"` to avoid host PATH contamination
- Network healthcheck on the `app` service to detect port-conflict-induced silent disconnects
