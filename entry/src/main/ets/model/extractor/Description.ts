/*
 * Port of org.schabi.newpipe.extractor.stream.Description (NewPipeExtractor v0.26.5).
 *
 * `type` decides how the description is rendered: HTML, MARKDOWN (see common/text/Markdown.ts)
 * or PLAIN_TEXT.
 */

export const DESCRIPTION_HTML: number = 1;
export const DESCRIPTION_MARKDOWN: number = 2;
export const DESCRIPTION_PLAIN_TEXT: number = 3;

export class Description {
  readonly content: string;
  readonly type: number;

  constructor(content: string | null, type: number) {
    this.type = type;
    this.content = content === null ? '' : content;
  }

  static readonly EMPTY_DESCRIPTION: Description = new Description('', DESCRIPTION_PLAIN_TEXT);

  getContent(): string {
    return this.content;
  }

  getType(): number {
    return this.type;
  }

  equals(other: Description | null): boolean {
    return other !== null && this.type === other.type && this.content === other.content;
  }
}
