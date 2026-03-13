(* SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <jonathan.jewell@open.ac.uk> *)
(* SPDX-License-Identifier: PMPL-1.0-or-later *)

(** PDF parsing using CamlPDF library. *)

open Document_types

(** Compute SHA-256 hash of a file *)
let compute_sha256 filepath =
  let ic = open_in_bin filepath in
  let len = in_channel_length ic in
  let content = really_input_string ic len in
  close_in ic;
  Digest.string content |> Digest.to_hex

(** Extract metadata from PDF *)
let extract_metadata pdf =
  try
    let info = Pdf.lookup_direct pdf "/Info" pdf.Pdf.trailerdict in
    match info with
    | Some (Pdf.Dictionary dict) ->
      let get_string key =
        match List.assoc_opt key dict with
        | Some (Pdf.String s) -> Some s
        | _ -> None
      in
      {
        title = get_string "/Title";
        author = get_string "/Author";
        subject = get_string "/Subject";
        keywords = get_string "/Keywords";
        creator = get_string "/Creator";
        producer = get_string "/Producer";
      }
    | _ -> empty_metadata
  with _ -> empty_metadata

(** Get page dimensions from media box *)
let get_page_dimensions pdf pagenum =
  try
    let page = Pdfpage.page_of_pagenumber pdf pagenum in
    match page.Pdfpage.mediabox with
    | Pdf.Array [Pdf.Real x0; Pdf.Real y0; Pdf.Real x1; Pdf.Real y1]
    | Pdf.Array [Pdf.Integer x0; Pdf.Integer y0; Pdf.Integer x1; Pdf.Integer y1] ->
      let x0, y0, x1, y1 =
        float_of_int x0, float_of_int y0, float_of_int x1, float_of_int y1
      in
      make_dimensions (x1 -. x0) (y1 -. y0)
    | Pdf.Array [Pdf.Real x0; Pdf.Real y0; Pdf.Real x1; Pdf.Real y1] ->
      make_dimensions (x1 -. x0) (y1 -. y0)
    | _ -> make_dimensions 612.0 792.0
  with _ -> make_dimensions 612.0 792.0

(** Extract text content from a page *)
let extract_page_text pdf pagenum =
  try
    let page = Pdfpage.page_of_pagenumber pdf pagenum in
    let text = Pdftotext.extract_page_text pdf page in
    text
  with _ -> ""

(** Parse text into blocks (simplified - positions are estimated) *)
let parse_text_to_blocks text pagenum =
  let lines = String.split_on_char '\n' text in
  let y_pos = ref 72.0 in
  List.filter_map (fun line ->
    let trimmed = String.trim line in
    if String.length trimmed > 0 then begin
      let block = make_text_block
        trimmed
        72.0 !y_pos
        (72.0 +. float_of_int (String.length trimmed) *. 6.0)
        (!y_pos +. 12.0)
        12.0
      in
      y_pos := !y_pos +. 14.0;
      Some block
    end else
      None
  ) lines

(** Extract content from a single page *)
let extract_page pdf pagenum =
  let dimensions = get_page_dimensions pdf pagenum in
  let text = extract_page_text pdf pagenum in
  let lines = String.split_on_char '\n' text
              |> List.map String.trim
              |> List.filter (fun s -> String.length s > 0) in
  let blocks = parse_text_to_blocks text pagenum in
  {
    page_number = pagenum;
    dimensions;
    blocks;
    lines;
  }

(** Parse a PDF file into a document structure *)
let parse_pdf filepath =
  let sha256 = compute_sha256 filepath in
  let pdf = Pdfread.pdf_of_file None None filepath in
  let metadata = extract_metadata pdf in
  let num_pages = Pdfpage.endpage pdf in

  let pages = List.init num_pages (fun i ->
    extract_page pdf (i + 1)
  ) in

  let now = Unix.gettimeofday () in
  let tm = Unix.gmtime now in
  let extracted_at = Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
    (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1) tm.Unix.tm_mday
    tm.Unix.tm_hour tm.Unix.tm_min tm.Unix.tm_sec
  in

  {
    filepath;
    sha256;
    metadata;
    pages;
    extracted_at;
  }

(** Parse from JSON (Julia output) *)
let parse_json filepath =
  let json = Yojson.Safe.from_file filepath in
  let open Yojson.Safe.Util in

  let metadata_json = json |> member "metadata" in
  let pdf_meta = metadata_json |> member "pdf_metadata" in

  let get_opt_string json key =
    try Some (json |> member key |> to_string)
    with _ -> None
  in

  let metadata = {
    title = get_opt_string pdf_meta "Title";
    author = get_opt_string pdf_meta "Author";
    subject = get_opt_string pdf_meta "Subject";
    keywords = get_opt_string pdf_meta "Keywords";
    creator = get_opt_string pdf_meta "Creator";
    producer = get_opt_string pdf_meta "Producer";
  } in

  let pages_json = json |> member "pages" |> to_list in
  let pages = List.map (fun page_json ->
    let page_number = page_json |> member "page_number" |> to_int in
    let width = page_json |> member "width" |> to_float in
    let height = page_json |> member "height" |> to_float in
    let lines = page_json |> member "lines" |> to_list |> List.map to_string in
    let blocks_json = page_json |> member "blocks" |> to_list in

    let blocks = List.map (fun block_json ->
      let text = block_json |> member "text" |> to_string in
      let x0 = block_json |> member "x0" |> to_float in
      let y0 = block_json |> member "y0" |> to_float in
      let x1 = block_json |> member "x1" |> to_float in
      let y1 = block_json |> member "y1" |> to_float in
      let font_size = block_json |> member "font_size" |> to_float in
      make_text_block text x0 y0 x1 y1 font_size
    ) blocks_json in

    {
      page_number;
      dimensions = make_dimensions width height;
      blocks;
      lines;
    }
  ) pages_json in

  {
    filepath = metadata_json |> member "filepath" |> to_string;
    sha256 = metadata_json |> member "sha256" |> to_string;
    metadata;
    pages;
    extracted_at = metadata_json |> member "extracted_at" |> to_string;
  }
