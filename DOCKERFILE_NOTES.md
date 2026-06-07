# Dockerfile Notes

## Baseline build

- **Image size:** 214 MB
- **Output of `docker run --rm <image>`:**

```
ONNX model loaded OK: /home/app/model.onnx
  inputs:  1
  outputs: 1
```

---

## Stage 1 (builder) — why it exists

Stage 1 exists because compiling a C program against ONNX Runtime requires
tooling that has no business in a production image: `build-essential` (gcc,
make, binutils), the full ONNX Runtime header tree, and a 100+ MB release
tarball. Installing all that on Debian pulls in roughly 350 MB of compilers
and dev libraries. The build stage is a throw-away workshop — it does all the
heavy lifting (download ORT, compile `check_model.c` against its headers,
validate the bundled `model.onnx`) and then its entire filesystem is discarded
when Docker moves to stage 2. The only artifacts that leave stage 1 are the
compiled binary (`/out/check_model`), the `.so` shared library, and the
validated model file — three small, precise outputs that the runtime stage
cherry-picks with `COPY --from=builder`.

---

## Stage 2 (runtime) — why it exists

Stage 2 exists to be the minimal, safe environment operators actually run.
It starts from a fresh `debian:12-slim` with only two runtime dependencies:
`ca-certificates` (TLS hygiene) and `libstdc++6` (the ONNX Runtime `.so`
uses C++ symbols internally — without it, `dlopen` fails at runtime).
Everything else from stage 1 — the C compiler, the ORT headers, the 130 MB
source tarball, the `apt` package lists — is never copied in. The result is
an image 214 MB rather than the 600 MB a single-stage build would
produce. Stage 2 also owns the non-root user (`app`, uid 1001), the
`LD_LIBRARY_PATH`, the `HEALTHCHECK`, and the `LABEL` metadata — all the
configuration that belongs on a shipped artifact, not a build tool.

---

## Three architectural decisions in this Dockerfile

### 1. Multi-stage split

Without stage 1, we would have no compiled `check_model` binary (GCC is not
in stage 2). Without stage 2 discarding stage 1's filesystem, we would ship
`build-essential` + the full ORT tarball + the ORT header tree into every
deployed container, inflating the image from ~250 MB to ~600 MB and including
a complete C compiler in a runtime environment — an unnecessary attack surface.
The split is the single biggest size and security win in this Dockerfile.

### 2. Validation gate (`file /tmp/model.onnx | grep -qi onnx`)

Without the `test -s` + `file | grep -qi onnx` gate in stage 1, a missing
model file (e.g., developer forgot to `cp model.onnx .` before building) or
a truncated/corrupt artifact would be silently packaged, the image would be
pushed to the registry, and the failure would surface at runtime in production
— the most expensive place to discover it. By making the build *itself* fail
loudly, the gate enforces that only a structurally valid ONNX binary ever
makes it into stage 2. It's a supply-chain checkpoint baked into the build
graph, not a runtime assertion.

### 3. Position of `COPY model.onnx` in stage 1 (cache impact)

`COPY model.onnx` is placed **after** the `apt-get`, the ORT tarball download,
and the GCC compile step — not before them. Docker invalidates all subsequent
layers when a `COPY` layer's content changes. If `COPY model.onnx` were the
first instruction, every time you re-exported an updated model the build would
re-download the 130 MB ONNX Runtime tarball and re-run `gcc`, adding 2–5
minutes to each iteration. By pushing the model copy to the end of stage 1,
those expensive steps stay cache-hit on every rebuild. Only the validation
gate and the model-specific layers re-execute when the model changes — which
is exactly the work that should re-run.

---

## Final build (v2)

- **Image size:** 214 MB
- **Labels** (`docker inspect <image> --format '{{json .Config.Labels}}' | jq .`):

```json
{
  "maintainer": "firuddinrzayev",
  "model.framework": "ultralytics-yolo26",
  "model.source": "m6-09-assessment",
  "ort.version": "1.20.1"
}
```

- **Healthcheck** (`docker inspect <image> --format '{{json .Config.Healthcheck}}'`):

```json
{
  "Test": ["CMD-SHELL", "check_model /home/app/model.onnx || exit 1"],
  "Interval": 30000000000,
  "Timeout": 10000000000,
  "StartPeriod": 5000000000,
  "Retries": 3
}
```

---

## Notes on Task 3b — digest pinning

Both `FROM` lines in the Dockerfile are pinned to the amd64 digest obtained by running:

```bash
docker pull --platform linux/amd64 debian:12-slim
docker inspect --format '{{index .RepoDigests 0}}' debian:12-slim
```

The `--platform=linux/amd64` flag is also baked into both `FROM` lines to prevent Docker Desktop from silently pulling the wrong architecture variant.








