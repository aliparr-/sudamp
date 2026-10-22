// SPDX-License-Identifier: GPL-3.0-or-later
// ZIP names without the UTF-8 flag (general-purpose bit 11) are IBM code page 437, which is what 1990s/2000s
// Windows zip tools wrote. Bytes 0x00-0x7F are ASCII; this table maps 0x80-0xFF to Unicode.

enum CP437 {
    private static let high: [Character] = Array(
        "ÇüéâäàåçêëèïîìÄÅÉæÆôöòûùÿÖÜ¢£¥₧ƒáíóúñÑªº¿⌐¬½¼¡«»░▒▓│┤╡╢╖╕╣║╗╝╜╛┐└┴┬├─┼╞╟╚╔╩╦╠═╬╧╨╤╥╙╘╒╓╫╪┘┌█▄▌▐▀"
            + "αßΓπΣσµτΦΘΩδ∞φε∩≡±≥≤⌠⌡÷≈°∙·√ⁿ²■\u{00A0}")

    static func decode<C: Collection>(_ bytes: C) -> String where C.Element == UInt8 {
        var out = ""
        out.reserveCapacity(bytes.count)
        for byte in bytes {
            if byte < 0x80 {
                out.unicodeScalars.append(Unicode.Scalar(byte))
            } else {
                out.append(high[Int(byte) - 0x80])
            }
        }
        return out
    }
}
