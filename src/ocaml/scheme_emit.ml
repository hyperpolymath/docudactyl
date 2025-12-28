(* SPDX-FileCopyrightText: 2025 Hyperpolymath *)
(* SPDX-License-Identifier: AGPL-3.0-or-later OR LicenseRef-Palimpsest-0.5 *)

(** Scheme (S-expression) code emitter for PDF documents. *)

open Document_types

(** Escape string for Scheme string literals *)
let escape_string s =
  let buf = Buffer.create (String.length s) in
  String.iter (function
    | '\\' -> Buffer.add_string buf "\\\\"
    | '"' -> Buffer.add_string buf "\\\""
    | '\n' -> Buffer.add_string buf "\\n"
    | '\r' -> Buffer.add_string buf "\\r"
    | '\t' -> Buffer.add_string buf "\\t"
    | c -> Buffer.add_char buf c
  ) s;
  Buffer.contents buf

(** Emit an optional string as Scheme *)
let emit_opt_string = function
  | Some s -> Printf.sprintf "\"%s\"" (escape_string s)
  | None -> "#f"

(** Emit bounds as S-expression *)
let emit_bounds b =
  Printf.sprintf "((x0 . %.2f) (y0 . %.2f) (x1 . %.2f) (y1 . %.2f))"
    b.x0 b.y0 b.x1 b.y1

(** Emit a text block as S-expression *)
let emit_block block =
  Printf.sprintf "((text . \"%s\")\n         (bounds %s)\n         (font-size . %.1f))"
    (escape_string block.text)
    (emit_bounds block.bounds)
    block.font_size

(** Emit page dimensions *)
let emit_dimensions dim =
  Printf.sprintf "((width . %.1f) (height . %.1f))" dim.width dim.height

(** Emit a page as S-expression *)
let emit_page page =
  let blocks_str = String.concat "\n        "
    (List.map emit_block page.blocks) in
  let lines_str = String.concat "\n        "
    (List.map (fun s -> Printf.sprintf "\"%s\"" (escape_string s)) page.lines) in

  Printf.sprintf {|      ((page-number . %d)
       (dimensions %s)
       (lines
        %s)
       (blocks
        %s))|}
    page.page_number
    (emit_dimensions page.dimensions)
    lines_str
    blocks_str

(** Emit metadata as S-expression *)
let emit_metadata meta =
  Printf.sprintf {|     (title . %s)
     (author . %s)
     (subject . %s)
     (keywords . %s)
     (creator . %s)
     (producer . %s)|}
    (emit_opt_string meta.title)
    (emit_opt_string meta.author)
    (emit_opt_string meta.subject)
    (emit_opt_string meta.keywords)
    (emit_opt_string meta.creator)
    (emit_opt_string meta.producer)

(** Emit complete document as Scheme *)
let emit_document doc =
  let pages_str = String.concat "\n" (List.map emit_page doc.pages) in

  Printf.sprintf {|;; SPDX-FileCopyrightText: 2025 Hyperpolymath
;; SPDX-License-Identifier: AGPL-3.0-or-later OR LicenseRef-Palimpsest-0.5
;;
;; Docudactyl PDF extraction - Scheme representation
;; Transformed by docudactyl-scm (OCaml)
;; Source: %s
;; Extracted: %s

(define docudactyl-document
  `((metadata
     (filepath . "%s")
     (sha256 . "%s")
     (extracted-at . "%s")
     (pdf-metadata
%s))

    (statistics
     (total-pages . %d)
     (total-words . %d))

    (pages
%s)))

;; Accessor functions for the document

(define (docudactyl-get-filepath doc)
  "Get the source file path."
  (cdr (assq 'filepath (cdr (assq 'metadata doc)))))

(define (docudactyl-get-pages doc)
  "Get all pages from the document."
  (cdr (assq 'pages doc)))

(define (docudactyl-get-page doc n)
  "Get a specific page by number (1-indexed)."
  (let ((pages (docudactyl-get-pages doc)))
    (find (lambda (p) (= (cdr (assq 'page-number p)) n)) pages)))

(define (docudactyl-page-text page)
  "Get all text from a page as a single string."
  (let ((lines (cdr (assq 'lines page))))
    (string-join lines "\n")))

(define (docudactyl-document-text doc)
  "Get all text from the document."
  (string-join
    (map docudactyl-page-text (docudactyl-get-pages doc))
    "\n\n"))

(define (docudactyl-search doc pattern)
  "Search for a pattern in the document (requires SRFI-115 for regex)."
  (let ((text (docudactyl-document-text doc)))
    (regexp-match-positions pattern text)))
|}
    doc.filepath
    doc.extracted_at
    (escape_string doc.filepath)
    doc.sha256
    doc.extracted_at
    (emit_metadata doc.metadata)
    (List.length doc.pages)
    (document_word_count doc)
    pages_str

(** Emit document to file *)
let emit_to_file doc filepath =
  let oc = open_out filepath in
  output_string oc (emit_document doc);
  close_out oc

(** Emit document to stdout *)
let emit_to_stdout doc =
  print_string (emit_document doc)

(** Emit minimal S-expression (data only, no helpers) *)
let emit_minimal doc =
  let pages_str = String.concat "\n" (List.map emit_page doc.pages) in

  Printf.sprintf {|((filepath . "%s")
 (sha256 . "%s")
 (pages
%s))|}
    (escape_string doc.filepath)
    doc.sha256
    pages_str
