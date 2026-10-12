/*
 * Port of org.schabi.newpipe.streams.OggFromWebMWriter (by kapodamy): rewraps the Opus/Vorbis
 * track of a WebM as an Ogg stream - a page per second of audio, each with its CRC32.
 *
 * StreamInfo cannot be imported here, so makeMetadata() reads the five fields it needs from an
 * OggStreamInfo the caller fills. null writes an OpusTags header without tags, as the source does
 * when it has no StreamInfo. The source's DEBUG logging is left out.
 */

import { DataReaderView, toInt32 } from './DataReader';
import {
  Cluster,
  Segment,
  SimpleBlock,
  TrackKind,
  WebMReader,
  WebMTrack,
  setLong,
  utf8Encode
} from './WebMReader';
import { SharpStream, StreamError } from './SharpStream';

const FLAG_UNSET: number = 0x00;
//const FLAG_CONTINUED: number = 0x01;
const FLAG_FIRST: number = 0x02;
const FLAG_LAST: number = 0x04;

const HEADER_CHECKSUM_OFFSET: number = 22;
const HEADER_SIZE: number = 27;

const TIME_SCALE_NS: number = 1000000000;

/** The StreamInfo fields makeMetadata() writes as Opus tags. */
export class OggStreamInfo {
  url: string = '';
  category: string = '';
  uploaderName: string = '';
  name: string = '';
  /** getUploadDate() as epoch milliseconds; null leaves the DATE tag out. */
  uploadDate: number | null = null;
}

/** android.util.Pair<String, String>. */
class Pair {
  readonly first: string;
  readonly second: string;

  constructor(first: string, second: string) {
    this.first = first;
    this.second = second;
  }
}

/** The part of a LITTLE_ENDIAN java.nio.ByteBuffer that build() uses: an array and a position. */
class PageBuffer {
  readonly data: Uint8Array;
  readonly view: DataView;
  position: number = 0;

  constructor(capacity: number) {
    this.data = new Uint8Array(capacity);
    this.view = new DataView(this.data.buffer);
  }

  put(value: number): void {
    this.data[this.position] = value;
    this.position++;
  }

  putInt(value: number): void {
    this.view.setInt32(this.position, value, true);
    this.position += 4;
  }

  putLong(value: number): void {
    setLong(this.view, this.position, value, true);
    this.position += 8;
  }

  putBytes(src: Uint8Array, offset: number, length: number): void {
    this.data.set(src.subarray(offset, offset + length), this.position);
    this.position += length;
  }
}

/** String.trim(): strips the chars <= U+0020 at both ends (JS trim() strips a different set). */
function javaTrim(value: string): string {
  let start: number = 0;
  let end: number = value.length;
  while (start < end && value.charCodeAt(start) <= 0x20) {
    start++;
  }
  while (start < end && value.charCodeAt(end - 1) <= 0x20) {
    end--;
  }
  return value.substring(start, end);
}

/** String.isBlank(): only Character.isWhitespace chars, which leave out the no-break spaces. */
function javaIsBlank(value: string): boolean {
  for (let i: number = 0; i < value.length; i++) {
    const c: number = value.charCodeAt(i);
    const whitespace: boolean = (c >= 0x09 && c <= 0x0D) || (c >= 0x1C && c <= 0x20)
      || c === 0x1680 || (c >= 0x2000 && c <= 0x2006) || (c >= 0x2008 && c <= 0x200A)
      || c === 0x2028 || c === 0x2029 || c === 0x205F || c === 0x3000;
    if (!whitespace) {
      return false;
    }
  }
  return true;
}

/** getUploadDate().getLocalDateTime().format(DateTimeFormatter.ISO_DATE): local yyyy-MM-dd. */
function isoDate(epochMillis: number): string {
  const date: Date = new Date(epochMillis);
  return date.getFullYear().toString().padStart(4, '0') + '-'
    + (date.getMonth() + 1).toString().padStart(2, '0') + '-'
    + date.getDate().toString().padStart(2, '0');
}

export class OggFromWebMWriter {
  private done: boolean = false;
  private parsed: boolean = false;

  private readonly source: SharpStream;
  private readonly output: SharpStream;

  private sequenceCount: number = 0;
  private readonly streamId: number;
  private packetFlag: number = FLAG_FIRST;

  private webm: WebMReader | null = null;
  private webmTrack: WebMTrack | null = null;
  private webmSegment: Segment | null = null;
  private webmCluster: Cluster | null = null;
  private webmBlock: SimpleBlock | null = null;

  private webmBlockLastTimecode: number = 0;
  private webmBlockNearDuration: number = 0;

  private segmentTableSize: number = 0;
  private readonly segmentTable: Uint8Array = new Uint8Array(255);
  private segmentTableNextTimestamp: number = TIME_SCALE_NS;

  private readonly crc32Table: Int32Array = new Int32Array(256);
  private readonly streamInfo: OggStreamInfo | null;

  constructor(source: SharpStream, target: SharpStream, streamInfo: OggStreamInfo | null) {
    if (!source.canRead() || !source.canRewind()) {
      throw new Error('source stream must be readable and allows seeking');
    }
    if (!target.canWrite() || !target.canRewind()) {
      throw new Error('output stream must be writable and allows seeking');
    }

    this.source = source;
    this.output = target;
    this.streamInfo = streamInfo;

    this.streamId = toInt32(Date.now()); // (int) System.currentTimeMillis()

    this.populateCrc32Table();
  }

  isDone(): boolean {
    return this.done;
  }

  isParsed(): boolean {
    return this.parsed;
  }

  getTracksFromSource(): WebMTrack[] {
    if (!this.parsed) {
      throw new Error('source must be parsed first');
    }

    return this.requireWebm().getAvailableTracks();
  }

  parseSource(): void {
    if (this.done) {
      throw new Error('already done');
    }
    if (this.parsed) {
      throw new Error('already parsed');
    }

    try {
      const webm: WebMReader = new WebMReader(this.source);
      this.webm = webm;
      webm.parse();
      this.webmSegment = webm.getNextSegment();
    } finally {
      this.parsed = true;
    }
  }

  selectTrack(trackIndex: number): void {
    if (!this.parsed) {
      throw new Error('source must be parsed first');
    }
    if (this.done) {
      throw new StreamError('already done');
    }
    if (this.webmTrack !== null) {
      throw new StreamError('tracks already selected');
    }

    const webm: WebMReader = this.requireWebm();
    switch (webm.getAvailableTracks()[trackIndex].kind) {
      case TrackKind.Audio:
      case TrackKind.Video:
        break;
      default:
        throw new Error('the track must an audio or video stream');
    }

    try {
      this.webmTrack = webm.selectTrack(trackIndex);
    } finally {
      this.parsed = true;
    }
  }

  close(): void {
    this.done = true;
    this.parsed = true;

    this.webmTrack = null;
    this.webm = null;

    if (!this.output.isClosed()) {
      this.output.flush();
    }

    this.source.close();
    this.output.close();
  }

  build(): void {
    let resolution: number = 0; // a Java float
    let bloq: SimpleBlock | null = null;
    const header: PageBuffer = new PageBuffer(27 + (255 * 255));
    const page: PageBuffer = new PageBuffer(64 * 1024);

    const webmTrack: WebMTrack = this.requireTrack();

    /* step 1: get the amount of frames per seconds */
    switch (webmTrack.kind) {
      case TrackKind.Audio:
        resolution = this.getSampleFrequencyFromTrack(webmTrack.bMetadata);
        if (resolution === 0) {
          throw new Error('cannot get the audio sample rate');
        }
        break;
      case TrackKind.Video:
        // WARNING: untested
        if (webmTrack.defaultDuration === 0) {
          throw new Error('missing default frame time');
        }
        // 1000f / ((float) defaultDuration / timecodeScale), all in float
        resolution = Math.fround(1000 / Math.fround(Math.fround(webmTrack.defaultDuration)
          / Math.fround(this.requireSegmentInfoTimecodeScale())));
        break;
      default:
        throw new Error('not implemented');
    }

    /* step 2: create packet with code init data */
    const codecPrivate: Uint8Array | null = webmTrack.codecPrivate;
    if (codecPrivate !== null) {
      this.addPacketSegment(codecPrivate.length);
      this.makePacketheader(0x00, header, codecPrivate);
      this.write(header);
      this.output.write(codecPrivate);
    }

    /* step 3: create packet with metadata */
    const buffer: Uint8Array | null = this.makeMetadata(webmTrack);
    if (buffer !== null) {
      this.addPacketSegment(buffer.length);
      this.makePacketheader(0x00, header, buffer);
      this.write(header);
      this.output.write(buffer);
    }

    /* step 4: calculate amount of packets */
    while (this.webmSegment !== null) {
      bloq = this.getNextBlock();

      if (bloq !== null && this.addPacketSegmentFromBlock(webmTrack, bloq)) {
        const pos: number = page.position;
        const data: DataReaderView | null = bloq.data;
        if (data === null) {
          throw new Error('block without data'); // a NullPointerException in the source
        }
        data.readInto(page.data, pos, bloq.dataSize);
        page.position = pos + bloq.dataSize;
        continue;
      }

      // calculate the current packet duration using the next block
      let elapsedNs: number = webmTrack.codecDelay;

      if (bloq === null) {
        this.packetFlag = FLAG_LAST; // note: if the flag is FLAG_CONTINUED, is changed
        elapsedNs += this.webmBlockLastTimecode;

        if (webmTrack.defaultDuration > 0) {
          elapsedNs += webmTrack.defaultDuration;
        } else {
          // hardcoded way, guess the sample duration
          elapsedNs += this.webmBlockNearDuration;
        }
      } else {
        elapsedNs += bloq.absoluteTimeCodeNs;
      }

      // get the sample count in the page
      elapsedNs = elapsedNs / TIME_SCALE_NS;
      elapsedNs = Math.ceil(elapsedNs * resolution);

      // create header and calculate page checksum; (long) elapsedNs is a no-op: it is ceil()ed
      let checksum: number = this.makePacketheader(elapsedNs, header, null);
      checksum = this.calcCrc32(checksum, page.data, page.position);

      header.view.setInt32(HEADER_CHECKSUM_OFFSET, checksum, true);

      // dump data
      this.write(header);
      this.write(page);

      this.webmBlock = bloq;
    }
  }

  private makePacketheader(granPos: number, buffer: PageBuffer,
    immediatePage: Uint8Array | null): number {
    let length: number = HEADER_SIZE;

    buffer.putInt(0x5367674f); // "OggS" binary string in little-endian
    buffer.put(0x00); // version
    buffer.put(this.packetFlag); // type

    buffer.putLong(granPos); // granulate position

    buffer.putInt(this.streamId); // bitstream serial number
    buffer.putInt(this.sequenceCount); // page sequence number
    this.sequenceCount = (this.sequenceCount + 1) | 0;

    buffer.putInt(0x00); // page checksum

    buffer.put(this.segmentTableSize); // segment table
    buffer.putBytes(this.segmentTable, 0, this.segmentTableSize); // segment size

    length += this.segmentTableSize;

    this.clearSegmentTable(); // clear segment table for next header

    let checksumCrc32: number = this.calcCrc32(0x00, buffer.data, length);

    if (immediatePage !== null) {
      checksumCrc32 = this.calcCrc32(checksumCrc32, immediatePage, immediatePage.length);
      buffer.view.setInt32(HEADER_CHECKSUM_OFFSET, checksumCrc32, true);
      this.segmentTableNextTimestamp -= TIME_SCALE_NS;
    }

    return checksumCrc32;
  }

  private makeMetadata(webmTrack: WebMTrack): Uint8Array | null {
    if ('A_OPUS' === webmTrack.codecId) {
      const metadata: Pair[] = [];
      const streamInfo: OggStreamInfo | null = this.streamInfo;
      if (streamInfo !== null) {
        metadata.push(new Pair('COMMENT', streamInfo.url));
        metadata.push(new Pair('GENRE', streamInfo.category));
        metadata.push(new Pair('ARTIST', streamInfo.uploaderName));
        metadata.push(new Pair('TITLE', streamInfo.name));
        const uploadDate: number | null = streamInfo.uploadDate;
        if (uploadDate !== null) {
          metadata.push(new Pair('DATE', isoDate(uploadDate)));
        }
      }

      return OggFromWebMWriter.makeOpusTagsHeader(metadata);
    } else if ('A_VORBIS' === webmTrack.codecId) {
      return new Uint8Array([
        0x03, // ¿¿¿???
        0x76, 0x6f, 0x72, 0x62, 0x69, 0x73, // "vorbis" binary string
        0x00, 0x00, 0x00, 0x00, // writing application string size (not present)
        0x00, 0x00, 0x00, 0x00 // additional tags count (zero means no tags)
      ]);
    }

    // not implemented for the desired codec
    return null;
  }

  /**
   * This creates a single metadata tag for use in opus metadata headers. It contains the four
   * byte string length field and includes the string as-is. This cannot be used independently,
   * but must follow a proper "OpusTags" header.
   *
   * @param pair A key-value pair in the format "KEY=some value"
   * @return The binary data of the encoded metadata tag
   */
  private static makeOpusMetadataTag(pair: Pair): Uint8Array {
    const keyValue: string = pair.first.toUpperCase() + '=' + javaTrim(pair.second);

    const bytes: Uint8Array = utf8Encode(keyValue);
    const buf: Uint8Array = new Uint8Array(4 + bytes.length);
    new DataView(buf.buffer).setInt32(0, bytes.length, true);
    buf.set(bytes, 4);
    return buf;
  }

  /**
   * This returns a complete "OpusTags" header, created from the provided metadata tags.
   *
   * @param keyValueLines A list of pairs of the tags. This can also be though of as a mapping
   *                      from one key to multiple values.
   * @return The binary header
   */
  private static makeOpusTagsHeader(keyValueLines: Pair[]): Uint8Array {
    const tags: Uint8Array[] = keyValueLines
      .filter((p: Pair): boolean => !javaIsBlank(p.second))
      .map((p: Pair): Uint8Array => OggFromWebMWriter.makeOpusMetadataTag(p));

    let tagsBytes: number = 0;
    for (const arr of tags) {
      tagsBytes += arr.length;
    }

    // Fixed header fields + dynamic fields
    const byteCount: number = 16 + tagsBytes;

    const head: Uint8Array = new Uint8Array(byteCount);
    head.set([
      0x4F, 0x70, 0x75, 0x73, 0x54, 0x61, 0x67, 0x73, // "OpusTags" binary string
      0x00, 0x00, 0x00, 0x00, // vendor (aka. Encoder) string of length 0
    ], 0);
    new DataView(head.buffer).setInt32(12, tags.length, true); // 4 bytes for tag count
    let offset: number = 16;
    for (const tag of tags) { // dynamic amount of tag bytes
      head.set(tag, offset);
      offset += tag.length;
    }

    return head;
  }

  private write(buffer: PageBuffer): void {
    this.output.writeFrom(buffer.data, 0, buffer.position);
    buffer.position = 0;
  }

  private getNextBlock(): SimpleBlock | null {
    let res: SimpleBlock | null = this.webmBlock;

    if (res !== null) {
      this.webmBlock = null;
      return res;
    }

    let segment: Segment | null = this.webmSegment;
    if (segment === null) {
      segment = this.requireWebm().getNextSegment();
      this.webmSegment = segment;
      if (segment === null) {
        return null; // no more blocks in the selected track
      }
    }

    let cluster: Cluster | null = this.webmCluster;
    if (cluster === null) {
      cluster = segment.getNextCluster();
      this.webmCluster = cluster;
      if (cluster === null) {
        this.webmSegment = null;
        return this.getNextBlock();
      }
    }

    res = cluster.getNextSimpleBlock();
    if (res === null) {
      this.webmCluster = null;
      return this.getNextBlock();
    }

    this.webmBlockNearDuration = res.absoluteTimeCodeNs - this.webmBlockLastTimecode;
    this.webmBlockLastTimecode = res.absoluteTimeCodeNs;

    return res;
  }

  private getSampleFrequencyFromTrack(bMetadata: Uint8Array | null): number {
    if (bMetadata === null) {
      throw new Error('track without Audio element'); // ByteBuffer.wrap(null) in the source
    }

    // hardcoded way
    const buffer: DataView =
      new DataView(bMetadata.buffer, bMetadata.byteOffset, bMetadata.byteLength);
    let position: number = 0;

    while (bMetadata.length - position >= 6) {
      const id: number = buffer.getUint16(position); // getShort() & 0xFFFF
      position += 2;
      if (id === 0x0000B584) {
        return buffer.getFloat32(position);
      }
    }

    return 0.0;
  }

  private clearSegmentTable(): void {
    this.segmentTableNextTimestamp += TIME_SCALE_NS;
    this.packetFlag = FLAG_UNSET;
    this.segmentTableSize = 0;
  }

  /** addPacketSegment(SimpleBlock) of the source. */
  private addPacketSegmentFromBlock(webmTrack: WebMTrack, block: SimpleBlock): boolean {
    const timestamp: number = block.absoluteTimeCodeNs + webmTrack.codecDelay;

    if (timestamp >= this.segmentTableNextTimestamp) {
      return false;
    }

    return this.addPacketSegment(block.dataSize);
  }

  private addPacketSegment(size: number): boolean {
    if (size > 65025) {
      throw new Error('page size cannot be larger than 65025');
    }

    let available: number = (this.segmentTable.length - this.segmentTableSize) * 255;
    const extra: boolean = (size % 255) === 0;

    if (extra) {
      // add a zero byte entry in the table
      // required to indicate the sample size is multiple of 255
      available -= 255;
    }

    // check if possible add the segment, without overflow the table
    if (available < size) {
      return false; // not enough space on the page
    }

    for (let seg: number = size; seg > 0; seg -= 255) {
      this.segmentTable[this.segmentTableSize++] = Math.min(seg, 255);
    }

    if (extra) {
      this.segmentTable[this.segmentTableSize++] = 0x00;
    }

    return true;
  }

  // The CRC works on Java ints: signed 32-bit values, kept so by the 32-bit operators, and
  // written with setInt32 - the same bytes the source writes.
  private populateCrc32Table(): void {
    for (let i: number = 0; i < 0x100; i++) {
      let crc: number = i << 24;
      for (let j: number = 0; j < 8; j++) {
        const b: number = crc >>> 31;
        crc <<= 1;
        crc ^= -b & 0x04c11db7; // (int) (0x100000000L - b) is 0 for b == 0, all bits for b == 1
      }
      this.crc32Table[i] = crc;
    }
  }

  private calcCrc32(initialCrc: number, buffer: Uint8Array, size: number): number {
    let crc: number = initialCrc;
    for (let i: number = 0; i < size; i++) {
      const reg: number = (crc >>> 24) & 0xff;
      crc = (crc << 8) ^ this.crc32Table[reg ^ buffer[i]];
    }

    return crc;
  }

  private requireWebm(): WebMReader {
    const webm: WebMReader | null = this.webm;
    if (webm === null) {
      throw new Error('source must be parsed first');
    }
    return webm;
  }

  private requireTrack(): WebMTrack {
    const track: WebMTrack | null = this.webmTrack;
    if (track === null) {
      throw new Error('no track selected');
    }
    return track;
  }

  /** webmSegment.info.timecodeScale, dereferenced unchecked by the source. */
  private requireSegmentInfoTimecodeScale(): number {
    const segment: Segment | null = this.webmSegment;
    if (segment === null || segment.info === null) {
      throw new Error('WebM segment without Info');
    }
    return segment.info.timecodeScale;
  }
}
