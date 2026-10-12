/*
 * Port of org.schabi.newpipe.streams.SrtFromTtmlWriter: TTML subtitles to SubRip (.srt).
 *
 * The source parses the TTML with jsoup's XML parser and selects "body > div > p". Jsoup.ts's XML
 * mode is not used for that tree: it turns a whitespace-only text run into one space where jsoup
 * keeps it verbatim (a "\n" between two <span>s is a line break in the SRT), lower-cases end tags
 * before matching them, and reads a stray "<" as a tag. selectParagraphs() builds just the tree
 * this class reads, by jsoup 1.22.2's Tokeniser + XmlTreeBuilder rules. Character references
 * still go through Jsoup.ts's port of Parser.unescapeEntities, in the parse and in
 * decodeXmlEntities(), as in the source.
 */

import { util } from '@kit.ArkTS';
import { Parser } from '../../extractor/html/Jsoup';
import { SharpStream } from './SharpStream';

const NEW_LINE: string = '\r\n';

/** nodeName() of a text node; no tag name can start with '#'. */
const TEXT: string = '#text';

/** An element of the parsed TTML, or a text node when `name` is TEXT. */
class TtmlNode {
  readonly name: string;
  readonly text: string;
  readonly attributes: Map<string, string>;
  readonly children: TtmlNode[] = [];

  constructor(name: string, text: string, attributes: Map<string, string>) {
    this.name = name;
    this.text = text;
    this.attributes = attributes;
  }

  /** Node.attr(): the first attribute whose name matches ignoring case, else ''. */
  attr(key: string): string {
    const wanted: string = key.toLowerCase();
    for (const name of this.attributes.keys()) {
      if (name.toLowerCase() === wanted) {
        const value: string | undefined = this.attributes.get(name);
        return value === undefined ? '' : value;
      }
    }
    return '';
  }
}

/** A start or end tag as readTag() found it. */
class Tag {
  name: string = '';
  readonly attributes: Map<string, string> = new Map<string, string>();
  selfClosing: boolean = false;
  /** Index just past its '>'. */
  end: number = 0;
}

function isSpace(ch: string): boolean {
  return ch === ' ' || ch === '\t' || ch === '\n' || ch === '\r' || ch === '\f';
}

function isAsciiLetter(ch: string): boolean {
  return (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z');
}

/** Where a tag or attribute name stops. */
function endsName(ch: string): boolean {
  return isSpace(ch) || ch === '/' || ch === '>';
}

/**
 * Reads the tag whose name starts at `from` (just past "<" or "</") the way the Tokeniser's tag
 * states do. Null when the input ends inside it: jsoup drops such a tag.
 */
function readTag(xml: string, from: number): Tag | null {
  const length: number = xml.length;
  const tag: Tag = new Tag();
  let i: number = from;
  while (i < length && !endsName(xml[i])) {
    i++;
  }
  tag.name = xml.substring(from, i);
  while (i < length) {
    const ch: string = xml[i];
    if (isSpace(ch)) {
      i++;
    } else if (ch === '>') {
      tag.end = i + 1;
      return tag;
    } else if (ch === '/') {
      i++; // "/>" self-closes; a '/' anywhere else is skipped
      if (i < length && xml[i] === '>') {
        tag.selfClosing = true;
        tag.end = i + 1;
        return tag;
      }
    } else {
      const nameStart: number = i;
      i++; // the first character belongs to the name even when it is '=' or a quote
      while (i < length && !endsName(xml[i]) && xml[i] !== '=') {
        i++;
      }
      const name: string = xml.substring(nameStart, i);
      while (i < length && isSpace(xml[i])) {
        i++;
      }
      let value: string = '';
      if (i < length && xml[i] === '=') {
        i++;
        while (i < length && isSpace(xml[i])) {
          i++;
        }
        const quote: string = i < length ? xml[i] : '';
        if (quote === '"' || quote === '\'') {
          const close: number = xml.indexOf(quote, i + 1);
          if (close < 0) {
            return null;
          }
          value = xml.substring(i + 1, close);
          i = close + 1;
        } else {
          const valueStart: number = i;
          while (i < length && !isSpace(xml[i]) && xml[i] !== '>') {
            i++;
          }
          value = xml.substring(valueStart, i);
        }
      }
      if (!tag.attributes.has(name)) { // Attributes.deduplicate(): the first one wins
        tag.attributes.set(name, Parser.unescapeEntities(value, true));
      }
    }
  }
  return null;
}

/**
 * doc.select("body > div > p") on the tree jsoup's XML parser builds from `xml`: each <p> whose
 * parent is a <div> whose parent is a <body> (names compared lower-cased), in document order.
 */
function selectParagraphs(xml: string): TtmlNode[] {
  const length: number = xml.length;
  const stack: TtmlNode[] = [new TtmlNode('#root', '', new Map<string, string>())];
  const paragraphs: TtmlNode[] = [];
  const appendText = (text: string): void => {
    stack[stack.length - 1].children.push(new TtmlNode(TEXT, text, new Map<string, string>()));
  };
  // Decoded text since the last token: jsoup makes the whole run one TextNode, verbatim.
  let pending: string = '';
  const flush = (): void => {
    if (pending.length > 0) {
      appendText(pending);
      pending = '';
    }
  };

  let i: number = 0;
  while (i < length) {
    const lt: number = xml.indexOf('<', i);
    const textEnd: number = lt < 0 ? length : lt;
    if (textEnd > i) {
      pending = pending + Parser.unescapeEntities(xml.substring(i, textEnd), false);
    }
    if (lt < 0) {
      break;
    }
    const next: string = lt + 1 < length ? xml[lt + 1] : '';
    const endTag: boolean = next === '/' && lt + 2 < length && isAsciiLetter(xml[lt + 2]);
    if (isAsciiLetter(next) || endTag) {
      const tag: Tag | null = readTag(xml, endTag ? lt + 2 : lt + 1);
      if (tag === null) {
        break;
      }
      flush();
      i = tag.end;
      if (endTag) {
        // popStackToClose(): to the nearest open element of exactly this name, if there is one
        for (let depth: number = stack.length - 1; depth > 0; depth--) {
          if (stack[depth].name === tag.name) {
            stack.length = depth;
            break;
          }
        }
      } else {
        const parent: TtmlNode = stack[stack.length - 1];
        const element: TtmlNode = new TtmlNode(tag.name, '', tag.attributes);
        parent.children.push(element);
        if (stack.length >= 3 && tag.name.toLowerCase() === 'p'
          && parent.name.toLowerCase() === 'div'
          && stack[stack.length - 2].name.toLowerCase() === 'body') {
          paragraphs.push(element);
        }
        if (!tag.selfClosing) {
          stack.push(element); // nothing is void in XML: a <br> without "/>" holds what follows
        }
      }
    } else if (xml.startsWith('<![CDATA[', lt)) {
      flush();
      const close: number = xml.indexOf(']]>', lt + 9);
      appendText(xml.substring(lt + 9, close < 0 ? length : close)); // raw, a TextNode of its own
      i = close < 0 ? length : close + 3;
    } else if (xml.startsWith('<!--', lt)) {
      flush();
      const close: number = xml.indexOf('-->', lt + 4);
      i = close < 0 ? length : close + 3;
    } else if (xml.startsWith('</>', lt)) {
      i = lt + 3; // dropped without a token: the text run goes on
    } else if (next === '!' || next === '?' || next === '/') {
      flush(); // <?xml ...?>, a doctype or a bogus comment: no text, but it ends the run
      const close: number = xml.indexOf('>', lt + 2);
      i = close < 0 ? length : close + 1;
    } else {
      pending = pending + '<'; // not markup: the Tokeniser emits it as text
      i = lt + 1;
    }
  }
  flush();
  return paragraphs;
}

export class SrtFromTtmlWriter {
  private readonly out: SharpStream;
  private readonly ignoreEmptyFrames: boolean;
  private readonly encoder: util.TextEncoder = new util.TextEncoder();
  // SubRip numbering starts at 1; some players accept 0 or less, the format does not.
  private frameIndex: number = 1;

  constructor(out: SharpStream, ignoreEmptyFrames: boolean) {
    this.out = out;
    this.ignoreEmptyFrames = ignoreEmptyFrames;
  }

  private static getTimestamp(frame: TtmlNode, attr: string): string {
    return frame.attr(attr).replace(/\./g, ','); // SRT uses a comma as the decimal separator
  }

  private writeFrame(begin: string, end: string, text: string): void {
    this.writeString(this.frameIndex.toString() + NEW_LINE + begin + ' --> ' + end + NEW_LINE
      + text + NEW_LINE + NEW_LINE);
    this.frameIndex += 1;
  }

  private writeString(text: string): void {
    this.out.write(this.encoder.encodeInto(text));
  }

  /**
   * Decodes the character references left in a text node. The parse already decoded once, so
   * this second pass resolves double-escaped ones too ("&amp;lt;" ends up "<"), as the source.
   */
  private decodeXmlEntities(encodedEntities: string): string {
    return Parser.unescapeEntities(encodedEntities, true);
  }

  /** "\r\n", "\r" and "\n" all become "\r\n" - in this order, or "\r\n" would double. */
  private normalizeLineBreakForSrt(text: string): string {
    return text.replace(/\r\n/g, '\n').replace(/\r/g, '\n').replace(/\n/g, NEW_LINE);
  }

  private normalizeForSrt(actualText: string): string {
    let cleaned: string = actualText;
    // NBSP, narrow no-break, medium mathematical, ideographic and the U+2000-U+200A spaces
    // render differently across players (MPlayer shows "??"); SRT only knows the plain space.
    cleaned = cleaned.replace(/[   　 - ]/g, ' ');
    // Zero-width characters (U+200B-U+200F) carry nothing in a subtitle.
    cleaned = cleaned.replace(/[​-‏]/g, '');
    // C0 controls other than \t \n \r are invisible and may show as boxes.
    cleaned = cleaned.replace(/[\u0000-\u0008\u000B\u000C\u000E-\u001F]/g, '');
    // A tab has no fixed width across players.
    cleaned = cleaned.replace(/\t/g, ' ');
    return this.normalizeLineBreakForSrt(cleaned);
  }

  private sanitizeFragment(raw: string): string {
    return this.normalizeForSrt(this.decodeXmlEntities(raw));
  }

  /** The text of `node` and everything below it (nested <span>s too); a <br> is a line break. */
  private extractText(node: TtmlNode): string {
    let text: string = '';
    if (node.name === TEXT) {
      text = this.sanitizeFragment(node.text);
    } else if (node.name.toLowerCase() === 'br') {
      text = NEW_LINE;
    }
    for (const child of node.children) {
      text = text + this.extractText(child);
    }
    return text;
  }

  build(ttml: SharpStream): void {
    // BASIC support, as in the source: one cue per <p>, no styling, no per-word tag timestamps
    // of auto-generated subtitles, no language.
    const buffer: Uint8Array = new Uint8Array(ttml.available());
    let filled: number = 0;
    while (filled < buffer.length) { // the source trusts a single read(buffer)
      const read: number = ttml.readInto(buffer, filled, buffer.length - filled);
      if (read <= 0) {
        break;
      }
      filled = filled + read;
    }
    const xml: string = util.TextDecoder.create('utf-8').decodeToString(buffer.subarray(0, filled));

    for (const paragraph of selectParagraphs(xml)) {
      const text: string = this.extractText(paragraph);
      if (this.ignoreEmptyFrames && text.length < 1) {
        continue;
      }
      this.writeFrame(SrtFromTtmlWriter.getTimestamp(paragraph, 'begin'),
        SrtFromTtmlWriter.getTimestamp(paragraph, 'end'), text);
    }
  }
}
