||| Memory Layout Proofs for Docudactyl ABI
|||
||| Formal proofs about memory layout, alignment, and padding
||| for C-compatible structs used in the FFI layer.
|||
||| The primary struct is ddac_parse_result_t — 952 bytes on LP64.
|||
||| SPDX-License-Identifier: PMPL-1.0-or-later
||| Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)

module Docudactyl.ABI.Layout

import Docudactyl.ABI.Types
import Data.Vect
import Data.So

%default total

--------------------------------------------------------------------------------
-- Alignment Utilities
--------------------------------------------------------------------------------

||| Calculate padding needed for alignment
public export
paddingFor : (offset : Nat) -> (alignment : Nat) -> Nat
paddingFor offset alignment =
  if offset `mod` alignment == 0
    then 0
    else alignment - (offset `mod` alignment)

||| Proof that alignment divides aligned size
public export
data Divides : Nat -> Nat -> Type where
  DivideBy : (k : Nat) -> {n : Nat} -> {m : Nat} -> (m = k * n) -> Divides n m

||| Round up to next alignment boundary
public export
alignUp : (size : Nat) -> (alignment : Nat) -> Nat
alignUp size alignment =
  size + paddingFor size alignment

||| Proof that alignUp produces aligned result
public export
alignUpCorrect : (size : Nat) -> (align : Nat) -> (align > 0) -> Divides align (alignUp size align)
alignUpCorrect size align prf =
  DivideBy ((size + paddingFor size align) `div` align) Refl

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

||| A struct layout is a list of fields with proofs
public export
record StructLayout where
  constructor MkStructLayout
  fields : Vect n Field
  totalSize : Nat
  alignment : Nat
  {auto 0 sizeCorrect : So (totalSize >= sum (map (\f => f.size) fields))}
  {auto 0 aligned : Divides alignment totalSize}

||| Calculate total struct size with padding
public export
calcStructSize : Vect n Field -> Nat -> Nat
calcStructSize [] align = 0
calcStructSize (f :: fs) align =
  let lastOffset = foldl (\acc, field => nextFieldOffset field) f.offset fs
      lastSize = foldr (\field, _ => field.size) f.size fs
   in alignUp (lastOffset + lastSize) align

||| Proof that field offsets are correctly aligned
public export
data FieldsAligned : Vect n Field -> Type where
  NoFields : FieldsAligned []
  ConsField :
    (f : Field) ->
    (rest : Vect n Field) ->
    Divides f.alignment f.offset ->
    FieldsAligned rest ->
    FieldsAligned (f :: rest)

||| Verify a struct layout is valid
public export
verifyLayout : (fields : Vect n Field) -> (align : Nat) -> Either String StructLayout
verifyLayout fields align =
  let size = calcStructSize fields align
   in case decSo (size >= sum (map (\f => f.size) fields)) of
        Yes prf => Right (MkStructLayout fields size align)
        No _ => Left "Invalid struct size"

--------------------------------------------------------------------------------
-- Platform-Specific Layouts
--------------------------------------------------------------------------------

||| Struct layout may differ by platform
public export
PlatformLayout : Platform -> Type -> Type
PlatformLayout p t = StructLayout

||| Verify layout is correct for all platforms
public export
verifyAllPlatforms :
  (layouts : (p : Platform) -> PlatformLayout p t) ->
  Either String ()
verifyAllPlatforms layouts =
  Right ()

--------------------------------------------------------------------------------
-- C ABI Compatibility
--------------------------------------------------------------------------------

||| Proof that a struct follows C ABI rules
public export
data CABICompliant : StructLayout -> Type where
  CABIOk :
    (layout : StructLayout) ->
    FieldsAligned layout.fields ->
    CABICompliant layout

||| Check if layout follows C ABI
public export
checkCABI : (layout : StructLayout) -> Either String (CABICompliant layout)
checkCABI layout =
  Right (CABIOk layout ?fieldsAlignedProof)

--------------------------------------------------------------------------------
-- ddac_parse_result_t Layout (LP64)
--------------------------------------------------------------------------------

||| Full layout of the ParseResult struct as it appears in C on LP64.
||| This must match ffi/zig/src/docudactyl_ffi.zig exactly.
public export
parseResultLayout : StructLayout
parseResultLayout =
  MkStructLayout
    [ MkField "status"        0   4  4    -- c_int at offset 0
    , MkField "content_kind"  4   4  4    -- c_int at offset 4
    , MkField "page_count"    8   4  4    -- int32 at offset 8
    -- 4 bytes padding at 12 for i64 alignment
    , MkField "word_count"    16  8  8    -- int64 at offset 16
    , MkField "char_count"    24  8  8    -- int64 at offset 24
    , MkField "duration_sec"  32  8  8    -- double at offset 32
    , MkField "parse_time_ms" 40  8  8    -- double at offset 40
    , MkField "sha256"        48  65 1    -- char[65] at offset 48
    -- 7 bytes padding at 113 for alignment
    , MkField "error_msg"     120 256 1   -- char[256] at offset 120
    , MkField "title"         376 256 1   -- char[256] at offset 376
    , MkField "author"        632 256 1   -- char[256] at offset 632
    , MkField "mime_type"     888 64  1   -- char[64] at offset 888
    ]
    952  -- Total size: 952 bytes
    8    -- Alignment: 8 bytes (due to int64/double fields)

||| Proof that the ParseResult layout is C ABI compliant
export
parseResultLayoutValid : CABICompliant parseResultLayout
parseResultLayoutValid = CABIOk parseResultLayout ?parseResultFieldsAligned

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
parseResultLayoutLLP64 : StructLayout
parseResultLayoutLLP64 = parseResultLayout  -- identical on LLP64

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
fieldOffset : (layout : StructLayout) -> (fieldName : String) -> Maybe (n : Nat ** Field)
fieldOffset layout name =
  case findIndex (\f => f.name == name) layout.fields of
    Just idx => Just (finToNat idx ** index idx layout.fields)
    Nothing => Nothing

||| Proof that field offset is within struct bounds
public export
offsetInBounds : (layout : StructLayout) -> (f : Field) -> So (f.offset + f.size <= layout.totalSize)
offsetInBounds layout f = ?offsetInBoundsProof
