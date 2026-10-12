/*
 * The seam Stream / AudioStream / VideoStream need for org.schabi.newpipe.extractor.services
 * .youtube.ItagItem, which belongs to the YouTube service lane, not to this wave.
 *
 * Only the members the three stream classes read off an itag are declared. The YouTube lane's
 * ItagItem class must declare `implements ItagItem` from this module — ArkTS is nominally typed,
 * so a structurally identical class is NOT accepted.
 */

export interface ItagItem {
  readonly id: number;

  getQuality(): string;

  getBitrate(): number;

  getInitStart(): number;

  getInitEnd(): number;

  getIndexStart(): number;

  getIndexEnd(): number;

  getCodec(): string;

  getHeight(): number;

  getWidth(): number;

  getFps(): number;

  /** The size the extractor already read off the itag, or CONTENT_LENGTH_UNKNOWN. */
  getContentLength(): number;
}
