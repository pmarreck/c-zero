//! Root of the c0-codec-jpeg plugin library: exports the jpeg codec through the c0_plugin.h ABI.
const plugin = @import("c0_plugin");
const codec = @import("c0_codec");

comptime {
    plugin.exportPlugin(codec.exif.JpegCodec);
}
