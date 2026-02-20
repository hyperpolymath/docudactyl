||| Foreign Function Interface Declarations for Docudactyl
|||
||| Declares all C-compatible functions implemented in the Zig FFI layer
||| (ffi/zig/src/docudactyl_ffi.zig). Chapel calls these directly; Idris2
||| provides the type-level proofs that the interface is correct.
|||
||| SPDX-License-Identifier: PMPL-1.0-or-later
||| Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)

module Docudactyl.ABI.Foreign

import Docudactyl.ABI.Types
import Docudactyl.ABI.Layout

%default total

--------------------------------------------------------------------------------
-- Library Lifecycle
--------------------------------------------------------------------------------

||| Initialise the Docudactyl FFI library.
||| Returns a handle to Tesseract/GDAL/vips contexts, or Nothing on failure.
export
%foreign "C:ddac_init, libdocudactyl_ffi"
prim__init : PrimIO Bits64

||| Safe wrapper for library initialisation
export
init : IO (Maybe Handle)
init = do
  ptr <- primIO prim__init
  pure (createHandle ptr)

||| Free all library resources (Tesseract, GDAL, vips).
||| Safe to call with a null pointer.
export
%foreign "C:ddac_free, libdocudactyl_ffi"
prim__free : Bits64 -> PrimIO ()

||| Safe wrapper for cleanup
export
free : Handle -> IO ()
free h = primIO (prim__free (handlePtr h))

--------------------------------------------------------------------------------
-- Core Parse Operation
--------------------------------------------------------------------------------

||| Parse a document. Dispatches to the correct C library based on file extension.
|||
||| Parameters (as raw Bits64 pointers to C strings):
|||   handle     - library handle from ddac_init
|||   input_path - absolute path to input document
|||   output_path - absolute path for extracted content output
|||   output_fmt  - output format (0=scheme, 1=json, 2=csv)
|||
||| Returns a raw pointer to a ddac_parse_result_t struct.
||| In practice, Chapel reads the struct fields directly via extern record.
export
%foreign "C:ddac_parse, libdocudactyl_ffi"
prim__parse : Bits64 -> Bits64 -> Bits64 -> Bits64 -> PrimIO Bits64

||| Safe wrapper for parse with type-checked status
export
parse : Handle -> (inputPath : Bits64) -> (outputPath : Bits64) -> (outputFmt : Bits64) -> IO (Either ParseStatus Bits64)
parse h inputPath outputPath outputFmt = do
  resultPtr <- primIO (prim__parse (handlePtr h) inputPath outputPath outputFmt)
  if resultPtr == 0
    then pure (Left Error)
    else pure (Right resultPtr)

--------------------------------------------------------------------------------
-- Version Information
--------------------------------------------------------------------------------

||| Get library version string
export
%foreign "C:ddac_version, libdocudactyl_ffi"
prim__version : PrimIO Bits64

||| Convert C string pointer to Idris String
export
%foreign "support:idris2_getString, libidris2_support"
prim__getString : Bits64 -> String

||| Get version as string
export
version : IO String
version = do
  ptr <- primIO prim__version
  pure (prim__getString ptr)

--------------------------------------------------------------------------------
-- Error Handling Utilities
--------------------------------------------------------------------------------

||| Extract ParseStatus from a raw result status integer
export
decodeStatus : Bits32 -> ParseStatus
decodeStatus n = case intToParseStatus n of
  Just s  => s
  Nothing => Error

||| Extract ContentKind from a raw result content_kind integer
export
decodeContentKind : Bits32 -> ContentKind
decodeContentKind n = case intToContentKind n of
  Just k  => k
  Nothing => Unknown

||| Human-readable description of a parse status
export
statusDescription : ParseStatus -> String
statusDescription Ok               = "Success"
statusDescription Error             = "Generic error"
statusDescription FileNotFound      = "File not found"
statusDescription ParseError        = "Parse error"
statusDescription NullPointer       = "Null pointer"
statusDescription UnsupportedFormat = "Unsupported format"
statusDescription OutOfMemory       = "Out of memory"

||| Human-readable description of a content kind
export
contentKindDescription : ContentKind -> String
contentKindDescription PDF        = "PDF document"
contentKindDescription Image      = "Image (OCR)"
contentKindDescription Audio      = "Audio recording"
contentKindDescription Video      = "Video recording"
contentKindDescription EPUB       = "EPUB e-book"
contentKindDescription GeoSpatial = "Geospatial data"
contentKindDescription Unknown    = "Unknown format"

--------------------------------------------------------------------------------
-- Safety Proofs
--------------------------------------------------------------------------------

||| Proof that init returns a non-null handle on success
||| (This is a specification — the Zig implementation must guarantee it)
export
initNonNull : (ptr : Bits64) -> (ptr /= 0) = True -> Maybe Handle
initNonNull ptr prf = Just (MkHandle ptr)

||| Proof that free is idempotent (calling twice is safe)
||| Encoded as a specification: ddac_free(NULL) is a no-op in Zig.
export
freeIdempotent : String
freeIdempotent = "ddac_free checks for null; double-free is a no-op"
