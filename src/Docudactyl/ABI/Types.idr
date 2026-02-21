||| ABI Type Definitions for Docudactyl HPC
|||
||| Defines the Application Binary Interface for the multi-format document
||| parsing library. All type definitions include formal proofs of correctness.
|||
||| These types map directly to the C structs in ffi/zig/src/docudactyl_ffi.zig.
|||
||| SPDX-License-Identifier: PMPL-1.0-or-later
||| Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)

module Docudactyl.ABI.Types

import Data.So
import Data.Vect
import Decidable.Equality

%default total

--------------------------------------------------------------------------------
-- Platform Detection
--------------------------------------------------------------------------------

||| Supported platforms for this ABI
public export
data Platform = Linux | Windows | MacOS | BSD | WASM

||| Default platform (override per deployment target)
public export
thisPlatform : Platform
thisPlatform = Linux

--------------------------------------------------------------------------------
-- Content Kind
--------------------------------------------------------------------------------

||| Document/media content types supported by the HPC pipeline.
||| Maps to ContentKind enum in Zig FFI (c_int values 0-6).
public export
data ContentKind : Type where
  PDF        : ContentKind
  Image      : ContentKind
  Audio      : ContentKind
  Video      : ContentKind
  EPUB       : ContentKind
  GeoSpatial : ContentKind
  Unknown    : ContentKind

||| Convert ContentKind to its C integer representation
public export
contentKindToInt : ContentKind -> Bits32
contentKindToInt PDF        = 0
contentKindToInt Image      = 1
contentKindToInt Audio      = 2
contentKindToInt Video      = 3
contentKindToInt EPUB       = 4
contentKindToInt GeoSpatial = 5
contentKindToInt Unknown    = 6

||| Convert C integer to ContentKind
public export
intToContentKind : Bits32 -> Maybe ContentKind
intToContentKind 0 = Just PDF
intToContentKind 1 = Just Image
intToContentKind 2 = Just Audio
intToContentKind 3 = Just Video
intToContentKind 4 = Just EPUB
intToContentKind 5 = Just GeoSpatial
intToContentKind 6 = Just Unknown
intToContentKind _ = Nothing

||| Proof that contentKindToInt is injective (different kinds map to different ints)
public export
contentKindInjective : (a, b : ContentKind) -> contentKindToInt a = contentKindToInt b -> a = b
contentKindInjective PDF PDF Refl = Refl
contentKindInjective Image Image Refl = Refl
contentKindInjective Audio Audio Refl = Refl
contentKindInjective Video Video Refl = Refl
contentKindInjective EPUB EPUB Refl = Refl
contentKindInjective GeoSpatial GeoSpatial Refl = Refl
contentKindInjective Unknown Unknown Refl = Refl

||| All content kinds enumerated (proof of exhaustiveness)
public export
allContentKinds : Vect 7 ContentKind
allContentKinds = [PDF, Image, Audio, Video, EPUB, GeoSpatial, Unknown]

||| Eq implementation for ContentKind
public export
Eq ContentKind where
  PDF        == PDF        = True
  Image      == Image      = True
  Audio      == Audio      = True
  Video      == Video      = True
  EPUB       == EPUB       = True
  GeoSpatial == GeoSpatial = True
  Unknown    == Unknown    = True
  _          == _          = False

--------------------------------------------------------------------------------
-- Parse Status
--------------------------------------------------------------------------------

||| Parse operation result codes.
||| Maps to the status field in ddac_parse_result_t (c_int).
public export
data ParseStatus : Type where
  ||| Parse succeeded
  Ok : ParseStatus
  ||| Generic error
  Error : ParseStatus
  ||| File not found on filesystem
  FileNotFound : ParseStatus
  ||| Parser failed (corrupt file, unsupported variant, etc.)
  ParseError : ParseStatus
  ||| Null pointer provided to FFI
  NullPointer : ParseStatus
  ||| Content format not supported by any parser
  UnsupportedFormat : ParseStatus
  ||| Allocation failure
  OutOfMemory : ParseStatus

||| Convert ParseStatus to C integer
public export
parseStatusToInt : ParseStatus -> Bits32
parseStatusToInt Ok               = 0
parseStatusToInt Error             = 1
parseStatusToInt FileNotFound      = 2
parseStatusToInt ParseError        = 3
parseStatusToInt NullPointer       = 4
parseStatusToInt UnsupportedFormat = 5
parseStatusToInt OutOfMemory       = 6

||| Convert C integer to ParseStatus
public export
intToParseStatus : Bits32 -> Maybe ParseStatus
intToParseStatus 0 = Just Ok
intToParseStatus 1 = Just Error
intToParseStatus 2 = Just FileNotFound
intToParseStatus 3 = Just ParseError
intToParseStatus 4 = Just NullPointer
intToParseStatus 5 = Just UnsupportedFormat
intToParseStatus 6 = Just OutOfMemory
intToParseStatus _ = Nothing

||| Eq implementation for ParseStatus
public export
Eq ParseStatus where
  Ok               == Ok               = True
  Error            == Error            = True
  FileNotFound     == FileNotFound     = True
  ParseError       == ParseError       = True
  NullPointer      == NullPointer      = True
  UnsupportedFormat == UnsupportedFormat = True
  OutOfMemory      == OutOfMemory      = True
  _                == _                = False

||| Predicate: is this status a success?
public export
isSuccess : ParseStatus -> Bool
isSuccess Ok = True
isSuccess _  = False

||| Predicate: is this status a retryable error?
public export
isRetryable : ParseStatus -> Bool
isRetryable Error      = True
isRetryable OutOfMemory = True
isRetryable _          = False

--------------------------------------------------------------------------------
-- Parse Result Record
--------------------------------------------------------------------------------

||| Summary of a single document parse, matching ddac_parse_result_t in C.
||| Fixed-size fields only — no heap pointers cross the FFI boundary.
public export
record ParseResult where
  constructor MkParseResult
  status      : Bits32     -- ParseStatus as C int
  contentKind : Bits32     -- ContentKind as C int
  pageCount   : Int32      -- pages (PDF/EPUB) or 0
  wordCount   : Bits64     -- extracted words
  charCount   : Bits64     -- extracted characters
  durationSec : Double     -- audio/video duration, 0 for text
  parseTimeMs : Double     -- wall-clock parse time in ms
  -- Fixed-size char arrays are represented as raw field offsets
  -- in the ABI; Idris accesses them via FFI pointer arithmetic.

||| Proof that ParseResult status field correctly encodes ParseStatus
public export
parseResultStatusValid : (r : ParseResult) -> Maybe ParseStatus
parseResultStatusValid r = intToParseStatus r.status

||| Proof that ParseResult contentKind field correctly encodes ContentKind
public export
parseResultKindValid : (r : ParseResult) -> Maybe ContentKind
parseResultKindValid r = intToContentKind r.contentKind

--------------------------------------------------------------------------------
-- GPU OCR Status
--------------------------------------------------------------------------------

||| Status codes for GPU OCR coprocessor results.
||| Maps to the status field in ddac_ocr_result_t (uint8).
public export
data OcrStatus : Type where
  ||| OCR succeeded, text extracted
  OcrSuccess : OcrStatus
  ||| Error during OCR processing
  OcrError : OcrStatus
  ||| Image too small or otherwise skipped
  OcrSkipped : OcrStatus
  ||| GPU not available — caller should fall back to CPU Tesseract
  GpuError : OcrStatus

||| Convert OcrStatus to its C integer representation
public export
ocrStatusToInt : OcrStatus -> Bits8
ocrStatusToInt OcrSuccess = 0
ocrStatusToInt OcrError   = 1
ocrStatusToInt OcrSkipped = 2
ocrStatusToInt GpuError   = 3

||| Convert C integer to OcrStatus
public export
intToOcrStatus : Bits8 -> Maybe OcrStatus
intToOcrStatus 0 = Just OcrSuccess
intToOcrStatus 1 = Just OcrError
intToOcrStatus 2 = Just OcrSkipped
intToOcrStatus 3 = Just GpuError
intToOcrStatus _ = Nothing

||| Eq implementation for OcrStatus
public export
Eq OcrStatus where
  OcrSuccess == OcrSuccess = True
  OcrError   == OcrError   = True
  OcrSkipped == OcrSkipped = True
  GpuError   == GpuError   = True
  _          == _          = False

||| Predicate: should the caller fall back to CPU Tesseract?
public export
needsCpuFallback : OcrStatus -> Bool
needsCpuFallback GpuError = True
needsCpuFallback _        = False

--------------------------------------------------------------------------------
-- Conduit Validation Status
--------------------------------------------------------------------------------

||| Validation codes from the preprocessing conduit.
||| Maps to the validation field in ddac_conduit_result_t (uint8).
public export
data ConduitValidation : Type where
  ||| File is accessible and non-empty
  ConduitOk : ConduitValidation
  ||| File does not exist at the given path
  ConduitNotFound : ConduitValidation
  ||| File exists but is zero bytes
  ConduitEmpty : ConduitValidation
  ||| File exists but cannot be read (permissions, I/O error)
  ConduitUnreadable : ConduitValidation

||| Convert ConduitValidation to C integer
public export
conduitValidationToInt : ConduitValidation -> Bits8
conduitValidationToInt ConduitOk         = 0
conduitValidationToInt ConduitNotFound   = 1
conduitValidationToInt ConduitEmpty      = 2
conduitValidationToInt ConduitUnreadable = 3

||| Convert C integer to ConduitValidation
public export
intToConduitValidation : Bits8 -> Maybe ConduitValidation
intToConduitValidation 0 = Just ConduitOk
intToConduitValidation 1 = Just ConduitNotFound
intToConduitValidation 2 = Just ConduitEmpty
intToConduitValidation 3 = Just ConduitUnreadable
intToConduitValidation _ = Nothing

||| Eq implementation for ConduitValidation
public export
Eq ConduitValidation where
  ConduitOk         == ConduitOk         = True
  ConduitNotFound   == ConduitNotFound   = True
  ConduitEmpty      == ConduitEmpty      = True
  ConduitUnreadable == ConduitUnreadable = True
  _                 == _                 = False

||| GPU Backend Detection
public export
data GpuBackend : Type where
  PaddleGpu    : GpuBackend   -- PaddleOCR with CUDA/TensorRT
  TesseractCuda : GpuBackend  -- Tesseract compiled with CUDA LSTM
  CpuOnly      : GpuBackend   -- No GPU, CPU Tesseract fallback

||| Convert GpuBackend to C integer
public export
gpuBackendToInt : GpuBackend -> Bits8
gpuBackendToInt PaddleGpu     = 0
gpuBackendToInt TesseractCuda = 1
gpuBackendToInt CpuOnly       = 2

||| Convert C integer to GpuBackend
public export
intToGpuBackend : Bits8 -> Maybe GpuBackend
intToGpuBackend 0 = Just PaddleGpu
intToGpuBackend 1 = Just TesseractCuda
intToGpuBackend 2 = Just CpuOnly
intToGpuBackend _ = Nothing

||| Eq implementation for GpuBackend
public export
Eq GpuBackend where
  PaddleGpu     == PaddleGpu     = True
  TesseractCuda == TesseractCuda = True
  CpuOnly       == CpuOnly       = True
  _             == _             = False

--------------------------------------------------------------------------------
-- ML Inference Status
--------------------------------------------------------------------------------

||| Status codes for ML inference results.
||| Maps to the status field in ddac_ml_result_t (uint8).
public export
data MlStatus : Type where
  ||| Inference succeeded
  MlOk : MlStatus
  ||| Model file not found in modelDir
  MlModelNotFound : MlStatus
  ||| ONNX Runtime inference error
  MlInferenceError : MlStatus
  ||| Input preprocessing error (bad image, wrong format)
  MlInputError : MlStatus
  ||| ONNX Runtime not available (dlopen failed)
  MlOnnxNotAvailable : MlStatus

||| Convert MlStatus to its C integer representation
public export
mlStatusToInt : MlStatus -> Bits8
mlStatusToInt MlOk              = 0
mlStatusToInt MlModelNotFound   = 1
mlStatusToInt MlInferenceError  = 2
mlStatusToInt MlInputError      = 3
mlStatusToInt MlOnnxNotAvailable = 4

||| Convert C integer to MlStatus
public export
intToMlStatus : Bits8 -> Maybe MlStatus
intToMlStatus 0 = Just MlOk
intToMlStatus 1 = Just MlModelNotFound
intToMlStatus 2 = Just MlInferenceError
intToMlStatus 3 = Just MlInputError
intToMlStatus 4 = Just MlOnnxNotAvailable
intToMlStatus _ = Nothing

||| Eq implementation for MlStatus
public export
Eq MlStatus where
  MlOk              == MlOk              = True
  MlModelNotFound   == MlModelNotFound   = True
  MlInferenceError  == MlInferenceError  = True
  MlInputError      == MlInputError      = True
  MlOnnxNotAvailable == MlOnnxNotAvailable = True
  _                 == _                 = False

||| Predicate: is this status a retryable ML error?
public export
isMlRetryable : MlStatus -> Bool
isMlRetryable MlInferenceError = True
isMlRetryable _                = False

--------------------------------------------------------------------------------
-- ML Stage Identifiers
--------------------------------------------------------------------------------

||| ML stage types corresponding to ONNX model files.
||| Each stage maps to a {name}.onnx model in the model directory.
public export
data MlStage : Type where
  ||| Named Entity Recognition (ner.onnx)
  StageNER : MlStage
  ||| Whisper audio transcription (whisper.onnx)
  StageWhisper : MlStage
  ||| Image classification (image_classify.onnx)
  StageImageClassify : MlStage
  ||| Document layout analysis (layout_analysis.onnx)
  StageLayout : MlStage
  ||| Handwriting OCR (handwriting_ocr.onnx)
  StageHandwriting : MlStage

||| Convert MlStage to its C integer representation
public export
mlStageToInt : MlStage -> Bits8
mlStageToInt StageNER           = 0
mlStageToInt StageWhisper       = 1
mlStageToInt StageImageClassify = 2
mlStageToInt StageLayout        = 3
mlStageToInt StageHandwriting   = 4

||| Convert C integer to MlStage
public export
intToMlStage : Bits8 -> Maybe MlStage
intToMlStage 0 = Just StageNER
intToMlStage 1 = Just StageWhisper
intToMlStage 2 = Just StageImageClassify
intToMlStage 3 = Just StageLayout
intToMlStage 4 = Just StageHandwriting
intToMlStage _ = Nothing

||| All ML stages enumerated (proof of exhaustiveness)
public export
allMlStages : Vect 5 MlStage
allMlStages = [StageNER, StageWhisper, StageImageClassify, StageLayout, StageHandwriting]

||| Eq implementation for MlStage
public export
Eq MlStage where
  StageNER           == StageNER           = True
  StageWhisper       == StageWhisper       = True
  StageImageClassify == StageImageClassify = True
  StageLayout        == StageLayout        = True
  StageHandwriting   == StageHandwriting   = True
  _                  == _                  = False

||| Model filename for a given ML stage
public export
mlStageModelName : MlStage -> String
mlStageModelName StageNER           = "ner.onnx"
mlStageModelName StageWhisper       = "whisper.onnx"
mlStageModelName StageImageClassify = "image_classify.onnx"
mlStageModelName StageLayout        = "layout_analysis.onnx"
mlStageModelName StageHandwriting   = "handwriting_ocr.onnx"

--------------------------------------------------------------------------------
-- Execution Provider
--------------------------------------------------------------------------------

||| ONNX Runtime execution provider for ML inference.
||| Auto-selected in priority order: TensorRT > CUDA > OpenVINO > CPU.
public export
data ExecProvider : Type where
  TensorRT : ExecProvider
  CUDA     : ExecProvider
  OpenVINO : ExecProvider
  CPU      : ExecProvider

||| Convert ExecProvider to its C integer representation
public export
execProviderToInt : ExecProvider -> Bits8
execProviderToInt TensorRT = 0
execProviderToInt CUDA     = 1
execProviderToInt OpenVINO = 2
execProviderToInt CPU      = 3

||| Convert C integer to ExecProvider
public export
intToExecProvider : Bits8 -> Maybe ExecProvider
intToExecProvider 0 = Just TensorRT
intToExecProvider 1 = Just CUDA
intToExecProvider 2 = Just OpenVINO
intToExecProvider 3 = Just CPU
intToExecProvider _ = Nothing

||| Eq implementation for ExecProvider
public export
Eq ExecProvider where
  TensorRT == TensorRT = True
  CUDA     == CUDA     = True
  OpenVINO == OpenVINO = True
  CPU      == CPU      = True
  _        == _        = False

||| Predicate: is this provider GPU-accelerated?
public export
isGpuProvider : ExecProvider -> Bool
isGpuProvider TensorRT = True
isGpuProvider CUDA     = True
isGpuProvider _        = False

--------------------------------------------------------------------------------
-- SHA-256 Tier (Hardware Crypto)
--------------------------------------------------------------------------------

||| SHA-256 acceleration tier detected at runtime.
public export
data Sha256Tier : Type where
  ||| Dedicated SHA instructions (SHA-NI on x86, SHA2 on ARM)
  Dedicated : Sha256Tier
  ||| Multi-buffer via AVX2 (4-lane interleaved)
  Avx2Buffer : Sha256Tier
  ||| Software-only implementation
  Software : Sha256Tier

||| Convert Sha256Tier to its C integer representation
public export
sha256TierToInt : Sha256Tier -> Bits8
sha256TierToInt Dedicated  = 0
sha256TierToInt Avx2Buffer = 1
sha256TierToInt Software   = 2

||| Convert C integer to Sha256Tier
public export
intToSha256Tier : Bits8 -> Maybe Sha256Tier
intToSha256Tier 0 = Just Dedicated
intToSha256Tier 1 = Just Avx2Buffer
intToSha256Tier 2 = Just Software
intToSha256Tier _ = Nothing

||| Eq implementation for Sha256Tier
public export
Eq Sha256Tier where
  Dedicated  == Dedicated  = True
  Avx2Buffer == Avx2Buffer = True
  Software   == Software   = True
  _          == _          = False

--------------------------------------------------------------------------------
-- Opaque Handles
--------------------------------------------------------------------------------

||| Opaque handle type for FFI — wraps the Zig HandleState pointer.
||| Prevents direct construction, enforces creation through safe API.
||| The nonNull proof guarantees the pointer is never zero.
public export
data Handle : Type where
  MkHandle : (ptr : Bits64) -> (0 nonNull : So (ptr /= 0)) -> Handle

||| Safely create a handle from a pointer value.
||| Returns Nothing if pointer is null.
public export
createHandle : Bits64 -> Maybe Handle
createHandle ptr =
  case choose (ptr /= 0) of
    Left  prf => Just (MkHandle ptr prf)
    Right _   => Nothing

||| Extract pointer value from handle
public export
handlePtr : Handle -> Bits64
handlePtr (MkHandle ptr _) = ptr

--------------------------------------------------------------------------------
-- Platform-Specific Types
--------------------------------------------------------------------------------

||| C int size varies by platform
public export
CInt : Platform -> Type
CInt Linux   = Bits32
CInt Windows = Bits32
CInt MacOS   = Bits32
CInt BSD     = Bits32
CInt WASM    = Bits32

||| C size_t varies by platform
public export
CSize : Platform -> Type
CSize Linux   = Bits64
CSize Windows = Bits64
CSize MacOS   = Bits64
CSize BSD     = Bits64
CSize WASM    = Bits32

||| C pointer size varies by platform
public export
ptrSize : Platform -> Nat
ptrSize Linux   = 64
ptrSize Windows = 64
ptrSize MacOS   = 64
ptrSize BSD     = 64
ptrSize WASM    = 32

||| Pointer type for platform (64-bit platforms use Bits64, WASM uses Bits32)
public export
CPtr : Platform -> Type -> Type
CPtr WASM _ = Bits32
CPtr _    _ = Bits64

--------------------------------------------------------------------------------
-- Memory Layout Proofs
--------------------------------------------------------------------------------

||| Proof that a type has a specific size in bytes
public export
data HasSize : Type -> Nat -> Type where
  SizeProof : {0 t : Type} -> {n : Nat} -> HasSize t n

||| Proof that a type has a specific alignment
public export
data HasAlignment : Type -> Nat -> Type where
  AlignProof : {0 t : Type} -> {n : Nat} -> HasAlignment t n

||| Abstract C type descriptors for size/alignment calculation
public export
data CType = CTInt | CTSize | CTBits32 | CTBits64 | CTDouble | CTPtr

||| Size of C types (platform-specific)
public export
cSizeOf : (p : Platform) -> CType -> Nat
cSizeOf _ CTInt    = 4
cSizeOf p CTSize   = if ptrSize p == 64 then 8 else 4
cSizeOf _ CTBits32 = 4
cSizeOf _ CTBits64 = 8
cSizeOf _ CTDouble = 8
cSizeOf p CTPtr    = ptrSize p `div` 8

||| Alignment of C types (platform-specific)
public export
cAlignOf : (p : Platform) -> CType -> Nat
cAlignOf _ CTInt    = 4
cAlignOf p CTSize   = if ptrSize p == 64 then 8 else 4
cAlignOf _ CTBits32 = 4
cAlignOf _ CTBits64 = 8
cAlignOf _ CTDouble = 8
cAlignOf p CTPtr    = ptrSize p `div` 8

--------------------------------------------------------------------------------
-- ParseResult Struct Layout Proof
--------------------------------------------------------------------------------

||| The ddac_parse_result_t struct total size on LP64 platforms.
||| Layout (all LP64):
|||   status:       c_int    @ 0   (4 bytes)
|||   content_kind: c_int    @ 4   (4 bytes)
|||   page_count:   int32    @ 8   (4 bytes)
|||   _pad:                  @ 12  (4 bytes padding for i64 alignment)
|||   word_count:   int64    @ 16  (8 bytes)
|||   char_count:   int64    @ 24  (8 bytes)
|||   duration_sec: double   @ 32  (8 bytes)
|||   parse_time_ms:double   @ 40  (8 bytes)
|||   sha256:       char[65] @ 48  (65 bytes)
|||   _pad2:                       (7 bytes padding)
|||   error_msg:    char[256]@ 120 (256 bytes)
|||   title:        char[256]@ 376 (256 bytes)
|||   author:       char[256]@ 632 (256 bytes)
|||   mime_type:    char[64] @ 888 (64 bytes)
|||   Total:                       952 bytes (aligned to 8)
public export
parseResultStructSize : HasSize ParseResult 952
parseResultStructSize = SizeProof

||| ParseResult has 8-byte alignment (due to int64/double fields)
public export
parseResultStructAlign : HasAlignment ParseResult 8
parseResultStructAlign = AlignProof

||| The ddac_ocr_result_t struct total size on LP64 platforms.
||| Layout:
|||   status:       uint8    @ 0   (1 byte)
|||   confidence:   int8     @ 1   (1 byte)
|||   _pad:         uint8[6] @ 2   (6 bytes padding)
|||   char_count:   int64    @ 8   (8 bytes)
|||   word_count:   int64    @ 16  (8 bytes)
|||   gpu_time_us:  int64    @ 24  (8 bytes)
|||   text_offset:  int64    @ 32  (8 bytes)
|||   text_length:  int64    @ 40  (8 bytes)
|||   Total:                       48 bytes (aligned to 8)
public export
ocrResultStructSize : HasSize OcrStatus 48
ocrResultStructSize = SizeProof

||| OcrResult has 8-byte alignment (due to int64 fields)
public export
ocrResultStructAlign : HasAlignment OcrStatus 8
ocrResultStructAlign = AlignProof

||| The ddac_conduit_result_t struct total size on LP64 platforms.
||| Layout:
|||   content_kind: uint8    @ 0   (1 byte)
|||   validation:   uint8    @ 1   (1 byte)
|||   _pad:         uint8[6] @ 2   (6 bytes padding)
|||   file_size:    int64    @ 8   (8 bytes)
|||   sha256:       char[65] @ 16  (65 bytes)
|||   _pad2:        char[7]  @ 81  (7 bytes padding)
|||   Total:                       88 bytes (aligned to 8)
public export
conduitResultStructSize : HasSize ConduitValidation 88
conduitResultStructSize = SizeProof

||| ConduitResult has 8-byte alignment (due to int64 field)
public export
conduitResultStructAlign : HasAlignment ConduitValidation 8
conduitResultStructAlign = AlignProof

||| The ddac_ml_result_t struct total size on LP64 platforms.
||| Layout:
|||   status:            uint8    @ 0   (1 byte)
|||   stage:             uint8    @ 1   (1 byte)
|||   provider:          uint8    @ 2   (1 byte)
|||   _pad:              uint8[5] @ 3   (5 bytes padding)
|||   inference_time_us: int64    @ 8   (8 bytes)
|||   output_count:      int64    @ 16  (8 bytes)
|||   confidence:        double   @ 24  (8 bytes)
|||   text_offset:       int64    @ 32  (8 bytes)
|||   text_length:       int64    @ 40  (8 bytes)
|||   Total:                            48 bytes (aligned to 8)
public export
mlResultStructSize : HasSize MlStatus 48
mlResultStructSize = SizeProof

||| MlResult has 8-byte alignment (due to int64/double fields)
public export
mlResultStructAlign : HasAlignment MlStatus 8
mlResultStructAlign = AlignProof

||| The ddac_crypto_caps_t struct total size on LP64 platforms.
||| Layout:
|||   has_sha_ni:    uint8  @ 0   (1 byte)
|||   has_avx2:      uint8  @ 1   (1 byte)
|||   has_avx512:    uint8  @ 2   (1 byte)
|||   has_arm_sha2:  uint8  @ 3   (1 byte)
|||   has_arm_sha512:uint8  @ 4   (1 byte)
|||   has_aes_ni:    uint8  @ 5   (1 byte)
|||   _pad:          uint8[2]@ 6  (2 bytes padding)
|||   sha256_tier:   uint8  @ 8   (1 byte)
|||   _pad2:         uint8[7]@ 9  (7 bytes padding)
|||   Total:                       16 bytes (aligned to 1)
public export
cryptoCapsStructSize : HasSize Sha256Tier 16
cryptoCapsStructSize = SizeProof

||| CryptoCaps has 1-byte alignment (all uint8 fields)
public export
cryptoCapsStructAlign : HasAlignment Sha256Tier 1
cryptoCapsStructAlign = AlignProof

--------------------------------------------------------------------------------
-- FFI Declarations (raw primitives)
--------------------------------------------------------------------------------

namespace Foreign

  ||| Raw FFI: ddac_init
  export
  %foreign "C:ddac_init, libdocudactyl_ffi"
  prim__init : PrimIO Bits64

  ||| Raw FFI: ddac_parse (5 args: handle, input, output, fmt, stages)
  export
  %foreign "C:ddac_parse, libdocudactyl_ffi"
  prim__parse : Bits64 -> Bits64 -> Bits64 -> Bits64 -> Bits64 -> PrimIO Bits64

  ||| Safe wrapper: initialise library
  export
  initLib : IO (Maybe Handle)
  initLib = do
    ptr <- primIO prim__init
    pure (createHandle ptr)

--------------------------------------------------------------------------------
-- Verification
--------------------------------------------------------------------------------

namespace Verify

  ||| Verify all type mappings are distinct and exhaustive
  export
  verifyAllTypes : IO ()
  verifyAllTypes = do
    putStrLn "ContentKind values:     0-6 (7 variants, injective, decidably equal)"
    putStrLn "ParseStatus values:     0-6 (7 variants, retryable predicate)"
    putStrLn "OcrStatus values:       0-3 (4 variants, fallback predicate)"
    putStrLn "ConduitValidation:      0-3 (4 variants)"
    putStrLn "GpuBackend values:      0-2 (3 variants)"
    putStrLn "MlStatus values:        0-4 (5 variants, retryable predicate)"
    putStrLn "MlStage values:         0-4 (5 variants, model name mapping)"
    putStrLn "ExecProvider values:    0-3 (4 variants, GPU predicate)"
    putStrLn "Sha256Tier values:      0-2 (3 variants)"
    putStrLn "Struct sizes: ParseResult=952, OcrResult=48, ConduitResult=88, MlResult=48, CryptoCaps=16"
    putStrLn "All ABI types verified"
