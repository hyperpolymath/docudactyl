-- SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <jonathan.jewell@open.ac.uk>
-- SPDX-License-Identifier: PMPL-1.0-or-later

-- Docudactyl TUI: Terminal User Interface for PDF text extraction
--
-- This is the main entry point for the Ada TUI application.
-- It provides an interactive interface for viewing and analyzing
-- extracted PDF content.

with Ada.Text_IO;              use Ada.Text_IO;
with Ada.Command_Line;         use Ada.Command_Line;
with Ada.Strings.Unbounded;    use Ada.Strings.Unbounded;
with Ada.Exceptions;           use Ada.Exceptions;

with Terminal_Utils;           use Terminal_Utils;
with Document_Model;           use Document_Model;

procedure Docudactyl_TUI is

   -- Application version
   Version : constant String := "0.4.0";

   -- Current state
   type View_Mode is (List_View, Document_View, Search_View, Help_View);

   type App_State is record
      Mode            : View_Mode := List_View;
      Current_Page    : Positive := 1;
      Scroll_Offset   : Natural := 0;
      Document        : PDF_Document;
      Document_Loaded : Boolean := False;
      Search_Query    : Unbounded_String;
      Search_Results  : Document_Model.Result_Vectors.Vector;
      Status_Message  : Unbounded_String;
      Running         : Boolean := True;
   end record;

   State : App_State;
   Term  : Dimensions;

   -- Display the header bar
   procedure Draw_Header is
      Title : constant String := "Docudactyl TUI v" & Version;
   begin
      Set_Attribute (Reverse);
      Move_Cursor (1, 1);
      Put ((1 .. Term.Columns => ' '));
      Print_At (1, 2, Title);

      if State.Document_Loaded then
         declare
            Filename : constant String :=
               To_String (State.Document.Filepath);
            Display_Name : constant String :=
               (if Filename'Length > 40 then
                   "..." & Filename (Filename'Last - 36 .. Filename'Last)
                else Filename);
         begin
            Print_At (1, Term.Columns - Display_Name'Length - 1, Display_Name);
         end;
      end if;

      Reset_Attributes;
   end Draw_Header;

   -- Display the footer/status bar
   procedure Draw_Footer is
      Mode_Str : constant String :=
         (case State.Mode is
            when List_View     => "[List]",
            when Document_View => "[Doc:" & Positive'Image (State.Current_Page) & "]",
            when Search_View   => "[Search]",
            when Help_View     => "[Help]");
      Help_Str : constant String := "q:Quit  ?:Help  /:Search  Enter:Open";
   begin
      Set_Attribute (Reverse);
      Move_Cursor (Term.Rows, 1);
      Put ((1 .. Term.Columns => ' '));
      Print_At (Term.Rows, 2, Mode_Str);
      Print_At (Term.Rows, Term.Columns - Help_Str'Length - 1, Help_Str);
      Reset_Attributes;

      -- Status message line
      if Length (State.Status_Message) > 0 then
         Move_Cursor (Term.Rows - 1, 1);
         Put ((1 .. Term.Columns => ' '));
         Set_Foreground (Yellow);
         Print_At (Term.Rows - 1, 2, To_String (State.Status_Message));
         Reset_Attributes;
      end if;
   end Draw_Footer;

   -- Display help screen
   procedure Draw_Help is
      Row : Positive := 3;

      procedure Help_Line (Key, Desc : String) is
      begin
         Set_Foreground (Cyan);
         Print_At (Row, 4, Key);
         Reset_Attributes;
         Print_At (Row, 20, Desc);
         Row := Row + 1;
      end Help_Line;
   begin
      Draw_Box (2, 2, Term.Rows - 3, Term.Columns - 2, "Help");

      Help_Line ("q, Esc",       "Quit application");
      Help_Line ("?",            "Show this help");
      Help_Line ("/",            "Search in document");
      Help_Line ("Enter",        "Open/select item");
      Help_Line ("j, Down",      "Move down / Next line");
      Help_Line ("k, Up",        "Move up / Previous line");
      Help_Line ("n, PgDn",      "Next page");
      Help_Line ("p, PgUp",      "Previous page");
      Help_Line ("g",            "Go to first page");
      Help_Line ("G",            "Go to last page");
      Help_Line ("Tab",          "Switch view mode");
      Help_Line ("a",            "Show analysis");

      Row := Row + 2;
      Set_Foreground (Bright_White);
      Print_At (Row, 4, "Docudactyl - PDF Text Extraction Tool");
      Reset_Attributes;
      Row := Row + 1;
      Print_At (Row, 4, "Julia processing | OCaml transformation | Ada TUI");
   end Draw_Help;

   -- Display document list (placeholder for multi-document support)
   procedure Draw_List is
   begin
      Draw_Box (2, 2, Term.Rows - 3, Term.Columns - 2, "Documents");

      if State.Document_Loaded then
         Print_At (4, 4, "> " & To_String (State.Document.Filepath));

         declare
            Analysis : constant Analysis_Result := Analyze (State.Document);
         begin
            Print_At (6, 6, "Pages:" & Natural'Image (Analysis.Total_Pages));
            Print_At (7, 6, "Words:" & Natural'Image (Analysis.Total_Words));
            Print_At (8, 6, "Characters:" & Natural'Image (Analysis.Total_Characters));
         end;
      else
         Set_Foreground (Bright_Black);
         Print_At (4, 4, "No document loaded.");
         Print_At (6, 4, "Usage: docudactyl-tui <document.json>");
         Reset_Attributes;
      end if;
   end Draw_List;

   -- Display document content
   procedure Draw_Document is
      Content_Height : constant Positive := Term.Rows - 4;
      Start_Line     : constant Positive := State.Scroll_Offset + 1;
   begin
      Draw_Box (2, 2, Term.Rows - 3, Term.Columns - 2,
                "Page" & Positive'Image (State.Current_Page));

      if State.Document_Loaded and then
         State.Current_Page <= Positive (State.Document.Pages.Length)
      then
         declare
            Page : constant Page_Content :=
               State.Document.Pages (State.Current_Page);
            Row : Positive := 4;
         begin
            for I in Page.Lines.First_Index .. Page.Lines.Last_Index loop
               exit when Row > Term.Rows - 3;

               if I >= Start_Line then
                  declare
                     Line_Text : constant String := To_String (Page.Lines (I));
                     Max_Width : constant Positive := Term.Columns - 8;
                     Display   : constant String :=
                        (if Line_Text'Length > Max_Width then
                            Line_Text (Line_Text'First .. Line_Text'First + Max_Width - 4) & "..."
                         else Line_Text);
                  begin
                     Print_At (Row, 4, Display);
                     Row := Row + 1;
                  end;
               end if;
            end loop;
         end;
      else
         Set_Foreground (Bright_Black);
         Print_At (4, 4, "No content to display.");
         Reset_Attributes;
      end if;
   end Draw_Document;

   -- Display search results
   procedure Draw_Search is
      Row : Positive := 4;
   begin
      Draw_Box (2, 2, Term.Rows - 3, Term.Columns - 2,
                "Search: " & To_String (State.Search_Query));

      if State.Search_Results.Is_Empty then
         Set_Foreground (Bright_Black);
         Print_At (Row, 4, "No results found.");
         Reset_Attributes;
      else
         for Result of State.Search_Results loop
            exit when Row > Term.Rows - 4;

            Print_Colored (Row, 4, "Page" & Positive'Image (Result.Page_Number) & ":",
                          FG => Cyan);
            declare
               Context : constant String := To_String (Result.Context);
               Max_Width : constant Positive := Term.Columns - 20;
               Display : constant String :=
                  (if Context'Length > Max_Width then
                      Context (Context'First .. Context'First + Max_Width - 4) & "..."
                   else Context);
            begin
               Print_At (Row, 16, Display);
            end;
            Row := Row + 1;
         end loop;
      end if;
   end Draw_Search;

   -- Main draw routine
   procedure Draw is
   begin
      Clear_Screen;
      Draw_Header;

      case State.Mode is
         when List_View     => Draw_List;
         when Document_View => Draw_Document;
         when Search_View   => Draw_Search;
         when Help_View     => Draw_Help;
      end case;

      Draw_Footer;
   end Draw;

   -- Handle keyboard input
   procedure Handle_Input is
      Key : constant Character := Read_Key;
   begin
      State.Status_Message := Null_Unbounded_String;

      case Key is
         when 'q' | ASCII.ESC =>
            State.Running := False;

         when '?' =>
            State.Mode := Help_View;

         when '/' =>
            State.Mode := Search_View;
            -- TODO: Implement search input

         when ASCII.HT =>  -- Tab
            State.Mode :=
               (case State.Mode is
                  when List_View     => Document_View,
                  when Document_View => Search_View,
                  when Search_View   => Help_View,
                  when Help_View     => List_View);

         when 'j' | ASCII.LF =>  -- Down
            if State.Mode = Document_View then
               State.Scroll_Offset := State.Scroll_Offset + 1;
            end if;

         when 'k' =>  -- Up
            if State.Mode = Document_View and State.Scroll_Offset > 0 then
               State.Scroll_Offset := State.Scroll_Offset - 1;
            end if;

         when 'n' =>  -- Next page
            if State.Document_Loaded and then
               State.Current_Page < Positive (State.Document.Pages.Length)
            then
               State.Current_Page := State.Current_Page + 1;
               State.Scroll_Offset := 0;
            end if;

         when 'p' =>  -- Previous page
            if State.Current_Page > 1 then
               State.Current_Page := State.Current_Page - 1;
               State.Scroll_Offset := 0;
            end if;

         when 'g' =>  -- First page
            State.Current_Page := 1;
            State.Scroll_Offset := 0;

         when 'G' =>  -- Last page
            if State.Document_Loaded then
               State.Current_Page := Positive (State.Document.Pages.Length);
               State.Scroll_Offset := 0;
            end if;

         when 'a' =>  -- Analysis
            if State.Document_Loaded then
               declare
                  A : constant Analysis_Result := Analyze (State.Document);
               begin
                  State.Status_Message := To_Unbounded_String (
                     "Pages:" & Natural'Image (A.Total_Pages) &
                     " Words:" & Natural'Image (A.Total_Words) &
                     " Chars:" & Natural'Image (A.Total_Characters));
               end;
            end if;

         when others =>
            null;
      end case;
   end Handle_Input;

   -- Print usage information
   procedure Print_Usage is
   begin
      Put_Line ("Docudactyl TUI v" & Version);
      Put_Line ("PDF text extraction and analysis terminal interface");
      Put_Line ("");
      Put_Line ("Usage: docudactyl-tui [OPTIONS] [FILE]");
      Put_Line ("");
      Put_Line ("Options:");
      Put_Line ("  -h, --help     Show this help message");
      Put_Line ("  -v, --version  Show version information");
      Put_Line ("");
      Put_Line ("FILE can be a JSON file from Julia extraction");
   end Print_Usage;

begin
   -- Parse command line
   if Argument_Count > 0 then
      declare
         Arg : constant String := Argument (1);
      begin
         if Arg = "-h" or Arg = "--help" then
            Print_Usage;
            return;
         elsif Arg = "-v" or Arg = "--version" then
            Put_Line ("Docudactyl TUI v" & Version);
            return;
         else
            -- Try to load document
            State.Document := Load_From_JSON (Arg);
            State.Document_Loaded := True;
         end if;
      end;
   end if;

   -- Initialize terminal
   Initialize;
   Term := Get_Dimensions;

   -- Main loop
   while State.Running loop
      Draw;
      Handle_Input;
   end loop;

   -- Cleanup
   Finalize;

exception
   when E : others =>
      Finalize;
      Put_Line ("Error: " & Exception_Message (E));
end Docudactyl_TUI;
