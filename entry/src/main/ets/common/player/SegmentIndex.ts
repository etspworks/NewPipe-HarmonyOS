/*
 * svc_segment_index - the `sidx` (segment index) box of a fragmented MP4, parsed.
 *
 * Why this exists: HlsManifestBuilder used to cut the synthesized playlist into flat 2 MB byte
 * ranges. In fMP4 every segment must start with a `moof` box, and a flat split does not land on
 * one - the first segment plays, the second starts inside an `mdat`, and AVPlayer dies with
 * 5400103 (AVERR_IO, a GENERIC I/O error - not a format error, which would be 5400106; the
 * "DEM_PARSE_ERR" in T-0198's title named the wrong thing). The `sidx` lists every fragment's
 * exact byte length and duration; YouTube hands us its byte range as `indexRange` and the
 * extractor already parses it into VideoStream/AudioStream.indexStart/indexEnd.
 *
 * ISO/IEC 14496-12 section 8.16.3. Pure: no I/O, no kits, host-testable.
 */

/** One fMP4 fragment: where it starts in the file, how long it is, how long it plays. */
export interface Fragment {
  offset: number;
  length: number;
  durationMs: number;
}

/** 'sidx' as a big-endian 32-bit word. */
const SIDX_TYPE: number = 0x73696478;

/**
 * @param buf        the bytes of the sidx box, as returned by a Range GET of indexStart..indexEnd
 * @param indexStart the byte offset `buf` was read from, i.e. indexStart of the track
 * @param mediaStart the file offset the FIRST fragment begins at - normally indexEnd + 1
 * @returns the fragments in order, or [] when `buf` does not hold a parsable sidx
 */
export function parseSidx(buf: ArrayBuffer, indexStart: number, mediaStart: number): Fragment[] {
  // A sidx cannot be shorter than its own header, and indexStart must be a real file offset -
  // a negative one means the caller's range was never filled in.
  if (buf.byteLength < 12 || indexStart < 0) {
    return [];
  }
  const dv: DataView = new DataView(buf);
  if (dv.getUint32(4) !== SIDX_TYPE) {
    return [];
  }
  const version: number = dv.getUint8(8);
  // 12 bytes of box header + version/flags, then reference_ID and timescale.
  let p: number = 12;
  p += 4;
  const timescale: number = dv.getUint32(p);
  p += 4;
  if (timescale <= 0) {
    return [];
  }
  // version 0 stores two 32-bit fields here, version 1 two 64-bit ones. Only first_offset
  // matters and it is almost always 0; read it as the low half and refuse an impossible value
  // rather than pretending to support offsets past 4 GB.
  let firstOffset: number = 0;
  if (version === 0) {
    if (p + 8 > buf.byteLength) {
      return [];
    }
    p += 4;
    firstOffset = dv.getUint32(p);
    p += 4;
  } else {
    if (p + 16 > buf.byteLength) {
      return [];
    }
    p += 8;
    const high: number = dv.getUint32(p);
    firstOffset = dv.getUint32(p + 4);
    p += 8;
    if (high !== 0) {
      return [];
    }
  }
  if (p + 4 > buf.byteLength) {
    return [];
  }
  p += 2;
  const count: number = dv.getUint16(p);
  p += 2;
  if (count <= 0 || p + count * 12 > buf.byteLength) {
    return [];
  }

  const frags: Fragment[] = [];
  let offset: number = mediaStart + firstOffset;
  for (let i: number = 0; i < count; i++) {
    const sizeWord: number = dv.getUint32(p);
    p += 4;
    const duration: number = dv.getUint32(p);
    p += 4;
    p += 4;
    // Top bit set means this reference points at ANOTHER sidx, not at media. A nested index is
    // not something this player builds for, so refuse the whole thing rather than emit a
    // playlist with a hole in it.
    if ((sizeWord & 0x80000000) !== 0) {
      return [];
    }
    const length: number = sizeWord & 0x7fffffff;
    if (length <= 0) {
      return [];
    }
    frags.push({ offset: offset, length: length,
      durationMs: Math.round(duration * 1000 / timescale) });
    offset = offset + length;
  }
  return frags;
}
