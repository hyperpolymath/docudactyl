// Docudactyl — ML Inference Engine (ONNX Runtime)
//
// Unified ML inference backend for all ML-dependent processing stages:
//   - NER (Named Entity Recognition) — BERT-NER or spaCy ONNX
//   - Whisper (Audio Transcription) — OpenAI Whisper ONNX
//   - Image Classification — ResNet-50 or ViT ONNX
//   - Layout Analysis — DiT (Document Image Transformer) ONNX
//   - Handwriting OCR — TrOCR ONNX
//
// Uses ONNX Runtime C API via dlopen — no link-time dependency.
// Automatically selects the best execution provider:
//   1. TensorRT (NVIDIA, INT8/FP16 quantised) — fastest
//   2. CUDA (NVIDIA, FP32) — good
//   3. OpenVINO (Intel GPU/NPU) — Intel hardware
//   4. CPU (default) — always available
//
// Chapel calls ddac_ml_init() once per locale, then dispatches stage
// requests via ddac_ml_run_stage(). Each stage loads its model on first
// use (lazy loading) and caches the ONNX session for subsequent calls.
//
// Model paths are configured via ddac_ml_set_model_dir().
//
// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <jonathan.jewell@open.ac.uk>

const std = @import("std");

// ============================================================================
// ML Stage Identifiers
// ============================================================================

/// ML-dependent stages (must match DDAC_STAGE_* bitmask positions)
const MlStage = enum(u8) {
    ner = 0,               // STAGE_NER (bit 14)
    whisper = 1,           // STAGE_WHISPER (bit 15)
    image_classify = 2,    // STAGE_IMAGE_CLASSIFY (bit 16)
    layout_analysis = 3,   // STAGE_LAYOUT_ANALYSIS (bit 17)
    handwriting_ocr = 4,   // STAGE_HANDWRITING_OCR (bit 18)
};

const ML_STAGE_COUNT: usize = 5;

/// Execution provider preference
const ExecProvider = enum(u8) {
    tensorrt = 0,   // NVIDIA TensorRT (INT8/FP16)
    cuda = 1,       // NVIDIA CUDA (FP32)
    openvino = 2,   // Intel OpenVINO
    cpu = 3,        // CPU (ONNX default)
};

// ============================================================================
// ML Inference Result
// ============================================================================

/// Result of running an ML stage on a document.
const MlResult = extern struct {
    /// Status: 0=success, 1=model_not_found, 2=inference_error,
    ///         3=input_error, 4=onnx_not_available
    status: u8,
    /// Which stage produced this result
    stage: u8,
    /// Which execution provider was used
    provider: u8,
    /// Padding
    _pad: [5]u8,
    /// Inference time in microseconds
    inference_time_us: i64,
    /// Number of output tokens/entities/labels
    output_count: i64,
    /// Confidence score (0.0-1.0), -1.0 if not applicable
    confidence: f64,
    /// Output text offset in shared buffer
    text_offset: i64,
    /// Output text length in shared buffer
    text_length: i64,
};

comptime {
    if (@sizeOf(MlResult) != 48)
        @compileError("MlResult must be 48 bytes");
    if (@alignOf(MlResult) != 8)
        @compileError("MlResult must be 8-byte aligned");
}

// ============================================================================
// ONNX Runtime Dynamic Loading
// ============================================================================

/// ONNX Runtime API function pointers (loaded via dlopen)
const OrtApi = struct {
    lib: ?std.DynLib,
    available: bool,
    provider: ExecProvider,
    // In a full implementation, these would be ORT C API function pointers:
    // create_env, create_session, create_session_options, run, etc.
    // For now we track availability and provide the dispatch framework.
};

/// Probe for ONNX Runtime and determine the best execution provider.
fn probeOnnxRuntime() OrtApi {
    var api = OrtApi{
        .lib = null,
        .available = false,
        .provider = .cpu,
    };

    // Try to load ONNX Runtime shared library
    api.lib = std.DynLib.open("libonnxruntime.so") catch
        std.DynLib.open("libonnxruntime.so.1") catch {
        return api; // ONNX Runtime not installed
    };

    api.available = true;

    // Probe execution providers (best first)
    // TensorRT: check for libonnxruntime_providers_tensorrt
    if (std.DynLib.open("libonnxruntime_providers_tensorrt.so")) |lib| {
        lib.close();
        api.provider = .tensorrt;
    } else |_| {
        // CUDA: check for libonnxruntime_providers_cuda
        if (std.DynLib.open("libonnxruntime_providers_cuda.so")) |lib| {
            lib.close();
            api.provider = .cuda;
        } else |_| {
            // OpenVINO: check for libonnxruntime_providers_openvino
            if (std.DynLib.open("libonnxruntime_providers_openvino.so")) |lib| {
                lib.close();
                api.provider = .openvino;
            } else |_| {
                api.provider = .cpu;
            }
        }
    }

    return api;
}

// ============================================================================
// ML Engine State
// ============================================================================

/// Per-stage model session (lazily loaded)
const ModelSession = struct {
    loaded: bool = false,
    model_path: [512]u8 = undefined,
    model_path_len: usize = 0,
    // In full implementation: OrtSession pointer
};

/// ML inference engine state
const MlEngine = struct {
    allocator: std.mem.Allocator,
    ort: OrtApi,
    /// Per-stage model sessions
    sessions: [ML_STAGE_COUNT]ModelSession,
    /// Base directory for model files
    model_dir: [512]u8,
    model_dir_len: usize,
    /// Shared output text buffer
    text_buf: []u8,
    text_buf_used: usize,
    /// Statistics
    total_inferences: u64,
    total_inference_us: u64,

    const TEXT_BUF_SIZE: usize = 512 * 1024; // 512KB shared buffer

    /// Expected model filenames per stage
    const MODEL_NAMES: [ML_STAGE_COUNT][]const u8 = .{
        "ner.onnx",
        "whisper.onnx",
        "image_classify.onnx",
        "layout_analysis.onnx",
        "handwriting_ocr.onnx",
    };

    fn init(allocator: std.mem.Allocator) !*MlEngine {
        const engine = try allocator.create(MlEngine);
        engine.* = .{
            .allocator = allocator,
            .ort = probeOnnxRuntime(),
            .sessions = [_]ModelSession{.{}} ** ML_STAGE_COUNT,
            .model_dir = undefined,
            .model_dir_len = 0,
            .text_buf = try allocator.alloc(u8, TEXT_BUF_SIZE),
            .text_buf_used = 0,
            .total_inferences = 0,
            .total_inference_us = 0,
        };
        // Default model directory
        const default_dir = "models/onnx";
        @memcpy(engine.model_dir[0..default_dir.len], default_dir);
        engine.model_dir_len = default_dir.len;
        return engine;
    }

    fn deinit(self: *MlEngine) void {
        if (self.ort.lib) |*lib| {
            lib.close();
        }
        self.allocator.free(self.text_buf);
        self.allocator.destroy(self);
    }

    /// Set the model directory
    fn setModelDir(self: *MlEngine, dir: []const u8) void {
        const len = @min(dir.len, 511);
        @memcpy(self.model_dir[0..len], dir[0..len]);
        self.model_dir[len] = 0;
        self.model_dir_len = len;
    }

    /// Run an ML stage on a document
    fn runStage(self: *MlEngine, stage: MlStage, input_path: []const u8, output_text: *[]const u8) MlResult {
        var result = std.mem.zeroes(MlResult);
        result.stage = @intFromEnum(stage);

        // Check ONNX Runtime availability
        if (!self.ort.available) {
            result.status = 4; // onnx_not_available
            return result;
        }

        result.provider = @intFromEnum(self.ort.provider);

        // Check model file exists
        const stage_idx = @intFromEnum(stage);
        if (!self.sessions[stage_idx].loaded) {
            // Build model path: {model_dir}/{model_name}
            const model_name = MODEL_NAMES[stage_idx];
            var path_buf: [1024]u8 = undefined;
            const path_len = self.model_dir_len + 1 + model_name.len;
            if (path_len >= 1024) {
                result.status = 1; // model_not_found
                return result;
            }
            @memcpy(path_buf[0..self.model_dir_len], self.model_dir[0..self.model_dir_len]);
            path_buf[self.model_dir_len] = '/';
            @memcpy(path_buf[self.model_dir_len + 1 ..][0..model_name.len], model_name);
            path_buf[path_len] = 0;

            // Check file exists
            std.fs.accessAbsolute(path_buf[0..path_len], .{}) catch {
                result.status = 1; // model_not_found
                return result;
            };

            self.sessions[stage_idx].loaded = true;
            @memcpy(self.sessions[stage_idx].model_path[0..path_len], path_buf[0..path_len]);
            self.sessions[stage_idx].model_path_len = path_len;
        }

        // Run inference
        const start_ns = std.time.nanoTimestamp();

        // In a full implementation, this would:
        //   1. Load the ONNX model (if not cached)
        //   2. Prepare input tensors from the document
        //   3. Run inference via OrtSession::Run()
        //   4. Post-process output tensors
        //   5. Write results to the shared text buffer
        //
        // Each stage has specific preprocessing:
        //   NER: tokenize text → BERT input IDs → run → extract entities
        //   Whisper: audio features → run → decode tokens → text
        //   Image classify: resize/normalize → run → top-k labels
        //   Layout: document image → run → bounding boxes + labels
        //   Handwriting: image patches → run → decode characters
        //
        // For now, we provide the framework and report the stage as
        // "model loaded but inference not yet wired" (status=2).

        _ = input_path;
        _ = output_text;

        const elapsed_ns = std.time.nanoTimestamp() - start_ns;
        result.inference_time_us = @intCast(@divTrunc(elapsed_ns, 1000));
        result.status = 2; // inference_error (stub — not yet wired)
        result.confidence = -1.0;

        self.total_inferences += 1;
        self.total_inference_us += @intCast(result.inference_time_us);

        return result;
    }
};

// ============================================================================
// C-ABI Exports
// ============================================================================

/// Initialise the ML inference engine.
/// Probes for ONNX Runtime and selects the best execution provider.
/// Returns opaque handle or null if allocation fails.
export fn ddac_ml_init() ?*anyopaque {
    const allocator = std.heap.c_allocator;
    const engine = MlEngine.init(allocator) catch return null;
    return @ptrCast(engine);
}

/// Free the ML inference engine.
export fn ddac_ml_free(handle: ?*anyopaque) void {
    const ptr = handle orelse return;
    const engine: *MlEngine = @ptrCast(@alignCast(ptr));
    engine.deinit();
}

/// Check if ONNX Runtime is available.
/// Returns 1 if available, 0 if not.
export fn ddac_ml_available(handle: ?*anyopaque) u8 {
    const ptr = handle orelse return 0;
    const engine: *MlEngine = @ptrCast(@alignCast(ptr));
    return if (engine.ort.available) 1 else 0;
}

/// Get the execution provider in use.
/// Returns: 0=TensorRT, 1=CUDA, 2=OpenVINO, 3=CPU
export fn ddac_ml_provider(handle: ?*anyopaque) u8 {
    const ptr = handle orelse return 3;
    const engine: *MlEngine = @ptrCast(@alignCast(ptr));
    return @intFromEnum(engine.ort.provider);
}

/// Get human-readable name for the execution provider.
export fn ddac_ml_provider_name(handle: ?*anyopaque) [*:0]const u8 {
    const ptr = handle orelse return "unavailable";
    const engine: *MlEngine = @ptrCast(@alignCast(ptr));
    return switch (engine.ort.provider) {
        .tensorrt => "TensorRT (NVIDIA INT8/FP16)",
        .cuda => "CUDA (NVIDIA FP32)",
        .openvino => "OpenVINO (Intel GPU/NPU)",
        .cpu => "CPU (ONNX default)",
    };
}

/// Set the directory containing ONNX model files.
/// Models expected: ner.onnx, whisper.onnx, image_classify.onnx,
///                  layout_analysis.onnx, handwriting_ocr.onnx
export fn ddac_ml_set_model_dir(handle: ?*anyopaque, dir: [*:0]const u8) void {
    const ptr = handle orelse return;
    const engine: *MlEngine = @ptrCast(@alignCast(ptr));
    engine.setModelDir(std.mem.span(dir));
}

/// Run an ML stage on a document.
/// stage: 0=NER, 1=Whisper, 2=ImageClassify, 3=LayoutAnalysis, 4=HandwritingOCR
/// input_path: path to the document/image/audio file
/// result_out: pointer to MlResult (56 bytes)
/// Returns 0 on success (check result.status for stage-level status).
export fn ddac_ml_run_stage(
    handle: ?*anyopaque,
    stage: u8,
    input_path: [*:0]const u8,
    result_out: *MlResult,
) c_int {
    const ptr = handle orelse {
        result_out.* = std.mem.zeroes(MlResult);
        result_out.status = 4; // onnx_not_available
        return -1;
    };
    const engine: *MlEngine = @ptrCast(@alignCast(ptr));

    if (stage >= ML_STAGE_COUNT) {
        result_out.* = std.mem.zeroes(MlResult);
        result_out.status = 3; // input_error
        return -1;
    }

    const ml_stage: MlStage = @enumFromInt(stage);
    var output_text: []const u8 = &.{};
    result_out.* = engine.runStage(ml_stage, std.mem.span(input_path), &output_text);
    return 0;
}

/// Get ML inference statistics.
export fn ddac_ml_stats(
    handle: ?*anyopaque,
    total_inferences: *u64,
    total_inference_us: *u64,
) void {
    const ptr = handle orelse {
        total_inferences.* = 0;
        total_inference_us.* = 0;
        return;
    };
    const engine: *MlEngine = @ptrCast(@alignCast(ptr));
    total_inferences.* = engine.total_inferences;
    total_inference_us.* = engine.total_inference_us;
}

/// Get sizeof(MlResult) for Chapel allocation.
export fn ddac_ml_result_size() usize {
    return @sizeOf(MlResult);
}

/// Get the number of ML stages.
export fn ddac_ml_stage_count() u8 {
    return ML_STAGE_COUNT;
}

/// Get the model filename for a stage.
export fn ddac_ml_model_name(stage: u8) [*:0]const u8 {
    if (stage >= ML_STAGE_COUNT) return "unknown";
    return @ptrCast(MlEngine.MODEL_NAMES[stage].ptr);
}
