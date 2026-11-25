# Sirius MI300A Type0 experiment

This directory supports one isolated PBS experiment for `axpy`, `copy`, and
`dot`.  It parses the accepted `run_all.sh.o50858` measurements, calibrates the
Type0 bandwidth, fits the Type0 power coefficients from train rows only, writes
a provisional machine-model copy, runs nine held-out `uv` predictions, and
computes runtime/power/energy MAPE.

The PBS payload copies only the required GenASPEN components into
`$PBSWRAP_WORK`.  It never writes to the canonical
`/work/CSPP/ohara_803/genaspen` tree or its `amd_mi300a.aspen` file.  The three
LLM generations use an instrumented staged copy that records exact Ollama
prompt/completion token counts and per-stage elapsed seconds.

Because PBSWRAP deliberately hides sibling `/work` and `/home` paths, run
`type0/prepare_pbswrap_stage.sh` once on the Sirius login node before
submission.  It creates a new directory under the mounted project and uses
hard links for GenASPEN, the Python environment, Ollama, and model blobs; it
does not alter their canonical files or duplicate their data blocks.

Submit from the MacBook with a 30-minute limit:

```bash
ssh sirius-agent \
  'qsub -N type0-model -A CSPP -q mcrp -l select=1 -l walltime=00:30:00 -j oe' \
  < job/payload-type0-model-sirius.sh
```

The job returns a `summary/type0_axpy_copy_dot_<job-number>.tar.gz` artifact,
plus a compact MAPE table and execution log.  A `SUCCESS` marker is written
only after all nine official predictions are finite, positive where required,
and consistent with direct evaluation of the provisional coefficients.
