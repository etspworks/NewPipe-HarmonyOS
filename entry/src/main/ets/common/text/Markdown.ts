/*
 * Port of io.noties.markwon:core 4.6.2 (vendored at input/source/Markwon).
 *
 * Markwon core is two halves: a CommonMark parse, and CorePlugin's visitors turning that AST into
 * Android spans. The parse half is commonmark-java, a separate artifact that is NOT vendored with
 * Markwon and has no source on disk; the span half is Android-only. So this module carries both
 * halves in the shape HarmonyOS needs: markdown in, styled runs out, one block per source block.
 *
 * The node set is exactly the one CorePlugin registers a visitor for — Text, StrongEmphasis,
 * Emphasis, BlockQuote, Code, FencedCodeBlock, IndentedCodeBlock, Image, ListItem (bullet and
 * ordered), ThematicBreak, Heading, SoftLineBreak, HardLineBreak, Paragraph and Link — because a
 * node CorePlugin does not visit renders as plain text in the source too.
 *
 * KNOWN CEILING: this is a CommonMark SUBSET, not the full grammar. Setext headings, reference
 * links, nested block containers deeper than one level, HTML blocks and tables (a separate
 * Markwon module the app does not use) are rendered as their literal text rather than parsed.
 * NewPipe feeds it stream and channel descriptions, which is what the subset covers.
 */

import { LinkSpan, linkifyAll } from './Linkify';

export enum MarkdownBlockKind {
  PARAGRAPH,
  HEADING,
  CODE_BLOCK,
  BLOCK_QUOTE,
  BULLET_ITEM,
  ORDERED_ITEM,
  THEMATIC_BREAK
}

/** One styled run of text. The styles are cumulative, as the nested inline nodes are. */
export class MarkdownSpan {
  readonly text: string;
  readonly bold: boolean;
  readonly italic: boolean;
  readonly code: boolean;
  /** The href of a link node, or null. */
  readonly linkUrl: string | null;
  /** The src of an image node, in which case `text` is its alt text. */
  readonly imageUrl: string | null;

  constructor(text: string, bold: boolean = false, italic: boolean = false, code: boolean = false,
    linkUrl: string | null = null, imageUrl: string | null = null) {
    this.text = text;
    this.bold = bold;
    this.italic = italic;
    this.code = code;
    this.linkUrl = linkUrl;
    this.imageUrl = imageUrl;
  }
}

export class MarkdownBlock {
  readonly kind: MarkdownBlockKind;
  /** Heading level 1..6, or the ordinal of an ordered list item; 0 otherwise. */
  readonly level: number;
  readonly spans: MarkdownSpan[];
  /** The info string of a fenced code block, e.g. `json`; empty otherwise. */
  readonly language: string;

  constructor(kind: MarkdownBlockKind, level: number, spans: MarkdownSpan[],
    language: string = '') {
    this.kind = kind;
    this.level = level;
    this.spans = spans;
    this.language = language;
  }

  text(): string {
    let out: string = '';
    for (const span of this.spans) {
      out += span.text;
    }
    return out;
  }
}

export class MarkdownDocument {
  readonly blocks: MarkdownBlock[];

  constructor(blocks: MarkdownBlock[]) {
    this.blocks = blocks;
  }

  /** The rendered text with no styling, one line per block — what a plain TextArea shows. */
  toPlainText(): string {
    const lines: string[] = [];
    for (const block of this.blocks) {
      if (block.kind === MarkdownBlockKind.THEMATIC_BREAK) {
        lines.push('———');
      } else {
        lines.push(block.text());
      }
    }
    return lines.join('\n');
  }

  /**
   * The links this document declares, as ranges into toPlainText(); the LinkifyPlugin pass in
   * the source runs over the rendered text in exactly the same way.
   */
  links(): LinkSpan[] {
    return linkifyAll(this.toPlainText(), []);
  }
}

const THEMATIC_BREAK: RegExp = /^ {0,3}([-*_])(?:\s*\1){2,}\s*$/;
const HEADING: RegExp = /^ {0,3}(#{1,6})(?:\s+(.*?))?\s*#*\s*$/;
const FENCE: RegExp = /^ {0,3}(`{3,}|~{3,})\s*(\S*)\s*$/;
const BULLET_ITEM: RegExp = /^ {0,3}[-*+]\s+(.*)$/;
const ORDERED_ITEM: RegExp = /^ {0,3}(\d{1,9})[.)]\s+(.*)$/;
const BLOCK_QUOTE: RegExp = /^ {0,3}>\s?(.*)$/;
const INDENTED_CODE: RegExp = /^(?: {4}|\t)(.*)$/;

/** Port of Markwon.toMarkdown(): parse the markdown and render it to styled blocks. */
export function parseMarkdown(markdown: string): MarkdownDocument {
  const blocks: MarkdownBlock[] = [];
  const lines: string[] = markdown.replace(/\r\n/g, '\n').replace(/\r/g, '\n').split('\n');

  let index: number = 0;
  let paragraph: string[] = [];

  const flushParagraph = (): void => {
    if (paragraph.length > 0) {
      // A soft line break renders as a space, which is commonmark's own default and the reason
      // Markwon ships SoftBreakAddsNewLinePlugin for apps that want otherwise.
      blocks.push(new MarkdownBlock(MarkdownBlockKind.PARAGRAPH, 0,
        parseInline(paragraph.join(' '))));
      paragraph = [];
    }
  };

  while (index < lines.length) {
    const line: string = lines[index];

    if (line.trim().length === 0) {
      flushParagraph();
      index++;
      continue;
    }

    const fence: RegExpExecArray | null = FENCE.exec(line);
    if (fence !== null) {
      flushParagraph();
      const marker: string = fence[1].charAt(0);
      const language: string = fence[2];
      const body: string[] = [];
      index++;
      while (index < lines.length) {
        const closing: RegExpExecArray | null = FENCE.exec(lines[index]);
        if (closing !== null && closing[1].charAt(0) === marker) {
          index++;
          break;
        }
        body.push(lines[index]);
        index++;
      }
      blocks.push(new MarkdownBlock(MarkdownBlockKind.CODE_BLOCK, 0,
        [new MarkdownSpan(body.join('\n'), false, false, true)], language));
      continue;
    }

    if (THEMATIC_BREAK.test(line)) {
      flushParagraph();
      blocks.push(new MarkdownBlock(MarkdownBlockKind.THEMATIC_BREAK, 0, []));
      index++;
      continue;
    }

    const heading: RegExpExecArray | null = HEADING.exec(line);
    if (heading !== null) {
      flushParagraph();
      const content: string = heading[2] === undefined ? '' : heading[2];
      blocks.push(new MarkdownBlock(MarkdownBlockKind.HEADING, heading[1].length,
        parseInline(content)));
      index++;
      continue;
    }

    const quote: RegExpExecArray | null = BLOCK_QUOTE.exec(line);
    if (quote !== null) {
      flushParagraph();
      const quoted: string[] = [quote[1]];
      index++;
      while (index < lines.length) {
        const next: RegExpExecArray | null = BLOCK_QUOTE.exec(lines[index]);
        if (next === null) {
          break;
        }
        quoted.push(next[1]);
        index++;
      }
      blocks.push(new MarkdownBlock(MarkdownBlockKind.BLOCK_QUOTE, 0,
        parseInline(quoted.join(' '))));
      continue;
    }

    const bullet: RegExpExecArray | null = BULLET_ITEM.exec(line);
    if (bullet !== null) {
      flushParagraph();
      blocks.push(new MarkdownBlock(MarkdownBlockKind.BULLET_ITEM, 0, parseInline(bullet[1])));
      index++;
      continue;
    }

    const ordered: RegExpExecArray | null = ORDERED_ITEM.exec(line);
    if (ordered !== null) {
      flushParagraph();
      blocks.push(new MarkdownBlock(MarkdownBlockKind.ORDERED_ITEM,
        Number.parseInt(ordered[1], 10), parseInline(ordered[2])));
      index++;
      continue;
    }

    // An indented code block only starts where a paragraph is not already open, as in CommonMark.
    const indented: RegExpExecArray | null = INDENTED_CODE.exec(line);
    if (indented !== null && paragraph.length === 0) {
      const body: string[] = [indented[1]];
      index++;
      while (index < lines.length) {
        const next: RegExpExecArray | null = INDENTED_CODE.exec(lines[index]);
        if (next === null) {
          break;
        }
        body.push(next[1]);
        index++;
      }
      blocks.push(new MarkdownBlock(MarkdownBlockKind.CODE_BLOCK, 0,
        [new MarkdownSpan(body.join('\n'), false, false, true)]));
      continue;
    }

    // A hard line break is a line ending in two spaces or a backslash.
    if (line.endsWith('  ') || line.endsWith('\\')) {
      paragraph.push(line.endsWith('\\') ? line.substring(0, line.length - 1).trim() : line.trim());
      flushParagraph();
      index++;
      continue;
    }

    paragraph.push(line.trim());
    index++;
  }
  flushParagraph();

  return new MarkdownDocument(blocks);
}

const IMAGE: RegExp = /^!\[([^\]]*)\]\(([^)\s]+)(?:\s+"[^"]*")?\)/;
const LINK: RegExp = /^\[([^\]]*)\]\(([^)\s]+)(?:\s+"[^"]*")?\)/;
const AUTOLINK: RegExp = /^<((?:https?|mailto):[^>\s]+)>/;

/** The inline half of CorePlugin's visitors, over one block's text. */
export function parseInline(text: string): MarkdownSpan[] {
  const spans: MarkdownSpan[] = [];
  let plain: string = '';
  let index: number = 0;

  const flushPlain = (bold: boolean, italic: boolean): void => {
    if (plain.length > 0) {
      spans.push(new MarkdownSpan(plain, bold, italic));
      plain = '';
    }
  };

  let bold: boolean = false;
  let italic: boolean = false;

  while (index < text.length) {
    const rest: string = text.substring(index);
    const ch: string = text.charAt(index);

    if (ch === '\\' && index + 1 < text.length) {
      // A backslash escape is the next character, literally.
      plain += text.charAt(index + 1);
      index += 2;
      continue;
    }

    if (ch === '`') {
      const closing: number = text.indexOf('`', index + 1);
      if (closing > index) {
        flushPlain(bold, italic);
        spans.push(new MarkdownSpan(text.substring(index + 1, closing), bold, italic, true));
        index = closing + 1;
        continue;
      }
    }

    const image: RegExpExecArray | null = IMAGE.exec(rest);
    if (image !== null) {
      flushPlain(bold, italic);
      spans.push(new MarkdownSpan(image[1], bold, italic, false, null, image[2]));
      index += image[0].length;
      continue;
    }

    const link: RegExpExecArray | null = LINK.exec(rest);
    if (link !== null) {
      flushPlain(bold, italic);
      const label: string = link[1].length > 0 ? link[1] : link[2];
      spans.push(new MarkdownSpan(label, bold, italic, false, link[2]));
      index += link[0].length;
      continue;
    }

    const autolink: RegExpExecArray | null = AUTOLINK.exec(rest);
    if (autolink !== null) {
      flushPlain(bold, italic);
      spans.push(new MarkdownSpan(autolink[1], bold, italic, false, autolink[1]));
      index += autolink[0].length;
      continue;
    }

    if (rest.startsWith('**') || rest.startsWith('__')) {
      flushPlain(bold, italic);
      bold = !bold;
      index += 2;
      continue;
    }

    if (ch === '*' || ch === '_') {
      flushPlain(bold, italic);
      italic = !italic;
      index++;
      continue;
    }

    plain += ch;
    index++;
  }

  flushPlain(bold, italic);
  return spans;
}
