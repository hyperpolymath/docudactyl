(* SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <jonathan.jewell@open.ac.uk> *)
(* SPDX-License-Identifier: PMPL-1.0-or-later *)

(** Docudactyl-scm: PDF to Scheme transformer.

    This tool transforms PDF documents into machine-readable Scheme
    (S-expression) format for processing by Lisp systems.

    Usage:
      docudactyl-scm [OPTIONS] INPUT

    Input can be:
      - A PDF file (.pdf)
      - A JSON file from Julia extraction (.json)

    Output is Scheme code with the document structure and accessor functions.
*)

open Cmdliner

let version = "0.4.0"

(** Process a single input file *)
let process_file input_path output_path minimal verbose =
  try
    if verbose then
      Printf.eprintf "Processing: %s\n%!" input_path;

    (* Determine input type and parse *)
    let doc =
      if Filename.check_suffix input_path ".json" then begin
        if verbose then Printf.eprintf "Reading JSON input...\n%!";
        Pdf_parser.parse_json input_path
      end else begin
        if verbose then Printf.eprintf "Reading PDF input...\n%!";
        Pdf_parser.parse_pdf input_path
      end
    in

    if verbose then
      Printf.eprintf "Parsed %d pages, %d words\n%!"
        (List.length doc.pages)
        (Document_types.document_word_count doc);

    (* Generate output *)
    let output =
      if minimal then
        Scheme_emit.emit_minimal doc
      else
        Scheme_emit.emit_document doc
    in

    (* Write output *)
    begin match output_path with
    | Some path ->
      let oc = open_out path in
      output_string oc output;
      close_out oc;
      if verbose then Printf.eprintf "Output: %s\n%!" path
    | None ->
      print_string output
    end;

    `Ok ()
  with
  | Sys_error msg ->
    `Error (false, Printf.sprintf "File error: %s" msg)
  | Yojson.Json_error msg ->
    `Error (false, Printf.sprintf "JSON parse error: %s" msg)
  | e ->
    `Error (false, Printf.sprintf "Error: %s" (Printexc.to_string e))

(** Command-line argument definitions *)

let input_arg =
  let doc = "Input PDF or JSON file to transform." in
  Arg.(required & pos 0 (some file) None & info [] ~docv:"INPUT" ~doc)

let output_arg =
  let doc = "Output file path. If not specified, writes to stdout." in
  Arg.(value & opt (some string) None & info ["o"; "output"] ~docv:"FILE" ~doc)

let minimal_arg =
  let doc = "Output minimal S-expression (data only, no helper functions)." in
  Arg.(value & flag & info ["m"; "minimal"] ~doc)

let verbose_arg =
  let doc = "Enable verbose output to stderr." in
  Arg.(value & flag & info ["v"; "verbose"] ~doc)

(** Main command *)
let cmd =
  let doc = "Transform PDF documents to Scheme (S-expression) format" in
  let man = [
    `S Manpage.s_description;
    `P "docudactyl-scm transforms PDF documents into machine-readable \
        Scheme (S-expression) format. It can read PDFs directly or \
        process JSON output from the Julia extraction tool.";
    `P "The output includes the document structure with metadata, \
        page content, text blocks with positioning, and helper \
        functions for accessing the data in Scheme.";

    `S Manpage.s_examples;
    `P "Transform a PDF to Scheme:";
    `Pre "  docudactyl-scm document.pdf -o document.scm";
    `P "Transform JSON from Julia extraction:";
    `Pre "  docudactyl-scm extracted.json -o extracted.scm";
    `P "Output minimal format to stdout:";
    `Pre "  docudactyl-scm --minimal document.pdf";

    `S Manpage.s_bugs;
    `P "Report bugs at https://github.com/hyperpolymath/docudactyl/issues";

    `S Manpage.s_authors;
    `P "Jonathan D.A. Jewell <jonathan.jewell@open.ac.uk>";
  ] in
  let info = Cmd.info "docudactyl-scm" ~version ~doc ~man in
  Cmd.v info Term.(ret (const process_file $ input_arg $ output_arg $ minimal_arg $ verbose_arg))

(** Entry point *)
let () = exit (Cmd.eval cmd)
