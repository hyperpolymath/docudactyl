-- SPDX-FileCopyrightText: 2025 Hyperpolymath
-- SPDX-License-Identifier: PMPL-1.0-or-later

with Ada.Text_IO;              use Ada.Text_IO;
with Ada.Integer_Text_IO;      use Ada.Integer_Text_IO;
with Ada.Characters.Latin_1;   use Ada.Characters.Latin_1;
with Ada.Environment_Variables;

package body Terminal_Utils is

   -- ANSI escape sequence prefix
   ESC : constant Character := Ada.Characters.Latin_1.ESC;
   CSI : constant String := ESC & "[";

   -- Saved terminal state
   Original_Initialized : Boolean := False;

   -- Color to ANSI code mapping
   function FG_Code (C : Color) return Natural is
   begin
      case C is
         when Default        => return 39;
         when Black          => return 30;
         when Red            => return 31;
         when Green          => return 32;
         when Yellow         => return 33;
         when Blue           => return 34;
         when Magenta        => return 35;
         when Cyan           => return 36;
         when White          => return 37;
         when Bright_Black   => return 90;
         when Bright_Red     => return 91;
         when Bright_Green   => return 92;
         when Bright_Yellow  => return 93;
         when Bright_Blue    => return 94;
         when Bright_Magenta => return 95;
         when Bright_Cyan    => return 96;
         when Bright_White   => return 97;
      end case;
   end FG_Code;

   function BG_Code (C : Color) return Natural is
   begin
      case C is
         when Default        => return 49;
         when Black          => return 40;
         when Red            => return 41;
         when Green          => return 42;
         when Yellow         => return 43;
         when Blue           => return 44;
         when Magenta        => return 45;
         when Cyan           => return 46;
         when White          => return 47;
         when Bright_Black   => return 100;
         when Bright_Red     => return 101;
         when Bright_Green   => return 102;
         when Bright_Yellow  => return 103;
         when Bright_Blue    => return 104;
         when Bright_Magenta => return 105;
         when Bright_Cyan    => return 106;
         when Bright_White   => return 107;
      end case;
   end BG_Code;

   procedure Initialize is
   begin
      if not Original_Initialized then
         -- Enter alternate screen buffer
         Put (CSI & "?1049h");
         -- Enable mouse tracking (optional)
         -- Put (CSI & "?1000h");
         Hide_Cursor;
         Clear_Screen;
         Original_Initialized := True;
      end if;
   end Initialize;

   procedure Finalize is
   begin
      if Original_Initialized then
         Show_Cursor;
         Reset_Attributes;
         -- Exit alternate screen buffer
         Put (CSI & "?1049l");
         Original_Initialized := False;
      end if;
   end Finalize;

   function Get_Dimensions return Dimensions is
      Result : Dimensions;
      Lines_Str : constant String :=
        Ada.Environment_Variables.Value ("LINES", "24");
      Cols_Str : constant String :=
        Ada.Environment_Variables.Value ("COLUMNS", "80");
   begin
      Result.Rows := Positive'Value (Lines_Str);
      Result.Columns := Positive'Value (Cols_Str);
      return Result;
   exception
      when others =>
         return (Rows => 24, Columns => 80);
   end Get_Dimensions;

   procedure Clear_Screen is
   begin
      Put (CSI & "2J");
      Move_Cursor (1, 1);
   end Clear_Screen;

   procedure Move_Cursor (Row, Column : Positive) is
      Row_Str : constant String := Positive'Image (Row);
      Col_Str : constant String := Positive'Image (Column);
   begin
      Put (CSI & Row_Str (2 .. Row_Str'Last) & ";" &
           Col_Str (2 .. Col_Str'Last) & "H");
   end Move_Cursor;

   procedure Hide_Cursor is
   begin
      Put (CSI & "?25l");
   end Hide_Cursor;

   procedure Show_Cursor is
   begin
      Put (CSI & "?25h");
   end Show_Cursor;

   procedure Set_Foreground (C : Color) is
      Code : constant Natural := FG_Code (C);
      Code_Str : constant String := Natural'Image (Code);
   begin
      Put (CSI & Code_Str (2 .. Code_Str'Last) & "m");
   end Set_Foreground;

   procedure Set_Background (C : Color) is
      Code : constant Natural := BG_Code (C);
      Code_Str : constant String := Natural'Image (Code);
   begin
      Put (CSI & Code_Str (2 .. Code_Str'Last) & "m");
   end Set_Background;

   procedure Set_Attribute (A : Attribute) is
      Code : Natural;
   begin
      case A is
         when Normal    => Code := 0;
         when Bold      => Code := 1;
         when Dim       => Code := 2;
         when Italic    => Code := 3;
         when Underline => Code := 4;
         when Blink     => Code := 5;
         when Reverse   => Code := 7;
      end case;
      declare
         Code_Str : constant String := Natural'Image (Code);
      begin
         Put (CSI & Code_Str (2 .. Code_Str'Last) & "m");
      end;
   end Set_Attribute;

   procedure Reset_Attributes is
   begin
      Put (CSI & "0m");
   end Reset_Attributes;

   procedure Print_At (Row, Column : Positive; Text : String) is
   begin
      Move_Cursor (Row, Column);
      Put (Text);
   end Print_At;

   procedure Print_Colored
     (Row, Column : Positive;
      Text        : String;
      FG          : Color := Default;
      BG          : Color := Default;
      Attr        : Attribute := Normal)
   is
   begin
      Move_Cursor (Row, Column);
      Set_Attribute (Attr);
      Set_Foreground (FG);
      Set_Background (BG);
      Put (Text);
      Reset_Attributes;
   end Print_Colored;

   procedure Draw_Horizontal_Line
     (Row       : Positive;
      Start_Col : Positive;
      End_Col   : Positive;
      Char      : Character := '-')
   is
   begin
      Move_Cursor (Row, Start_Col);
      for I in Start_Col .. End_Col loop
         Put (Char);
      end loop;
   end Draw_Horizontal_Line;

   procedure Draw_Vertical_Line
     (Column    : Positive;
      Start_Row : Positive;
      End_Row   : Positive;
      Char      : Character := '|')
   is
   begin
      for R in Start_Row .. End_Row loop
         Print_At (R, Column, (1 => Char));
      end loop;
   end Draw_Vertical_Line;

   procedure Draw_Box
     (Top_Row  : Positive;
      Left_Col : Positive;
      Height   : Positive;
      Width    : Positive;
      Title    : String := "")
   is
      Bottom_Row : constant Positive := Top_Row + Height - 1;
      Right_Col  : constant Positive := Left_Col + Width - 1;
   begin
      -- Corners
      Print_At (Top_Row, Left_Col, "+");
      Print_At (Top_Row, Right_Col, "+");
      Print_At (Bottom_Row, Left_Col, "+");
      Print_At (Bottom_Row, Right_Col, "+");

      -- Horizontal lines
      Draw_Horizontal_Line (Top_Row, Left_Col + 1, Right_Col - 1, '-');
      Draw_Horizontal_Line (Bottom_Row, Left_Col + 1, Right_Col - 1, '-');

      -- Vertical lines
      Draw_Vertical_Line (Left_Col, Top_Row + 1, Bottom_Row - 1, '|');
      Draw_Vertical_Line (Right_Col, Top_Row + 1, Bottom_Row - 1, '|');

      -- Title
      if Title'Length > 0 and then Title'Length < Width - 4 then
         Print_At (Top_Row, Left_Col + 2, "[ " & Title & " ]");
      end if;
   end Draw_Box;

   function Read_Key return Character is
      C : Character;
   begin
      Get_Immediate (C);
      return C;
   end Read_Key;

   function Key_Available return Boolean is
   begin
      -- Simple implementation - actual would use select/poll
      return True;
   end Key_Available;

   procedure Bell is
   begin
      Put (Ada.Characters.Latin_1.BEL);
   end Bell;

end Terminal_Utils;
