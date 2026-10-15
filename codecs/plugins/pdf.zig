//! Root of the c0-codec-pdf plugin library: exports the pdf codec through the c0_plugin.h ABI.
const plugin = @import("c0_plugin");
const codec = @import("c0_codec");

comptime {
    plugin.exportPlugin(codec.pdf.PdfCodec);
}
