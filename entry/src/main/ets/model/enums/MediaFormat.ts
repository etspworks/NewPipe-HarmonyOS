/*
 * Port of org.schabi.newpipe.extractor.MediaFormat (NewPipeExtractor v0.26.5).
 *
 * The Java enum carries four fields; ArkTS enums are uniform-typed, so this is a class with one
 * static instance per constant. VALUES keeps the source's declaration order, which the lookups
 * below depend on: WEBMA/WEBMA_OPUS share id 0x200 and AIFF/AIF share 0x600, so "first match"
 * has to mean the same constant it means in Java.
 */
export class MediaFormat {
  readonly id: number;
  readonly name: string;
  readonly suffix: string;
  readonly mimeType: string;

  constructor(id: number, name: string, suffix: string, mimeType: string) {
    this.id = id;
    this.name = name;
    this.suffix = suffix;
    this.mimeType = mimeType;
  }

  // video and audio combined formats
  static readonly MPEG_4: MediaFormat = new MediaFormat(0x0, 'MPEG-4', 'mp4', 'video/mp4');
  static readonly v3GPP: MediaFormat = new MediaFormat(0x10, '3GPP', '3gp', 'video/3gpp');
  static readonly WEBM: MediaFormat = new MediaFormat(0x20, 'WebM', 'webm', 'video/webm');
  // audio formats
  static readonly M4A: MediaFormat = new MediaFormat(0x100, 'm4a', 'm4a', 'audio/mp4');
  static readonly WEBMA: MediaFormat = new MediaFormat(0x200, 'WebM', 'webm', 'audio/webm');
  static readonly MP3: MediaFormat = new MediaFormat(0x300, 'MP3', 'mp3', 'audio/mpeg');
  static readonly MP2: MediaFormat = new MediaFormat(0x310, 'MP2', 'mp2', 'audio/mpeg');
  static readonly OPUS: MediaFormat = new MediaFormat(0x400, 'opus', 'opus', 'audio/opus');
  static readonly OGG: MediaFormat = new MediaFormat(0x500, 'ogg', 'ogg', 'audio/ogg');
  static readonly WEBMA_OPUS: MediaFormat =
    new MediaFormat(0x200, 'WebM Opus', 'webm', 'audio/webm');
  static readonly AIFF: MediaFormat = new MediaFormat(0x600, 'AIFF', 'aiff', 'audio/aiff');
  /** Same as AIFF, just with the shorter suffix/file extension. */
  static readonly AIF: MediaFormat = new MediaFormat(0x600, 'AIFF', 'aif', 'audio/aiff');
  static readonly WAV: MediaFormat = new MediaFormat(0x700, 'WAV', 'wav', 'audio/wav');
  static readonly FLAC: MediaFormat = new MediaFormat(0x800, 'FLAC', 'flac', 'audio/flac');
  static readonly ALAC: MediaFormat = new MediaFormat(0x900, 'ALAC', 'alac', 'audio/alac');
  // subtitles formats
  static readonly VTT: MediaFormat = new MediaFormat(0x1000, 'WebVTT', 'vtt', 'text/vtt');
  static readonly TTML: MediaFormat =
    new MediaFormat(0x2000, 'Timed Text Markup Language', 'ttml', 'application/ttml+xml');
  static readonly TRANSCRIPT1: MediaFormat =
    new MediaFormat(0x3000, 'TranScript v1', 'srv1', 'text/xml');
  static readonly TRANSCRIPT2: MediaFormat =
    new MediaFormat(0x4000, 'TranScript v2', 'srv2', 'text/xml');
  static readonly TRANSCRIPT3: MediaFormat =
    new MediaFormat(0x5000, 'TranScript v3', 'srv3', 'text/xml');
  static readonly SRT: MediaFormat =
    new MediaFormat(0x6000, 'SubRip file format', 'srt', 'text/srt');

  private static readonly VALUES: MediaFormat[] = [
    MediaFormat.MPEG_4, MediaFormat.v3GPP, MediaFormat.WEBM,
    MediaFormat.M4A, MediaFormat.WEBMA, MediaFormat.MP3, MediaFormat.MP2, MediaFormat.OPUS,
    MediaFormat.OGG, MediaFormat.WEBMA_OPUS, MediaFormat.AIFF, MediaFormat.AIF, MediaFormat.WAV,
    MediaFormat.FLAC, MediaFormat.ALAC,
    MediaFormat.VTT, MediaFormat.TTML, MediaFormat.TRANSCRIPT1, MediaFormat.TRANSCRIPT2,
    MediaFormat.TRANSCRIPT3, MediaFormat.SRT
  ];

  static values(): MediaFormat[] {
    return MediaFormat.VALUES;
  }

  private static byId(id: number): MediaFormat | null {
    for (const format of MediaFormat.VALUES) {
      if (format.id === id) {
        return format;
      }
    }
    return null;
  }

  /** The friendly name of the format with this id, or an empty string if none match it. */
  static getNameById(id: number): string {
    const format: MediaFormat | null = MediaFormat.byId(id);
    return format === null ? '' : format.name;
  }

  /** The file extension of the format with this id, or an empty string if none match it. */
  static getSuffixById(id: number): string {
    const format: MediaFormat | null = MediaFormat.byId(id);
    return format === null ? '' : format.suffix;
  }

  /** The MIME type of the format with this id, or null if none match it. */
  static getMimeById(id: number): string | null {
    const format: MediaFormat | null = MediaFormat.byId(id);
    return format === null ? null : format.mimeType;
  }

  /** The first format with this mime type; there may be more, see getAllFromMimeType. */
  static getFromMimeType(mimeType: string): MediaFormat | null {
    for (const format of MediaFormat.VALUES) {
      if (format.mimeType === mimeType) {
        return format;
      }
    }
    return null;
  }

  /** Every format that has the given mime type. */
  static getAllFromMimeType(mimeType: string): MediaFormat[] {
    const matches: MediaFormat[] = [];
    for (const format of MediaFormat.VALUES) {
      if (format.mimeType === mimeType) {
        matches.push(format);
      }
    }
    return matches;
  }

  static getFormatById(id: number): MediaFormat | null {
    return MediaFormat.byId(id);
  }

  /** The first format that has the given suffix / file extension. */
  static getFromSuffix(suffix: string): MediaFormat | null {
    for (const format of MediaFormat.VALUES) {
      if (format.suffix === suffix) {
        return format;
      }
    }
    return null;
  }

  getName(): string {
    return this.name;
  }

  getSuffix(): string {
    return this.suffix;
  }

  getMimeType(): string {
    return this.mimeType;
  }
}
