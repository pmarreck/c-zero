//! Root of the c0-codec-png plugin library: exports the png codec through the c0_plugin.h ABI.
const plugin = @import("c0_plugin");
const codec = @import("c0_codec");

comptime {
    plugin.exportPlugin(codec.png.PngCodec);
}
