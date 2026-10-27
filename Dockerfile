FROM rocm/pytorch:latest

RUN apt-get update \
 && apt-get install -y --no-install-recommends git ca-certificates \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app
RUN git clone https://github.com/jaredpalmer/kev.git .

# The image ships torch 2.14+rocm, which is outside kev's torch<2.9 window.
# Strategy: keep the image's ROCm torch intact; install every other kev
# dependency normally, then install kev itself with --no-deps so pip
# never tries to replace torch.
RUN python3 - <<'PY' > /tmp/reqs.txt
import tomllib, re
with open("pyproject.toml", "rb") as f:
    p = tomllib.load(f)["project"]
reqs = list(p.get("dependencies", []))
reqs += list(p.get("optional-dependencies", {}).get("serve", []))
for r in reqs:
    if not re.match(r"\s*(torch|torchvision|torchaudio|triton)\b", r, re.I):
        print(r)
PY
RUN cat /tmp/reqs.txt \
 && pip install -r /tmp/reqs.txt \
 && pip install --no-deps -e . \
 && python3 -c "import torch; assert torch.version.hip, 'torch is not a ROCm build'; print('torch', torch.__version__, 'HIP', torch.version.hip)"


# ── Render group ──────────────────────────────────────────────────────────────
# Name only — entrypoint.sh reads the real GID from /dev/dri/renderD* at
# startup and grants it to the app process via setpriv (no fixed GID here).
RUN getent group render || groupadd --system render


# ── Application ──────────────────────────────────────────────────────────────
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 8009
ENTRYPOINT ["/entrypoint.sh"]
CMD [["python3", "-m", "kev.serve", "--device", "cuda", "--host", "0.0.0.0", "--port", "8009", "--run", "jaredpalmer/kev-4b"]
