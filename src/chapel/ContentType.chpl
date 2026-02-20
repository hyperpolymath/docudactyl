// Docudactyl HPC — Content Type Detection
//
// Detects document/media format from file extension.
// Maps to ContentKind enum in the Zig FFI layer.
//
// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <jonathan.jewell@open.ac.uk>

module ContentType {

  /** Content kinds supported by the HPC pipeline.
      Integer values must match Zig's ContentKind enum. */
  enum ContentKind : int {
    PDF        = 0,
    Image      = 1,
    Audio      = 2,
    Video      = 3,
    EPUB       = 4,
    GeoSpatial = 5,
    Unknown    = 6
  }

  /** Return a human-readable label for a content kind. */
  proc contentKindName(kind: ContentKind): string {
    select kind {
      when ContentKind.PDF        do return "PDF";
      when ContentKind.Image      do return "Image";
      when ContentKind.Audio      do return "Audio";
      when ContentKind.Video      do return "Video";
      when ContentKind.EPUB       do return "EPUB";
      when ContentKind.GeoSpatial do return "GeoSpatial";
      otherwise                   do return "Unknown";
    }
  }

  /** Detect content type from file path extension.
      Case-insensitive matching on the final extension. */
  proc detectContentType(path: string): ContentKind {
    // Find last dot
    var dotPos = -1;
    for i in 0..#path.size by -1 {
      if path[i] == "." {
        dotPos = i;
        break;
      }
    }

    if dotPos < 0 then return ContentKind.Unknown;

    const ext = path[dotPos..].toLower();

    // PDF
    if ext == ".pdf" then return ContentKind.PDF;

    // Images (OCR-capable)
    if ext == ".jpg" || ext == ".jpeg" then return ContentKind.Image;
    if ext == ".png"  then return ContentKind.Image;
    if ext == ".tiff" || ext == ".tif" then return ContentKind.Image;
    if ext == ".bmp"  then return ContentKind.Image;
    if ext == ".webp" then return ContentKind.Image;

    // Audio
    if ext == ".mp3"  then return ContentKind.Audio;
    if ext == ".wav"  then return ContentKind.Audio;
    if ext == ".flac" then return ContentKind.Audio;
    if ext == ".ogg"  then return ContentKind.Audio;
    if ext == ".aac"  then return ContentKind.Audio;
    if ext == ".m4a"  then return ContentKind.Audio;

    // Video
    if ext == ".mp4"  then return ContentKind.Video;
    if ext == ".mkv"  then return ContentKind.Video;
    if ext == ".avi"  then return ContentKind.Video;
    if ext == ".webm" then return ContentKind.Video;
    if ext == ".mov"  then return ContentKind.Video;

    // EPUB
    if ext == ".epub" then return ContentKind.EPUB;

    // Geospatial
    if ext == ".shp"     then return ContentKind.GeoSpatial;
    if ext == ".geotiff" then return ContentKind.GeoSpatial;
    if ext == ".gpkg"    then return ContentKind.GeoSpatial;
    if ext == ".kml"     then return ContentKind.GeoSpatial;

    return ContentKind.Unknown;
  }

  /** Check if a content kind is text-producing (has word/char counts). */
  proc isTextProducing(kind: ContentKind): bool {
    select kind {
      when ContentKind.PDF, ContentKind.Image, ContentKind.EPUB do return true;
      otherwise do return false;
    }
  }

  /** Check if a content kind has temporal duration. */
  proc hasDuration(kind: ContentKind): bool {
    return kind == ContentKind.Audio || kind == ContentKind.Video;
  }
}
