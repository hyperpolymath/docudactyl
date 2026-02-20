;; SPDX-License-Identifier: PMPL-1.0-or-later
;; Docudactyl HPC — Guix development environment
;;
;; Usage:
;;   guix shell -D -f guix.scm    # Enter dev shell with all dependencies
;;   guix build -f guix.scm       # Build (placeholder — real build uses just)
;;
;; This defines the development environment for building Docudactyl HPC.
;; The actual build is driven by the Justfile (just build-hpc).
;;
;; Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <jonathan.jewell@open.ac.uk>

(use-modules (guix packages)
             (guix build-system gnu)
             (guix licenses)
             (gnu packages)
             (gnu packages gcc)
             (gnu packages pkg-config)
             (gnu packages glib)
             (gnu packages pdf)
             (gnu packages ocr)
             (gnu packages image)
             (gnu packages video)
             (gnu packages xml)
             (gnu packages geo)
             (gnu packages image-processing))

(package
  (name "docudactyl")
  (version "0.3.0")
  (source #f)
  (build-system gnu-build-system)
  (synopsis "Multi-format HPC document extraction engine")
  (description
    "Docudactyl is a distributed document processing engine targeting
British Library scale (~170M items).  Chapel orchestrates across HPC
cluster nodes, dispatching to C libraries via a zero-cost Zig FFI layer.
Supports PDF, images (OCR), audio, video, EPUB, and geospatial formats.")
  (home-page "https://github.com/hyperpolymath/docudactyl")
  (license #f)  ; PMPL-1.0-or-later (not in Guix license list)

  ;; Development inputs — these are the C libraries linked by the Zig FFI.
  ;; Chapel and Zig are not yet packaged in Guix; install via asdf.
  (native-inputs
    (list pkg-config gcc-toolchain))
  (inputs
    (list
      ;; PDF extraction
      poppler                   ; poppler-glib
      glib                      ; glib-2.0, gobject-2.0

      ;; OCR
      tesseract-ocr             ; libtesseract
      leptonica                 ; liblept

      ;; Audio/Video
      ffmpeg                    ; libavformat, libavcodec, libavutil

      ;; EPUB/XHTML
      libxml2                   ; libxml-2.0

      ;; Geospatial
      gdal                      ; libgdal

      ;; Image metadata
      vips)))                   ; libvips
