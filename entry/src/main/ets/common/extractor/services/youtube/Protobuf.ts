/*
 * Port of the two generated protobuf classes the YouTube service uses:
 *   extractor/src/main/proto/youtube/video/xtags.proto          -> XTags / KeyValuePair
 *   extractor/src/main/proto/youtube/playlist/...continuation   -> PlaylistContinuation
 *
 * The source compiles these with protobuf-lite at build time. There is no protobuf runtime for
 * ArkTS and neither schema is a Rule-11 port task, so the wire format is written out directly:
 * both messages use only field 2 (length-delimited string) and field 1/80226972 (length-delimited
 * sub-message), which is the simplest corner of proto3. This is a port of the generated code's
 * behaviour, not a substitution — the bytes on the wire are identical.
 *
 * Wire format used here (proto3):
 *   tag  = (fieldNumber << 3) | wireType, encoded as a varint
 *   type 2 (length-delimited) = varint byte length, then that many bytes
 * proto3 omits a field whose value is the default (an empty string), which is why both the
 * writer and the reader skip empties.
 */

import { util } from '@kit.ArkTS';

const WIRE_TYPE_LENGTH_DELIMITED: number = 2;

function encodeVarint(value: number): number[] {
  const out: number[] = [];
  let remaining: number = value;
  while (remaining > 127) {
    out.push((remaining & 0x7f) | 0x80);
    remaining = Math.floor(remaining / 128);
  }
  out.push(remaining & 0x7f);
  return out;
}

function encodeTag(fieldNumber: number, wireType: number): number[] {
  // fieldNumber can exceed 2^28 (80226972 << 3 still fits in a double exactly), so multiply
  // rather than shift: ArkTS bitwise operators truncate to 32 bits.
  return encodeVarint(fieldNumber * 8 + wireType);
}

/** One length-delimited field: tag, length, payload. */
function encodeLengthDelimited(fieldNumber: number, payload: number[]): number[] {
  let out: number[] = encodeTag(fieldNumber, WIRE_TYPE_LENGTH_DELIMITED);
  out = out.concat(encodeVarint(payload.length));
  return out.concat(payload);
}

function encodeStringField(fieldNumber: number, value: string): number[] {
  if (value.length === 0) {
    // proto3 does not put a default-valued scalar on the wire
    return [];
  }
  const encoded: Uint8Array = new util.TextEncoder().encodeInto(value);
  const bytes: number[] = [];
  for (let i = 0; i < encoded.length; i++) {
    bytes.push(encoded[i]);
  }
  return encodeLengthDelimited(fieldNumber, bytes);
}

/** A cursor over a byte array, so the reader can be written without a class per message. */
class ByteReader {
  private readonly bytes: Uint8Array;
  private position: number = 0;

  constructor(bytes: Uint8Array) {
    this.bytes = bytes;
  }

  hasMore(): boolean {
    return this.position < this.bytes.length;
  }

  readVarint(): number {
    let result: number = 0;
    let shiftMultiplier: number = 1;
    while (this.position < this.bytes.length) {
      const byte: number = this.bytes[this.position];
      this.position++;
      result += (byte & 0x7f) * shiftMultiplier;
      if ((byte & 0x80) === 0) {
        return result;
      }
      shiftMultiplier *= 128;
    }
    throw new Error('Truncated protobuf varint');
  }

  readBytes(length: number): Uint8Array {
    if (this.position + length > this.bytes.length) {
      throw new Error('Truncated protobuf length-delimited field');
    }
    const slice: Uint8Array = this.bytes.subarray(this.position, this.position + length);
    this.position += length;
    return slice;
  }

  /** Skip a field whose tag has already been read, so an unknown field cannot desync the parse. */
  skipField(wireType: number): void {
    if (wireType === WIRE_TYPE_LENGTH_DELIMITED) {
      this.readBytes(this.readVarint());
    } else if (wireType === 0) {
      this.readVarint();
    } else if (wireType === 5) {
      this.readBytes(4);
    } else if (wireType === 1) {
      this.readBytes(8);
    } else {
      throw new Error('Unsupported protobuf wire type ' + wireType);
    }
  }
}

function decodeUtf8(bytes: Uint8Array): string {
  return util.TextDecoder.create('utf-8').decodeToString(bytes);
}

/** Port of youtube.video.KeyValuePair. */
export class KeyValuePair {
  readonly key: string;
  readonly value: string;

  constructor(key: string, value: string) {
    this.key = key;
    this.value = value;
  }

  getKey(): string {
    return this.key;
  }

  getValue(): string {
    return this.value;
  }
}

/** Port of youtube.video.XTags: `repeated KeyValuePair xtags = 1`. */
export class XTags {
  readonly xtags: KeyValuePair[];

  constructor(xtags: KeyValuePair[]) {
    this.xtags = xtags;
  }

  getXtagsList(): KeyValuePair[] {
    return this.xtags;
  }

  /** Port of XTags.parseFrom(byte[]); throws on malformed input, as the generated code does. */
  static parseFrom(bytes: Uint8Array): XTags {
    const reader: ByteReader = new ByteReader(bytes);
    const pairs: KeyValuePair[] = [];
    while (reader.hasMore()) {
      const tag: number = reader.readVarint();
      const fieldNumber: number = Math.floor(tag / 8);
      const wireType: number = tag % 8;
      if (fieldNumber === 1 && wireType === WIRE_TYPE_LENGTH_DELIMITED) {
        pairs.push(XTags.parseKeyValuePair(reader.readBytes(reader.readVarint())));
      } else {
        reader.skipField(wireType);
      }
    }
    return new XTags(pairs);
  }

  private static parseKeyValuePair(bytes: Uint8Array): KeyValuePair {
    const reader: ByteReader = new ByteReader(bytes);
    let key: string = '';
    let value: string = '';
    while (reader.hasMore()) {
      const tag: number = reader.readVarint();
      const fieldNumber: number = Math.floor(tag / 8);
      const wireType: number = tag % 8;
      if (wireType === WIRE_TYPE_LENGTH_DELIMITED && fieldNumber === 1) {
        key = decodeUtf8(reader.readBytes(reader.readVarint()));
      } else if (wireType === WIRE_TYPE_LENGTH_DELIMITED && fieldNumber === 2) {
        value = decodeUtf8(reader.readBytes(reader.readVarint()));
      } else {
        reader.skipField(wireType);
      }
    }
    return new KeyValuePair(key, value);
  }
}

/**
 * Port of youtube.playlists.ContinuationParams:
 *   string browseId = 2; string continuationProperties = 3; string playlistId = 35;
 */
export class ContinuationParams {
  browseId: string = '';
  continuationProperties: string = '';
  playlistId: string = '';

  toBytes(): number[] {
    let out: number[] = encodeStringField(2, this.browseId);
    out = out.concat(encodeStringField(3, this.continuationProperties));
    return out.concat(encodeStringField(35, this.playlistId));
  }
}

/** Port of youtube.playlists.PlaylistContinuation: `ContinuationParams parameters = 80226972`. */
export class PlaylistContinuation {
  parameters: ContinuationParams = new ContinuationParams();

  toBytes(): number[] {
    return encodeLengthDelimited(80226972, this.parameters.toBytes());
  }

  /** The message as a Uint8Array, ready for base64url encoding (what the continuation is). */
  toByteArray(): Uint8Array {
    return Uint8Array.from(this.toBytes());
  }
}

/**
 * URL-safe base64 — java.util.Base64.getUrlEncoder()'s output, padding included (Java's URL
 * encoder pads unless withoutPadding() is called, and YoutubePlaylistExtractor does not call it).
 * util.Type.BASIC_URL_SAFE uses the same alphabet but drops the padding, so it is restored here.
 */
export function base64UrlEncode(bytes: Uint8Array): string {
  let encoded: string = new util.Base64Helper()
    .encodeToStringSync(bytes, util.Type.BASIC_URL_SAFE);
  while (encoded.length % 4 !== 0) {
    encoded += '=';
  }
  return encoded;
}

/** The inverse: java.util.Base64.getUrlDecoder().decode(), which accepts unpadded input too. */
export function base64UrlDecode(text: string): Uint8Array {
  let padded: string = text;
  while (padded.length % 4 !== 0) {
    padded += '=';
  }
  return new util.Base64Helper().decodeSync(padded, util.Type.BASIC_URL_SAFE);
}
