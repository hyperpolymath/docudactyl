#!/bin/bash
# Docudactyl HPC — Slurm Job Script
#
# Submit: sbatch deploy/slurm-docudactyl.sh
#
# Adjust --nodes, --ntasks-per-node, and MANIFEST to your cluster.
# Chapel uses GASNet for multi-locale communication.
#
# SPDX-License-Identifier: PMPL-1.0-or-later
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <jonathan.jewell@open.ac.uk>

#SBATCH --job-name=docudactyl-hpc
#SBATCH --nodes=64
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=16
#SBATCH --mem=8G
#SBATCH --time=72:00:00
#SBATCH --output=logs/docudactyl-%j.out
#SBATCH --error=logs/docudactyl-%j.err
#SBATCH --partition=compute

# ── Configuration ────────────────────────────────────────────────────
MANIFEST="${MANIFEST:-/data/manifest.txt}"
OUTPUT_DIR="${OUTPUT_DIR:-/data/output/run-$(date +%Y%m%d-%H%M%S)}"
NUM_LOCALES="${SLURM_NNODES:-64}"
CHUNK_SIZE="${CHUNK_SIZE:-256}"
MANIFEST_MODE="${MANIFEST_MODE:-shared}"  # or "broadcast" if no shared filesystem

# ── Environment ──────────────────────────────────────────────────────
# Chapel GASNet configuration for multi-locale
export CHPL_COMM=gasnet
export CHPL_COMM_SUBSTRATE=ibv  # InfiniBand; use "udp" for Ethernet
export GASNET_PHYSMEM_MAX="6G"
export GASNET_IBV_SPAWNER=ssh

# Ensure the FFI library is findable
export LD_LIBRARY_PATH="/opt/docudactyl/lib:$LD_LIBRARY_PATH"

# ── Pre-flight checks ───────────────────────────────────────────────
echo "=== Docudactyl HPC Cluster Job ==="
echo "Job ID:       $SLURM_JOB_ID"
echo "Nodes:        $SLURM_NNODES"
echo "CPUs/node:    $SLURM_CPUS_PER_TASK"
echo "Manifest:     $MANIFEST"
echo "Output:       $OUTPUT_DIR"
echo "Locales:      $NUM_LOCALES"
echo "Chunk size:   $CHUNK_SIZE"
echo "Manifest mode: $MANIFEST_MODE"
echo ""

# Verify manifest exists
if [ ! -f "$MANIFEST" ]; then
    echo "ERROR: Manifest file not found: $MANIFEST"
    exit 1
fi

MANIFEST_LINES=$(wc -l < "$MANIFEST")
echo "Manifest lines: $MANIFEST_LINES"
echo ""

# Create output and log directories
mkdir -p "$OUTPUT_DIR"
mkdir -p logs

# ── Run ──────────────────────────────────────────────────────────────
echo "Starting Docudactyl HPC at $(date -Iseconds)"
echo ""

srun --mpi=none /opt/docudactyl/bin/docudactyl-hpc \
    --manifestPath="$MANIFEST" \
    --outputDir="$OUTPUT_DIR" \
    --manifestMode="$MANIFEST_MODE" \
    --chunkSize="$CHUNK_SIZE" \
    --resume=true \
    --checkpointIntervalDocs=10000 \
    --progressIntervalSec=60 \
    -nl "$NUM_LOCALES"

EXIT_CODE=$?

echo ""
echo "Docudactyl HPC completed at $(date -Iseconds) with exit code $EXIT_CODE"

# ── Post-processing ──────────────────────────────────────────────────
if [ -f "$OUTPUT_DIR/run-report.scm" ]; then
    echo ""
    echo "=== Run Report ==="
    cat "$OUTPUT_DIR/run-report.scm"
fi

exit $EXIT_CODE
