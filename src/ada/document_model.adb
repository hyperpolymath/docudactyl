-- SPDX-FileCopyrightText: 2025 Hyperpolymath
-- SPDX-License-Identifier: PMPL-1.0-or-later

with Ada.Text_IO;              use Ada.Text_IO;
with Ada.Strings.Fixed;        use Ada.Strings.Fixed;
with Ada.Strings.Maps;         use Ada.Strings.Maps;
with Ada.Characters.Handling;  use Ada.Characters.Handling;

package body Document_Model is

   -- Simple JSON parsing (minimal implementation)
   -- For production, use a proper JSON library

   function Load_From_JSON (Filepath : String) return PDF_Document is
      Doc  : PDF_Document;
      File : File_Type;
   begin
      Doc.Filepath := To_Unbounded_String (Filepath);
      Doc.SHA256 := To_Unbounded_String ("");
      Doc.Extracted_At := To_Unbounded_String ("");

      -- Note: This is a placeholder. Real implementation would
      -- parse JSON using a library like GNATCOLL.JSON
      -- For now, we create an empty document structure

      return Doc;
   exception
      when others =>
         return Doc;
   end Load_From_JSON;

   function Get_Page_Text (Page : Page_Content) return String is
      Result : Unbounded_String;
   begin
      if not Page.Lines.Is_Empty then
         for I in Page.Lines.First_Index .. Page.Lines.Last_Index loop
            if I > Page.Lines.First_Index then
               Append (Result, ASCII.LF);
            end if;
            Append (Result, Page.Lines (I));
         end loop;
      else
         for I in Page.Blocks.First_Index .. Page.Blocks.Last_Index loop
            if I > Page.Blocks.First_Index then
               Append (Result, " ");
            end if;
            Append (Result, Page.Blocks (I).Text);
         end loop;
      end if;
      return To_String (Result);
   end Get_Page_Text;

   function Get_Document_Text (Doc : PDF_Document) return String is
      Result : Unbounded_String;
   begin
      for I in Doc.Pages.First_Index .. Doc.Pages.Last_Index loop
         if I > Doc.Pages.First_Index then
            Append (Result, ASCII.LF & ASCII.LF);
         end if;
         Append (Result, Get_Page_Text (Doc.Pages (I)));
      end loop;
      return To_String (Result);
   end Get_Document_Text;

   function Count_Words (Text : String) return Natural is
      Count    : Natural := 0;
      In_Word  : Boolean := False;
      Whitespace : constant Character_Set := To_Set (" " & ASCII.HT & ASCII.LF & ASCII.CR);
   begin
      for C of Text loop
         if Is_In (C, Whitespace) then
            In_Word := False;
         elsif not In_Word then
            In_Word := True;
            Count := Count + 1;
         end if;
      end loop;
      return Count;
   end Count_Words;

   function Analyze (Doc : PDF_Document) return Analysis_Result is
      Result : Analysis_Result;
      Total_Text : constant String := Get_Document_Text (Doc);
   begin
      Result.Total_Pages := Natural (Doc.Pages.Length);
      Result.Total_Words := Count_Words (Total_Text);
      Result.Total_Characters := Total_Text'Length;
      Result.Unique_Words := 0;  -- Would need a proper set implementation

      if Result.Total_Pages > 0 then
         Result.Avg_Words_Per_Page := Float (Result.Total_Words) /
                                      Float (Result.Total_Pages);
      else
         Result.Avg_Words_Per_Page := 0.0;
      end if;

      Result.Estimated_Redacted := 0.0;  -- Placeholder

      return Result;
   end Analyze;

   function Search (Doc : PDF_Document; Pattern : String)
      return Result_Vectors.Vector
   is
      Results : Result_Vectors.Vector;
      Lower_Pattern : constant String := To_Lower (Pattern);
   begin
      for P of Doc.Pages loop
         for L in P.Lines.First_Index .. P.Lines.Last_Index loop
            declare
               Line_Text : constant String := To_String (P.Lines (L));
               Lower_Line : constant String := To_Lower (Line_Text);
               Pos : constant Natural := Index (Lower_Line, Lower_Pattern);
            begin
               if Pos > 0 then
                  Results.Append ((
                     Page_Number => P.Page_Number,
                     Line_Number => L,
                     Context     => P.Lines (L)
                  ));
               end if;
            end;
         end loop;
      end loop;
      return Results;
   end Search;

end Document_Model;
