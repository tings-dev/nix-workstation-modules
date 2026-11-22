# Shared desktop file associations.
{ lib, ... }:

let
  # The image formats both viewers below claim. Kept to the intersection on
  # purpose: a type only one of them handles has no meaningful fallback, and
  # the mimeapps entry would then lie about the second choice.
  imageTypes = [
    "image/avif"
    "image/bmp"
    "image/gif"
    "image/jpeg"
    "image/jxl"
    "image/png"
    "image/svg+xml"
    "image/tiff"
    "image/webp"
    "image/x-exr"
    "image/x-portable-anymap"
    "image/x-portable-bitmap"
    "image/x-portable-graymap"
    "image/x-portable-pixmap"
    "image/x-tga"
  ];

  # MIME types advertised by Papers' org.gnome.Papers.desktop entry.
  documentTypes = [
    "application/vnd.comicbook-rar"
    "application/vnd.comicbook+zip"
    "application/x-cb7"
    "application/x-cbr"
    "application/x-cbt"
    "application/x-cbz"
    "application/x-ext-cb7"
    "application/x-ext-cbr"
    "application/x-ext-cbt"
    "application/x-ext-cbz"
    "application/x-ext-djv"
    "application/x-ext-djvu"
    "image/vnd.djvu"
    "image/vnd.djvu+multipage"
    "application/pdf"
    "application/x-bzpdf"
    "application/x-ext-pdf"
    "application/x-gzpdf"
    "application/x-xzpdf"
    "application/illustrator"
    "image/tiff"
  ];

  # Office documents and templates, grouped by the component that opens them.
  # These are MIME types rather than extensions: shared-mime-info resolves
  # .docx, .xlsx, .odt, etc. before the desktop looks up the default handler.
  officeTypes = {
    writer = [
      "application/msword"
      "application/vnd.ms-word"
      "application/vnd.ms-word.document.macroEnabled.12"
      "application/vnd.ms-word.template.macroEnabled.12"
      "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
      "application/vnd.openxmlformats-officedocument.wordprocessingml.template"
      "application/vnd.oasis.opendocument.text"
      "application/vnd.oasis.opendocument.text-template"
      "application/vnd.oasis.opendocument.text-flat-xml"
      "application/vnd.oasis.opendocument.text-master"
      "application/vnd.oasis.opendocument.text-master-template"
      "application/vnd.oasis.opendocument.text-web"
      "application/vnd.sun.xml.writer"
      "application/vnd.sun.xml.writer.template"
      "application/vnd.sun.xml.writer.global"
      "application/vnd.apple.pages"
      "application/x-iwork-pages-sffpages"
      "application/rtf"
      "text/rtf"
    ];
    calc = [
      "application/vnd.ms-excel"
      "application/vnd.ms-excel.sheet.binary.macroEnabled.12"
      "application/vnd.ms-excel.sheet.macroEnabled.12"
      "application/vnd.ms-excel.template.macroEnabled.12"
      "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
      "application/vnd.openxmlformats-officedocument.spreadsheetml.template"
      "application/vnd.oasis.opendocument.spreadsheet"
      "application/vnd.oasis.opendocument.spreadsheet-template"
      "application/vnd.oasis.opendocument.spreadsheet-flat-xml"
      "application/vnd.sun.xml.calc"
      "application/vnd.sun.xml.calc.template"
      "application/vnd.apple.numbers"
      "application/x-iwork-numbers-sffnumbers"
      "application/csv"
      "text/csv"
      "text/comma-separated-values"
      "text/tab-separated-values"
    ];
    impress = [
      "application/vnd.ms-powerpoint"
      "application/vnd.ms-powerpoint.presentation.macroEnabled.12"
      "application/vnd.ms-powerpoint.slideshow.macroEnabled.12"
      "application/vnd.ms-powerpoint.template.macroEnabled.12"
      "application/vnd.openxmlformats-officedocument.presentationml.presentation"
      "application/vnd.openxmlformats-officedocument.presentationml.slide"
      "application/vnd.openxmlformats-officedocument.presentationml.slideshow"
      "application/vnd.openxmlformats-officedocument.presentationml.template"
      "application/vnd.oasis.opendocument.presentation"
      "application/vnd.oasis.opendocument.presentation-template"
      "application/vnd.oasis.opendocument.presentation-flat-xml"
      "application/vnd.sun.xml.impress"
      "application/vnd.sun.xml.impress.template"
      "application/vnd.apple.keynote"
      "application/x-iwork-keynote-sffkey"
    ];
    draw = [
      "application/vnd.oasis.opendocument.graphics"
      "application/vnd.oasis.opendocument.graphics-template"
      "application/vnd.oasis.opendocument.graphics-flat-xml"
      "application/vnd.sun.xml.draw"
      "application/vnd.sun.xml.draw.template"
      "application/vnd.visio"
    ];
    base = [
      "application/vnd.oasis.opendocument.database"
      "application/vnd.sun.xml.base"
    ];
    math = [
      "application/vnd.oasis.opendocument.formula"
      "application/vnd.sun.xml.math"
      "application/mathml+xml"
    ];
  };
in
{
  # For images, Loupe is the default handler and swayimg the declared second
  # choice, which is what puts it in every "Open with" menu. Papers overrides
  # TIFF below because it also handles multipage documents.
  xdg.mimeApps = {
    enable = true;
    defaultApplications =
      builtins.listToAttrs (
        map (type: {
          name = type;
          value = [
            "org.gnome.Loupe.desktop"
            "swayimg.desktop"
          ];
        }) imageTypes
      )
      // builtins.listToAttrs (
        map (type: {
          name = type;
          value = "org.gnome.Papers.desktop";
        }) documentTypes
      )
      // lib.concatMapAttrs (
        component: types:
        builtins.listToAttrs (
          map (type: {
            name = type;
            value = "libreoffice-${component}.desktop";
          }) types
        )
      ) officeTypes
      // {
        # Open web links and HTML documents in Firefox on graphical seats.
        "x-scheme-handler/http" = "firefox.desktop";
        "x-scheme-handler/https" = "firefox.desktop";
        "text/html" = "firefox.desktop";
        "application/xhtml+xml" = "firefox.desktop";

        # What "open the containing folder" resolves to, for every application
        # that asks the desktop rather than guessing.
        "inode/directory" = "org.gnome.Nautilus.desktop";
      };
  };
}
