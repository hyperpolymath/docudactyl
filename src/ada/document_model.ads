-- SPDX-FileCopyrightText: 2025 Hyperpolymath
-- SPDX-License-Identifier: AGPL-3.0-or-later OR LicenseRef-Palimpsest-0.5

-- Document_Model: Data structures for PDF document representation
--
-- Mirrors the Julia/OCaml document structure for display in TUI.

with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Containers.Vectors;

package Document_Model is

   -- Text block with positioning
   type Text_Block is record
      Text      : Unbounded_String;
      X0        : Float;
      Y0        : Float;
      X1        : Float;
      Y1        : Float;
      Font_Size : Float;
   end record;

   package Block_Vectors is new Ada.Containers.Vectors
     (Index_Type   => Positive,
      Element_Type => Text_Block);

   -- Lines of text
   package Line_Vectors is new Ada.Containers.Vectors
     (Index_Type   => Positive,
      Element_Type => Unbounded_String);

   -- Page content
   type Page_Content is record
      Page_Number : Positive;
      Width       : Float;
      Height      : Float;
      Blocks      : Block_Vectors.Vector;
      Lines       : Line_Vectors.Vector;
   end record;

   package Page_Vectors is new Ada.Containers.Vectors
     (Index_Type   => Positive,
      Element_Type => Page_Content);

   -- Document metadata
   type PDF_Metadata is record
      Title    : Unbounded_String;
      Author   : Unbounded_String;
      Subject  : Unbounded_String;
      Keywords : Unbounded_String;
      Creator  : Unbounded_String;
      Producer : Unbounded_String;
   end record;

   -- Complete document
   type PDF_Document is record
      Filepath     : Unbounded_String;
      SHA256       : Unbounded_String;
      Metadata     : PDF_Metadata;
      Pages        : Page_Vectors.Vector;
      Extracted_At : Unbounded_String;
   end record;

   -- Analysis results
   type Analysis_Result is record
      Total_Pages           : Natural;
      Total_Words           : Natural;
      Total_Characters      : Natural;
      Unique_Words          : Natural;
      Avg_Words_Per_Page    : Float;
      Estimated_Redacted    : Float;
   end record;

   -- Document loading from JSON
   function Load_From_JSON (Filepath : String) return PDF_Document;

   -- Get page text
   function Get_Page_Text (Page : Page_Content) return String;

   -- Get document text
   function Get_Document_Text (Doc : PDF_Document) return String;

   -- Count words
   function Count_Words (Text : String) return Natural;

   -- Analyze document
   function Analyze (Doc : PDF_Document) return Analysis_Result;

   -- Search in document
   type Search_Result is record
      Page_Number : Positive;
      Line_Number : Positive;
      Context     : Unbounded_String;
   end record;

   package Result_Vectors is new Ada.Containers.Vectors
     (Index_Type   => Positive,
      Element_Type => Search_Result);

   function Search (Doc : PDF_Document; Pattern : String)
      return Result_Vectors.Vector;

end Document_Model;
