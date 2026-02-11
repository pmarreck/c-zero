//! EXIF Tag Database
//!
//! Provides tag name <-> ID mappings for IFD0, Exif, GPS, and Interop contexts.
//! Each tag also has a standard TIFF type for correct binary serialization.

const std = @import("std");

/// TIFF data types (IFD entry type field)
pub const TiffType = enum(u16) {
    byte = 1,
    ascii = 2,
    short = 3,
    long = 4,
    rational = 5,
    sbyte = 6,
    undefined = 7,
    sshort = 8,
    slong = 9,
    srational = 10,
    float = 11,
    double = 12,

    /// Size in bytes of a single value of this type
    pub fn size(self: TiffType) u8 {
        return switch (self) {
            .byte, .ascii, .sbyte, .undefined => 1,
            .short, .sshort => 2,
            .long, .slong, .float => 4,
            .rational, .srational, .double => 8,
        };
    }

    pub fn fromInt(val: u16) ?TiffType {
        if (val >= 1 and val <= 12) {
            return @enumFromInt(val);
        }
        return null;
    }
};

/// IFD context determines which tag table to use
pub const IfdContext = enum {
    ifd0,
    exif,
    gps,
    interop,
};

/// Tag metadata entry
pub const TagInfo = struct {
    id: u16,
    name: []const u8,
    tiff_type: TiffType,
};

// ============================================================================
// Sub-IFD pointer tags (handled specially during expand/collapse)
// ============================================================================

pub const EXIF_IFD_TAG: u16 = 0x8769;
pub const GPS_IFD_TAG: u16 = 0x8825;
pub const INTEROP_IFD_TAG: u16 = 0xA005;

pub fn isSubIfdTag(tag_id: u16) bool {
    return tag_id == EXIF_IFD_TAG or tag_id == GPS_IFD_TAG or tag_id == INTEROP_IFD_TAG;
}

pub fn subIfdContext(tag_id: u16) ?IfdContext {
    return switch (tag_id) {
        EXIF_IFD_TAG => .exif,
        GPS_IFD_TAG => .gps,
        INTEROP_IFD_TAG => .interop,
        else => null,
    };
}

pub fn subIfdTagName(tag_id: u16) ?[]const u8 {
    return switch (tag_id) {
        EXIF_IFD_TAG => "ExifIFD",
        GPS_IFD_TAG => "GPSIFD",
        INTEROP_IFD_TAG => "InteropIFD",
        else => null,
    };
}

pub fn subIfdTagId(name: []const u8) ?u16 {
    if (std.mem.eql(u8, name, "ExifIFD")) return EXIF_IFD_TAG;
    if (std.mem.eql(u8, name, "GPSIFD")) return GPS_IFD_TAG;
    if (std.mem.eql(u8, name, "InteropIFD")) return INTEROP_IFD_TAG;
    return null;
}

pub fn subIfdContextForName(name: []const u8) ?IfdContext {
    if (std.mem.eql(u8, name, "ExifIFD")) return .exif;
    if (std.mem.eql(u8, name, "GPSIFD")) return .gps;
    if (std.mem.eql(u8, name, "InteropIFD")) return .interop;
    return null;
}

// ============================================================================
// Unknown tag formatting (tag_XXXX hex format)
// ============================================================================

const hex_upper = "0123456789ABCDEF";

/// Format an unknown tag ID as "tag_XXXX" into the provided buffer.
/// Returns a slice of the buffer containing the formatted name.
pub fn formatUnknownTag(buf: *[8]u8, id: u16) []const u8 {
    buf[0] = 't';
    buf[1] = 'a';
    buf[2] = 'g';
    buf[3] = '_';
    buf[4] = hex_upper[(id >> 12) & 0xF];
    buf[5] = hex_upper[(id >> 8) & 0xF];
    buf[6] = hex_upper[(id >> 4) & 0xF];
    buf[7] = hex_upper[id & 0xF];
    return buf[0..8];
}

/// Parse a "tag_XXXX" formatted name back to a tag ID.
pub fn parseUnknownTag(name: []const u8) ?u16 {
    if (name.len == 8 and std.mem.eql(u8, name[0..4], "tag_")) {
        return std.fmt.parseInt(u16, name[4..8], 16) catch return null;
    }
    return null;
}

// ============================================================================
// Lookup functions
// ============================================================================

/// Look up a tag name by context and ID. Returns null for unknown tags.
pub fn tagName(context: IfdContext, id: u16) ?[]const u8 {
    // Check sub-IFD pointer tags (they can appear in ifd0 and exif contexts)
    if (subIfdTagName(id)) |name| return name;

    const table = getTable(context);
    for (table) |entry| {
        if (entry.id == id) return entry.name;
    }
    return null;
}

/// Look up a tag ID by context and name. Returns null for unknown names.
pub fn tagId(context: IfdContext, name: []const u8) ?u16 {
    // Check sub-IFD names
    if (subIfdTagId(name)) |id| return id;

    // Check unknown tag format
    if (parseUnknownTag(name)) |id| return id;

    const table = getTable(context);
    for (table) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry.id;
    }
    return null;
}

/// Look up the standard TIFF type for a tag. Returns null for unknown tags.
pub fn tagType(context: IfdContext, id: u16) ?TiffType {
    // Sub-IFD pointers are always LONG
    if (isSubIfdTag(id)) return .long;

    const table = getTable(context);
    for (table) |entry| {
        if (entry.id == id) return entry.tiff_type;
    }
    return null;
}

fn getTable(context: IfdContext) []const TagInfo {
    return switch (context) {
        .ifd0 => &ifd0_tags,
        .exif => &exif_tags,
        .gps => &gps_tags,
        .interop => &interop_tags,
    };
}

// ============================================================================
// IFD0 / IFD1 tags (baseline TIFF + EXIF pointers)
// ============================================================================

const ifd0_tags = [_]TagInfo{
    .{ .id = 0x0100, .name = "ImageWidth", .tiff_type = .long },
    .{ .id = 0x0101, .name = "ImageLength", .tiff_type = .long },
    .{ .id = 0x0102, .name = "BitsPerSample", .tiff_type = .short },
    .{ .id = 0x0103, .name = "Compression", .tiff_type = .short },
    .{ .id = 0x0106, .name = "PhotometricInterpretation", .tiff_type = .short },
    .{ .id = 0x010E, .name = "ImageDescription", .tiff_type = .ascii },
    .{ .id = 0x010F, .name = "Make", .tiff_type = .ascii },
    .{ .id = 0x0110, .name = "Model", .tiff_type = .ascii },
    .{ .id = 0x0111, .name = "StripOffsets", .tiff_type = .long },
    .{ .id = 0x0112, .name = "Orientation", .tiff_type = .short },
    .{ .id = 0x0115, .name = "SamplesPerPixel", .tiff_type = .short },
    .{ .id = 0x0116, .name = "RowsPerStrip", .tiff_type = .long },
    .{ .id = 0x0117, .name = "StripByteCounts", .tiff_type = .long },
    .{ .id = 0x011A, .name = "XResolution", .tiff_type = .rational },
    .{ .id = 0x011B, .name = "YResolution", .tiff_type = .rational },
    .{ .id = 0x011C, .name = "PlanarConfiguration", .tiff_type = .short },
    .{ .id = 0x0128, .name = "ResolutionUnit", .tiff_type = .short },
    .{ .id = 0x012D, .name = "TransferFunction", .tiff_type = .short },
    .{ .id = 0x0131, .name = "Software", .tiff_type = .ascii },
    .{ .id = 0x0132, .name = "DateTime", .tiff_type = .ascii },
    .{ .id = 0x013B, .name = "Artist", .tiff_type = .ascii },
    .{ .id = 0x013E, .name = "WhitePoint", .tiff_type = .rational },
    .{ .id = 0x013F, .name = "PrimaryChromaticities", .tiff_type = .rational },
    .{ .id = 0x0201, .name = "JPEGInterchangeFormat", .tiff_type = .long },
    .{ .id = 0x0202, .name = "JPEGInterchangeFormatLength", .tiff_type = .long },
    .{ .id = 0x0211, .name = "YCbCrCoefficients", .tiff_type = .rational },
    .{ .id = 0x0212, .name = "YCbCrSubSampling", .tiff_type = .short },
    .{ .id = 0x0213, .name = "YCbCrPositioning", .tiff_type = .short },
    .{ .id = 0x0214, .name = "ReferenceBlackWhite", .tiff_type = .rational },
    .{ .id = 0x8298, .name = "Copyright", .tiff_type = .ascii },
};

// ============================================================================
// Exif sub-IFD tags
// ============================================================================

const exif_tags = [_]TagInfo{
    .{ .id = 0x829A, .name = "ExposureTime", .tiff_type = .rational },
    .{ .id = 0x829D, .name = "FNumber", .tiff_type = .rational },
    .{ .id = 0x8822, .name = "ExposureProgram", .tiff_type = .short },
    .{ .id = 0x8824, .name = "SpectralSensitivity", .tiff_type = .ascii },
    .{ .id = 0x8827, .name = "ISOSpeedRatings", .tiff_type = .short },
    .{ .id = 0x8828, .name = "OECF", .tiff_type = .undefined },
    .{ .id = 0x8830, .name = "SensitivityType", .tiff_type = .short },
    .{ .id = 0x9000, .name = "ExifVersion", .tiff_type = .undefined },
    .{ .id = 0x9003, .name = "DateTimeOriginal", .tiff_type = .ascii },
    .{ .id = 0x9004, .name = "DateTimeDigitized", .tiff_type = .ascii },
    .{ .id = 0x9101, .name = "ComponentsConfiguration", .tiff_type = .undefined },
    .{ .id = 0x9102, .name = "CompressedBitsPerPixel", .tiff_type = .rational },
    .{ .id = 0x9201, .name = "ShutterSpeedValue", .tiff_type = .srational },
    .{ .id = 0x9202, .name = "ApertureValue", .tiff_type = .rational },
    .{ .id = 0x9203, .name = "BrightnessValue", .tiff_type = .srational },
    .{ .id = 0x9204, .name = "ExposureBiasValue", .tiff_type = .srational },
    .{ .id = 0x9205, .name = "MaxApertureValue", .tiff_type = .rational },
    .{ .id = 0x9206, .name = "SubjectDistance", .tiff_type = .rational },
    .{ .id = 0x9207, .name = "MeteringMode", .tiff_type = .short },
    .{ .id = 0x9208, .name = "LightSource", .tiff_type = .short },
    .{ .id = 0x9209, .name = "Flash", .tiff_type = .short },
    .{ .id = 0x920A, .name = "FocalLength", .tiff_type = .rational },
    .{ .id = 0x9214, .name = "SubjectArea", .tiff_type = .short },
    .{ .id = 0x927C, .name = "MakerNote", .tiff_type = .undefined },
    .{ .id = 0x9286, .name = "UserComment", .tiff_type = .undefined },
    .{ .id = 0x9290, .name = "SubSecTime", .tiff_type = .ascii },
    .{ .id = 0x9291, .name = "SubSecTimeOriginal", .tiff_type = .ascii },
    .{ .id = 0x9292, .name = "SubSecTimeDigitized", .tiff_type = .ascii },
    .{ .id = 0xA000, .name = "FlashpixVersion", .tiff_type = .undefined },
    .{ .id = 0xA001, .name = "ColorSpace", .tiff_type = .short },
    .{ .id = 0xA002, .name = "PixelXDimension", .tiff_type = .long },
    .{ .id = 0xA003, .name = "PixelYDimension", .tiff_type = .long },
    .{ .id = 0xA004, .name = "RelatedSoundFile", .tiff_type = .ascii },
    .{ .id = 0xA20B, .name = "FlashEnergy", .tiff_type = .rational },
    .{ .id = 0xA20E, .name = "FocalPlaneXResolution", .tiff_type = .rational },
    .{ .id = 0xA20F, .name = "FocalPlaneYResolution", .tiff_type = .rational },
    .{ .id = 0xA210, .name = "FocalPlaneResolutionUnit", .tiff_type = .short },
    .{ .id = 0xA214, .name = "SubjectLocation", .tiff_type = .short },
    .{ .id = 0xA215, .name = "ExposureIndex", .tiff_type = .rational },
    .{ .id = 0xA217, .name = "SensingMethod", .tiff_type = .short },
    .{ .id = 0xA300, .name = "FileSource", .tiff_type = .undefined },
    .{ .id = 0xA301, .name = "SceneType", .tiff_type = .undefined },
    .{ .id = 0xA302, .name = "CFAPattern", .tiff_type = .undefined },
    .{ .id = 0xA401, .name = "CustomRendered", .tiff_type = .short },
    .{ .id = 0xA402, .name = "ExposureMode", .tiff_type = .short },
    .{ .id = 0xA403, .name = "WhiteBalance", .tiff_type = .short },
    .{ .id = 0xA404, .name = "DigitalZoomRatio", .tiff_type = .rational },
    .{ .id = 0xA405, .name = "FocalLengthIn35mmFilm", .tiff_type = .short },
    .{ .id = 0xA406, .name = "SceneCaptureType", .tiff_type = .short },
    .{ .id = 0xA407, .name = "GainControl", .tiff_type = .short },
    .{ .id = 0xA408, .name = "Contrast", .tiff_type = .short },
    .{ .id = 0xA409, .name = "Saturation", .tiff_type = .short },
    .{ .id = 0xA40A, .name = "Sharpness", .tiff_type = .short },
    .{ .id = 0xA40C, .name = "SubjectDistanceRange", .tiff_type = .short },
    .{ .id = 0xA420, .name = "ImageUniqueID", .tiff_type = .ascii },
    .{ .id = 0xA430, .name = "CameraOwnerName", .tiff_type = .ascii },
    .{ .id = 0xA431, .name = "BodySerialNumber", .tiff_type = .ascii },
    .{ .id = 0xA432, .name = "LensSpecification", .tiff_type = .rational },
    .{ .id = 0xA433, .name = "LensMake", .tiff_type = .ascii },
    .{ .id = 0xA434, .name = "LensModel", .tiff_type = .ascii },
    .{ .id = 0xA435, .name = "LensSerialNumber", .tiff_type = .ascii },
};

// ============================================================================
// GPS sub-IFD tags
// ============================================================================

const gps_tags = [_]TagInfo{
    .{ .id = 0x0000, .name = "GPSVersionID", .tiff_type = .byte },
    .{ .id = 0x0001, .name = "GPSLatitudeRef", .tiff_type = .ascii },
    .{ .id = 0x0002, .name = "GPSLatitude", .tiff_type = .rational },
    .{ .id = 0x0003, .name = "GPSLongitudeRef", .tiff_type = .ascii },
    .{ .id = 0x0004, .name = "GPSLongitude", .tiff_type = .rational },
    .{ .id = 0x0005, .name = "GPSAltitudeRef", .tiff_type = .byte },
    .{ .id = 0x0006, .name = "GPSAltitude", .tiff_type = .rational },
    .{ .id = 0x0007, .name = "GPSTimeStamp", .tiff_type = .rational },
    .{ .id = 0x0008, .name = "GPSSatellites", .tiff_type = .ascii },
    .{ .id = 0x0009, .name = "GPSStatus", .tiff_type = .ascii },
    .{ .id = 0x000A, .name = "GPSMeasureMode", .tiff_type = .ascii },
    .{ .id = 0x000B, .name = "GPSDOP", .tiff_type = .rational },
    .{ .id = 0x000C, .name = "GPSSpeedRef", .tiff_type = .ascii },
    .{ .id = 0x000D, .name = "GPSSpeed", .tiff_type = .rational },
    .{ .id = 0x000E, .name = "GPSTrackRef", .tiff_type = .ascii },
    .{ .id = 0x000F, .name = "GPSTrack", .tiff_type = .rational },
    .{ .id = 0x0010, .name = "GPSImgDirectionRef", .tiff_type = .ascii },
    .{ .id = 0x0011, .name = "GPSImgDirection", .tiff_type = .rational },
    .{ .id = 0x0012, .name = "GPSMapDatum", .tiff_type = .ascii },
    .{ .id = 0x0013, .name = "GPSDestLatitudeRef", .tiff_type = .ascii },
    .{ .id = 0x0014, .name = "GPSDestLatitude", .tiff_type = .rational },
    .{ .id = 0x0015, .name = "GPSDestLongitudeRef", .tiff_type = .ascii },
    .{ .id = 0x0016, .name = "GPSDestLongitude", .tiff_type = .rational },
    .{ .id = 0x0017, .name = "GPSDestBearingRef", .tiff_type = .ascii },
    .{ .id = 0x0018, .name = "GPSDestBearing", .tiff_type = .rational },
    .{ .id = 0x0019, .name = "GPSDestDistanceRef", .tiff_type = .ascii },
    .{ .id = 0x001A, .name = "GPSDestDistance", .tiff_type = .rational },
    .{ .id = 0x001B, .name = "GPSProcessingMethod", .tiff_type = .undefined },
    .{ .id = 0x001C, .name = "GPSAreaInformation", .tiff_type = .undefined },
    .{ .id = 0x001D, .name = "GPSDateStamp", .tiff_type = .ascii },
    .{ .id = 0x001E, .name = "GPSDifferential", .tiff_type = .short },
    .{ .id = 0x001F, .name = "GPSHPositioningError", .tiff_type = .rational },
};

// ============================================================================
// Interoperability sub-IFD tags
// ============================================================================

const interop_tags = [_]TagInfo{
    .{ .id = 0x0001, .name = "InteroperabilityIndex", .tiff_type = .ascii },
    .{ .id = 0x0002, .name = "InteroperabilityVersion", .tiff_type = .undefined },
    .{ .id = 0x1000, .name = "RelatedImageFileFormat", .tiff_type = .ascii },
    .{ .id = 0x1001, .name = "RelatedImageWidth", .tiff_type = .long },
    .{ .id = 0x1002, .name = "RelatedImageLength", .tiff_type = .long },
};

// ============================================================================
// Tests
// ============================================================================

test "known IFD0 tag lookup" {
    try std.testing.expectEqualStrings("Make", tagName(.ifd0, 0x010F).?);
    try std.testing.expectEqualStrings("Model", tagName(.ifd0, 0x0110).?);
    try std.testing.expectEqualStrings("Orientation", tagName(.ifd0, 0x0112).?);
    try std.testing.expectEqualStrings("DateTime", tagName(.ifd0, 0x0132).?);
}

test "known Exif tag lookup" {
    try std.testing.expectEqualStrings("ExposureTime", tagName(.exif, 0x829A).?);
    try std.testing.expectEqualStrings("FNumber", tagName(.exif, 0x829D).?);
    try std.testing.expectEqualStrings("ISOSpeedRatings", tagName(.exif, 0x8827).?);
    try std.testing.expectEqualStrings("FocalLength", tagName(.exif, 0x920A).?);
    try std.testing.expectEqualStrings("LensModel", tagName(.exif, 0xA434).?);
}

test "known GPS tag lookup" {
    try std.testing.expectEqualStrings("GPSLatitudeRef", tagName(.gps, 0x0001).?);
    try std.testing.expectEqualStrings("GPSLatitude", tagName(.gps, 0x0002).?);
    try std.testing.expectEqualStrings("GPSAltitude", tagName(.gps, 0x0006).?);
}

test "unknown tag returns null" {
    try std.testing.expect(tagName(.ifd0, 0xFFFF) == null);
    try std.testing.expect(tagName(.exif, 0x0001) == null);
}

test "sub-IFD tag names" {
    try std.testing.expectEqualStrings("ExifIFD", tagName(.ifd0, 0x8769).?);
    try std.testing.expectEqualStrings("GPSIFD", tagName(.ifd0, 0x8825).?);
    try std.testing.expectEqualStrings("InteropIFD", tagName(.exif, 0xA005).?);
}

test "reverse lookup by name" {
    try std.testing.expectEqual(@as(?u16, 0x010F), tagId(.ifd0, "Make"));
    try std.testing.expectEqual(@as(?u16, 0x829A), tagId(.exif, "ExposureTime"));
    try std.testing.expectEqual(@as(?u16, 0x0002), tagId(.gps, "GPSLatitude"));
    try std.testing.expect(tagId(.ifd0, "NonexistentTag") == null);
}

test "sub-IFD reverse lookup" {
    try std.testing.expectEqual(@as(?u16, 0x8769), tagId(.ifd0, "ExifIFD"));
    try std.testing.expectEqual(@as(?u16, 0x8825), tagId(.ifd0, "GPSIFD"));
    try std.testing.expectEqual(@as(?u16, 0xA005), tagId(.exif, "InteropIFD"));
}

test "tag type lookup" {
    try std.testing.expectEqual(TiffType.ascii, tagType(.ifd0, 0x010F).?);
    try std.testing.expectEqual(TiffType.short, tagType(.ifd0, 0x0112).?);
    try std.testing.expectEqual(TiffType.rational, tagType(.ifd0, 0x011A).?);
    try std.testing.expectEqual(TiffType.rational, tagType(.exif, 0x829A).?);
    try std.testing.expectEqual(TiffType.long, tagType(.ifd0, 0x8769).?); // sub-IFD pointer
    try std.testing.expect(tagType(.ifd0, 0xFFFF) == null);
}

test "unknown tag formatting" {
    var buf: [8]u8 = undefined;
    const name = formatUnknownTag(&buf, 0x010F);
    try std.testing.expectEqualStrings("tag_010F", name);
}

test "unknown tag formatting zero padded" {
    var buf: [8]u8 = undefined;
    const name = formatUnknownTag(&buf, 0x0001);
    try std.testing.expectEqualStrings("tag_0001", name);
}

test "unknown tag parsing" {
    try std.testing.expectEqual(@as(?u16, 0x010F), parseUnknownTag("tag_010F"));
    try std.testing.expectEqual(@as(?u16, 0x0001), parseUnknownTag("tag_0001"));
    try std.testing.expect(parseUnknownTag("notag") == null);
    try std.testing.expect(parseUnknownTag("tag_ZZZZ") == null);
}

test "TiffType sizes" {
    try std.testing.expectEqual(@as(u8, 1), TiffType.byte.size());
    try std.testing.expectEqual(@as(u8, 1), TiffType.ascii.size());
    try std.testing.expectEqual(@as(u8, 2), TiffType.short.size());
    try std.testing.expectEqual(@as(u8, 4), TiffType.long.size());
    try std.testing.expectEqual(@as(u8, 8), TiffType.rational.size());
    try std.testing.expectEqual(@as(u8, 1), TiffType.undefined.size());
    try std.testing.expectEqual(@as(u8, 8), TiffType.double.size());
}
