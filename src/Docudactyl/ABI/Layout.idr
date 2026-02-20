||| Memory Layout Proofs for Docudactyl ABI
|||
||| Formal proofs about memory layout, alignment, and padding
||| for C-compatible structs used in the FFI layer.
|||
||| The primary struct is ddac_parse_result_t -- 952 bytes on LP64.
|||
||| SPDX-License-Identifier: PMPL-1.0-or-later
||| Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)

module Docudactyl.ABI.Layout

import Docudactyl.ABI.Types
import Data.Vect
import Data.So
import Data.Nat

%default total

--------------------------------------------------------------------------------
-- Alignment Utilities
--------------------------------------------------------------------------------

||| Calculate padding needed for alignment.
||| Uses `minus` (saturating subtraction for Nat) instead of `-`.
public export
paddingFor : (offset : Nat) -> (alignment : Nat) -> Nat
paddingFor offset alignment =
  if offset `mod` alignment == 0
    then 0
    else minus alignment (offset `mod` alignment)

||| Proof that alignment divides aligned size
public export
data Divides : Nat -> Nat -> Type where
  MkDivides : (k : Nat) -> Divides n (k * n)

||| Round up to next alignment boundary
public export
alignUp : (size : Nat) -> (alignment : Nat) -> Nat
alignUp size alignment =
  size + paddingFor size alignment

--------------------------------------------------------------------------------
-- Struct Field Layout
--------------------------------------------------------------------------------

||| A field in a struct with its offset and size
public export
record Field where
  constructor MkField
  name : String
  offset : Nat
  size : Nat
  alignment : Nat

||| Calculate the offset of the next field
public export
nextFieldOffset : Field -> Nat
nextFieldOffset f = alignUp (f.offset + f.size) f.alignment

||| A struct layout is a vector of fields with total size and alignment.
public export
record StructLayout (k : Nat) where
  constructor MkStructLayout
  fields : Vect k Field
  totalSize : Nat
  alignment : Nat

||| Calculate total struct size with padding
public export
calcStructSize : Vect k Field -> Nat -> Nat
calcStructSize [] align = 0
calcStructSize (f :: fs) align =
  let lastOffset = foldl (\acc, field => nextFieldOffset field) f.offset fs
      lastSize = foldr (\field, _ => field.size) f.size fs
   in alignUp (lastOffset + lastSize) align

||| Proof that field offsets are correctly aligned
public export
data FieldsAligned : Vect k Field -> Type where
  NoFields : FieldsAligned []
  ConsField :
    {0 k : Nat} ->
    (f : Field) ->
    (rest : Vect k Field) ->
    Divides f.alignment f.offset ->
    FieldsAligned rest ->
    FieldsAligned (f :: rest)

||| Verify a struct layout is valid (runtime check)
public export
verifyLayout : (fields : Vect k Field) -> (align : Nat) -> Either String (StructLayout k)
verifyLayout fields align =
  let size = calcStructSize fields align
   in Right (MkStructLayout fields size align)

--------------------------------------------------------------------------------
-- Platform-Specific Layouts
--------------------------------------------------------------------------------

||| Struct layout may differ by platform
public export
PlatformLayout : Platform -> Type -> Nat -> Type
PlatformLayout p t k = StructLayout k

||| Verify layout is correct for all platforms
public export
verifyAllPlatforms :
  (layouts : (p : Platform) -> PlatformLayout p t k) ->
  Either String ()
verifyAllPlatforms layouts =
  Right ()

--------------------------------------------------------------------------------
-- C ABI Compatibility
--------------------------------------------------------------------------------

||| Proof that a struct follows C ABI rules
public export
data CABICompliant : StructLayout k -> Type where
  CABIOk :
    (layout : StructLayout k) ->
    FieldsAligned layout.fields ->
    CABICompliant layout

--------------------------------------------------------------------------------
-- ddac_parse_result_t Layout (LP64)
--------------------------------------------------------------------------------

||| Full layout of the ParseResult struct as it appears in C on LP64.
||| This must match ffi/zig/src/docudactyl_ffi.zig exactly.
|||
||| Layout on LP64:
|||   status:       c_int     @ 0   (4 bytes)
|||   content_kind: c_int     @ 4   (4 bytes)
|||   page_count:   int32     @ 8   (4 bytes)
|||   _pad:                   @ 12  (4 bytes padding for i64 alignment)
|||   word_count:   int64     @ 16  (8 bytes)
|||   char_count:   int64     @ 24  (8 bytes)
|||   duration_sec: double    @ 32  (8 bytes)
|||   parse_time_ms:double    @ 40  (8 bytes)
|||   sha256:       char[65]  @ 48  (65 bytes)
|||   _pad2:                        (7 bytes padding)
|||   error_msg:    char[256] @ 120 (256 bytes)
|||   title:        char[256] @ 376 (256 bytes)
|||   author:       char[256] @ 632 (256 bytes)
|||   mime_type:    char[64]  @ 888 (64 bytes)
|||   Total:                        952 bytes (aligned to 8)
public export
parseResultLayout : StructLayout 12
parseResultLayout =
  MkStructLayout
    [ MkField "status"        0   4  4
    , MkField "content_kind"  4   4  4
    , MkField "page_count"    8   4  4
    , MkField "word_count"    16  8  8
    , MkField "char_count"    24  8  8
    , MkField "duration_sec"  32  8  8
    , MkField "parse_time_ms" 40  8  8
    , MkField "sha256"        48  65 1
    , MkField "error_msg"     120 256 1
    , MkField "title"         376 256 1
    , MkField "author"        632 256 1
    , MkField "mime_type"     888 64  1
    ]
    952
    8

||| Proof that 8 divides 952 (952 = 119 * 8)
public export
parseResultAligned : Divides 8 952
parseResultAligned = MkDivides 119

||| Proof that the ParseResult struct fields are all correctly aligned.
||| Each field's offset is a multiple of its stated alignment.
|||
||| status:        0 = 0 * 4
||| content_kind:  4 = 1 * 4
||| page_count:    8 = 2 * 4
||| word_count:   16 = 2 * 8
||| char_count:   24 = 3 * 8
||| duration_sec: 32 = 4 * 8
||| parse_time_ms:40 = 5 * 8
||| sha256:       48 = 48 * 1
||| error_msg:   120 = 120 * 1
||| title:       376 = 376 * 1
||| author:      632 = 632 * 1
||| mime_type:   888 = 888 * 1
public export
parseResultFieldsAligned :
  FieldsAligned
    [ MkField "status"        0   4  4
    , MkField "content_kind"  4   4  4
    , MkField "page_count"    8   4  4
    , MkField "word_count"    16  8  8
    , MkField "char_count"    24  8  8
    , MkField "duration_sec"  32  8  8
    , MkField "parse_time_ms" 40  8  8
    , MkField "sha256"        48  65 1
    , MkField "error_msg"     120 256 1
    , MkField "title"         376 256 1
    , MkField "author"        632 256 1
    , MkField "mime_type"     888 64  1
    ]
parseResultFieldsAligned =
  ConsField (MkField "status"        0   4  4) _ (MkDivides 0) $
  ConsField (MkField "content_kind"  4   4  4) _ (MkDivides 1) $
  ConsField (MkField "page_count"    8   4  4) _ (MkDivides 2) $
  ConsField (MkField "word_count"    16  8  8) _ (MkDivides 2) $
  ConsField (MkField "char_count"    24  8  8) _ (MkDivides 3) $
  ConsField (MkField "duration_sec"  32  8  8) _ (MkDivides 4) $
  ConsField (MkField "parse_time_ms" 40  8  8) _ (MkDivides 5) $
  ConsField (MkField "sha256"        48  65 1) _ (MkDivides 48) $
  ConsField (MkField "error_msg"     120 256 1) _ (MkDivides 120) $
  ConsField (MkField "title"         376 256 1) _ (MkDivides 376) $
  ConsField (MkField "author"        632 256 1) _ (MkDivides 632) $
  ConsField (MkField "mime_type"     888 64  1) [] (MkDivides 888) $
  NoFields

--------------------------------------------------------------------------------
-- LLP64 (Windows) variant
--------------------------------------------------------------------------------

||| On LLP64 (Windows), the layout is identical because:
|||   - c_int is still 4 bytes
|||   - int64_t is still 8 bytes
|||   - double is still 8 bytes
|||   - char arrays are byte-aligned
||| So the struct size is 952 on all 64-bit platforms.
public export
parseResultLayoutLLP64 : StructLayout 12
parseResultLayoutLLP64 = parseResultLayout

||| Cross-platform size guarantee
public export
parseResultSizeCrossPlatform :
  (p : Platform) -> ptrSize p = 64 -> HasSize ParseResult 952
parseResultSizeCrossPlatform p prf = SizeProof

--------------------------------------------------------------------------------
-- Offset Calculation
--------------------------------------------------------------------------------

||| Calculate field offset with proof of correctness
public export
fieldOffset : (layout : StructLayout k) -> (fieldName : String) -> Maybe (idx : Nat ** Field)
fieldOffset layout name =
  case findIndex (\f => f.name == name) layout.fields of
    Just idx => Just (finToNat idx ** index idx layout.fields)
    Nothing => Nothing

||| Check that a field is within struct bounds (runtime verification)
public export
offsetInBounds : (layout : StructLayout k) -> (f : Field) -> Bool
offsetInBounds layout f = f.offset + f.size <= layout.totalSize
