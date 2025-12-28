-- SPDX-FileCopyrightText: 2025 Hyperpolymath
-- SPDX-License-Identifier: AGPL-3.0-or-later OR LicenseRef-Palimpsest-0.5

-- Terminal_Utils: ANSI terminal control utilities for TUI
--
-- Provides cross-platform terminal manipulation using ANSI escape codes.

with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;

package Terminal_Utils is

   -- Terminal dimensions
   type Dimensions is record
      Rows    : Positive := 24;
      Columns : Positive := 80;
   end record;

   -- Color definitions
   type Color is
     (Default, Black, Red, Green, Yellow, Blue, Magenta, Cyan, White,
      Bright_Black, Bright_Red, Bright_Green, Bright_Yellow,
      Bright_Blue, Bright_Magenta, Bright_Cyan, Bright_White);

   -- Text attributes
   type Attribute is (Normal, Bold, Dim, Italic, Underline, Blink, Reverse);

   -- Initialize terminal for TUI mode
   procedure Initialize;

   -- Restore terminal to normal mode
   procedure Finalize;

   -- Get terminal dimensions
   function Get_Dimensions return Dimensions;

   -- Clear screen
   procedure Clear_Screen;

   -- Move cursor to position (1-indexed)
   procedure Move_Cursor (Row, Column : Positive);

   -- Hide/show cursor
   procedure Hide_Cursor;
   procedure Show_Cursor;

   -- Set foreground color
   procedure Set_Foreground (C : Color);

   -- Set background color
   procedure Set_Background (C : Color);

   -- Set text attribute
   procedure Set_Attribute (A : Attribute);

   -- Reset all attributes
   procedure Reset_Attributes;

   -- Print text at position
   procedure Print_At
     (Row, Column : Positive;
      Text        : String);

   -- Print text with colors
   procedure Print_Colored
     (Row, Column : Positive;
      Text        : String;
      FG          : Color := Default;
      BG          : Color := Default;
      Attr        : Attribute := Normal);

   -- Draw a horizontal line
   procedure Draw_Horizontal_Line
     (Row         : Positive;
      Start_Col   : Positive;
      End_Col     : Positive;
      Char        : Character := '-');

   -- Draw a vertical line
   procedure Draw_Vertical_Line
     (Column      : Positive;
      Start_Row   : Positive;
      End_Row     : Positive;
      Char        : Character := '|');

   -- Draw a box
   procedure Draw_Box
     (Top_Row     : Positive;
      Left_Col    : Positive;
      Height      : Positive;
      Width       : Positive;
      Title       : String := "");

   -- Read a single key (blocking)
   function Read_Key return Character;

   -- Check if key is available
   function Key_Available return Boolean;

   -- Ring the terminal bell
   procedure Bell;

end Terminal_Utils;
