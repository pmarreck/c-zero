//! Root of the c0-codec-bg3 plugin library: exports the bg3 codec through the c0_plugin.h ABI.
const plugin = @import("c0_plugin");
const codec = @import("c0_codec");

comptime {
    plugin.exportPlugin(codec.bg3.Bg3Codec);
}
