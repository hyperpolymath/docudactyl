(* SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <jonathan.jewell@open.ac.uk> *)
(* SPDX-License-Identifier: PMPL-1.0-or-later *)

(** Document type definitions for PDF to Scheme transformation. *)

(** Bounding box for text positioning *)
type bounds = {
  x0 : float;
  y0 : float;
  x1 : float;
  y1 : float;
}

(** A single text block with position *)
type text_block = {
  text : string;
  bounds : bounds;
  font_size : float;
}

(** Page dimensions *)
type page_dimensions = {
  width : float;
  height : float;
}

(** Content from a single PDF page *)
type page_content = {
  page_number : int;
  dimensions : page_dimensions;
  blocks : text_block list;
  lines : string list;
}

(** PDF document metadata *)
type pdf_metadata = {
  title : string option;
  author : string option;
  subject : string option;
  keywords : string option;
  creator : string option;
  producer : string option;
}

(** Complete PDF document representation *)
type pdf_document = {
  filepath : string;
  sha256 : string;
  metadata : pdf_metadata;
  pages : page_content list;
  extracted_at : string;
}

(** Empty metadata *)
let empty_metadata = {
  title = None;
  author = None;
  subject = None;
  keywords = None;
  creator = None;
  producer = None;
}

(** Create bounds from coordinates *)
let make_bounds x0 y0 x1 y1 = { x0; y0; x1; y1 }

(** Create a text block *)
let make_text_block text x0 y0 x1 y1 font_size = {
  text;
  bounds = make_bounds x0 y0 x1 y1;
  font_size;
}

(** Create page dimensions *)
let make_dimensions width height = { width; height }

(** Create an empty page *)
let empty_page num = {
  page_number = num;
  dimensions = make_dimensions 612.0 792.0;
  blocks = [];
  lines = [];
}

(** Calculate block area *)
let block_area block =
  let b = block.bounds in
  abs_float (b.x1 -. b.x0) *. abs_float (b.y1 -. b.y0)

(** Calculate page area *)
let page_area page =
  page.dimensions.width *. page.dimensions.height

(** Get all text from a page *)
let page_text page =
  if page.lines <> [] then
    String.concat "\n" page.lines
  else
    String.concat " " (List.map (fun b -> b.text) page.blocks)

(** Get all text from a document *)
let document_text doc =
  String.concat "\n\n" (List.map page_text doc.pages)

(** Count words in text *)
let word_count text =
  let words = String.split_on_char ' ' text in
  List.length (List.filter (fun s -> String.length s > 0) words)

(** Total words in document *)
let document_word_count doc =
  List.fold_left (fun acc page ->
    acc + word_count (page_text page)
  ) 0 doc.pages
