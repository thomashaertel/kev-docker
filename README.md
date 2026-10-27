# Kev on AMD GPU (ROCm) with Docker Compose

Community setup based on the `rocm/pytorch` image. Kev has no official ROCm Dockerfile.
Status: the image builds on the author's host; end-to-end GPU inference has not been verified here.

## Files

| File | Purpose |
| --- | --- |
| `Dockerfile` | Builds on `rocm/pytorch:latest`, clones Kev, installs its dependencies |
| `docker-compose.yml` | Passes `/dev/kfd` and `/dev/dri`, publishes the port, sets the serve command |
| `entrypoint.sh` | Reads the GPU device GIDs and starts the server with those groups |
| `.env` | Model, bind address, port, API key |
| `test-kev.sh` | Sends a sample request to `/v1/systemone` |

## Quick start

1. Edit `.env`: set `KEV_API_KEY` (e.g. `openssl rand -hex 24`) and `KEV_MODEL`.
2. Build and start: `docker compose up -d --build`
3. Watch the logs until the model is loaded: `docker compose logs -f kev`
   (the first start downloads the model from the Hugging Face Hub into the `huggingface-cache` volume).
4. Verify the GPU:
   `docker compose exec kev python3 -c "import torch; print(torch.version.hip, torch.cuda.is_available(), torch.cuda.get_device_name(0))"`
   `torch.version.hip` must not be `None`, and the device name must be your discrete GPU, not the iGPU.
5. Test the API: `./test-kev.sh` (reads `KEV_API_KEY` from `.env`; optional args: `./test-kev.sh HOST PORT`).

## Available models

| Model | Hub ID | Min VRAM |
| --- | --- | --- |
| Kev-0.8B | `jaredpalmer/kev-0.8b` | 4 GB (any GPU) |
| Kev-4B | `jaredpalmer/kev-4b` | ~16 GB (L40S / H100 class) |
| Kev-9B | `jaredpalmer/kev-9b` | ~24 GB (L40S / H100 class) |
| Kev-27B | `jaredpalmer/kev-27b` | 80 GB (B200 / H200 / H100 80 GB) |

Start with `kev-0.8b` to verify the setup. Set `KEV_MODEL` in `.env` to switch models. The model is downloaded from the Hugging Face Hub on first start into the `huggingface-cache` volume.

## Configuration (`.env`)

| Variable | Default | Meaning |
| --- | --- | --- |
| `KEV_MODEL` | `jaredpalmer/kev-0.8b` | Hub ID, optionally with a revision (`jaredpalmer/kev-4b@v1.0`) |
| `KEV_HOST` | `127.0.0.1` | Host interface the port binds to (`0.0.0.0` exposes it to the network) |
| `KEV_PORT` | `8009` | Host port (the container always listens on 8009) |
| `KEV_API_KEY` | empty | Passed into the container as `KEV_API_KEY` |

`VIDEO_GID` and `RENDER_GID` in `.env` are no longer used: `docker-compose.yml` has no `group_add`, and `entrypoint.sh` reads the GIDs from the device nodes at start-up. You can delete them.

## API

Kev serves a System One compatible API on port 8009:

```bash
curl -s http://127.0.0.1:8009/v1/systemone \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer change-me" \
  -d '{"state":"Shoes arrived late and wrong size, also double-charged.",
       "model":"kev-latest",
       "questions":{
         "dept":   {"type":"choice","instructions":"Which team?",
                    "criteria":{"returns":"Wrong/damaged items","billing":"Payment issues"}},
         "urgent": {"type":"noul","instructions":"Needs urgent attention?"}
       }}'
```

Question types are `noul` (probability of "yes"), `choice` and `score` (both need `criteria`). See `test-kev.sh` for all three. The `Authorization` header is only needed when your server enforces the key; I have not confirmed how the server reads `KEV_API_KEY`, so check the Kev README if you get a 401.

## How the container is wired

- **Torch:** the image ships a ROCm torch (2.14) that is newer than Kev's declared `torch<2.9`. The Dockerfile keeps the image's torch, installs every other dependency from `pyproject.toml`, then installs Kev with `--no-deps`. The build ends with an assertion that `torch.version.hip` is set. Kev may still misbehave on the newer torch at runtime.
- **GPU groups:** the Dockerfile creates `render` and `video` groups so Docker can start the container. `entrypoint.sh` reads the real GIDs from `/dev/kfd` and `/dev/dri/renderD*` and starts the server with those supplementary groups via `setpriv`.
- **Command:** the serve command comes from `command:` in `docker-compose.yml` and is passed to `entrypoint.sh` as `"$@"`. The Dockerfile has no `CMD`, so `docker run` without arguments starts nothing useful.
- **Model:** `KEV_MODEL` is substituted into `--run` in `docker-compose.yml`.

## Troubleshooting

- **`Unable to find group render`:** rebuild (`docker compose up --build`); the Dockerfile must contain the `groupadd` step.
- **`setpriv: command not found`:** add `util-linux` to the `apt-get install` line in the Dockerfile.
- **`HIP` assertion fails during build:** pip replaced the ROCm torch with another build; check the build log for the torch line.
- **GPU not used or wrong GPU:** run step 4 and compare the device name with `rocminfo`. On a machine with an iGPU and a discrete GPU, a `HSA_OVERRIDE_GFX_VERSION` set from assumptions can select the wrong device; set it only from the real `rocminfo` value.
- **Out of memory:** use a smaller model (`kev-0.8b` or `kev-4b`).
- **Port already in use:** change `KEV_PORT` in `.env`.
