/*
 * Port of org.schabi.newpipe.extractor.services.youtube.YoutubeDescriptionHelper
 * (NewPipeExtractor v0.26.5).
 *
 * Turns YouTube's `attributedDescription` (plain text plus index-range command/style runs) into
 * HTML, reopening runs that a mis-nested close would otherwise break.
 *
 * Java's Stack/StringBuilder become an array used as a stack and a string; `Function<String,
 * String>` becomes an arrow function (ArkTS allows arrows, not `function` expressions).
 * `String.replaceFirst` becomes replace() with a non-global RegExp, which is the same semantics.
 */

import { JsonObject } from '../../json/NanoJson';
import { Entities } from '../../html/Jsoup';
import { stringToURL } from '../../core/Utils';
import { getUrlFromNavigationEndpoint, isYoutubeServiceURL, isYoutubeURL } from './YoutubeParsingHelper';
import { url as ohosUrl } from '@kit.ArkTS';

const LINK_CLOSE: string = '</a>';
const STRIKETHROUGH_OPEN: string = '<s>';
const STRIKETHROUGH_CLOSE: string = '</s>';
const BOLD_OPEN: string = '<b>';
const BOLD_CLOSE: string = '</b>';
const ITALIC_OPEN: string = '<i>';
const ITALIC_CLOSE: string = '</i>';

/**
 * Special link chips (YT videos, YT channels, social media accounts) render as
 * `(u00a0) u00a0 u00a0 [/•] u00a0 <link content> u00a0 u00a0`; this strips the decoration.
 * Java's `(?s)` DOTALL becomes the `s` flag.
 */
const LINK_CONTENT_CLEANER_REGEX: RegExp = new RegExp('^ +[/•] +(.*?) +$', 's');

/** One opener/closer half of a formatting run over the raw description text. */
export class Run {
  readonly open: string;
  readonly close: string;
  readonly pos: number;
  readonly transformContent: ((content: string) => string) | null;
  openPosInOutput: number = -1;

  constructor(open: string, close: string, pos: number,
    transformContent: ((content: string) => string) | null = null) {
    this.open = open;
    this.close = close;
    this.pos = pos;
    this.transformContent = transformContent;
  }

  sameOpen(other: Run): boolean {
    return this.open === other.open;
  }
}

export function attributedDescriptionToHtml(
  attributedDescription: JsonObject | null): string | null {
  if (attributedDescription === null || attributedDescription.size() === 0) {
    return null;
  }
  const content: string | null = attributedDescription.getString('content');
  if (content === null) {
    return null;
  }

  // Every run pair must have length at least 1 or be discarded, otherwise assumptions made in
  // runsToHtml may fail
  const openers: Run[] = [];
  const closers: Run[] = [];
  addAllCommandRuns(attributedDescription, openers, closers);
  addAllStyleRuns(attributedDescription, openers, closers);

  // Sorting this way can put closers with the same close position in the wrong order relative to
  // their openers, causing an unnecessary close and reopen. E.g. <b>b<i>b&i</i></b> comes out as
  // <b>b<i>b&i</b></i><b></b> when the </b> is seen before the </i>. Solving that would need extra
  // sorting steps that would slow down the common case, so the source leaves it — as does this.
  openers.sort((a: Run, b: Run): number => a.pos - b.pos);
  closers.sort((a: Run, b: Run): number => a.pos - b.pos);

  return runsToHtml(openers, closers, content);
}

export function runsToHtml(openers: Run[], closers: Run[], rawContent: string): string {
  const content: string = rawContent.replace(new RegExp(' ', 'g'), ' ');
  const openRuns: Run[] = [];
  const tempStack: Run[] = [];
  let textBuilder: string = '';

  let currentTextPos: number = 0;
  let openersIndex: number = 0;
  let closersIndex: number = 0;

  // openers and closers have the same length, but openers always finishes first: every opened
  // interval has to close and no interval is empty, so only closersIndex needs checking
  while (closersIndex < closers.length) {
    const minPos: number = openersIndex < openers.length
      ? Math.min(closers[closersIndex].pos, openers[openersIndex].pos)
      : closers[closersIndex].pos;

    // append the piece of text up to the current index
    textBuilder += Entities.escape(content.substring(currentTextPos, minPos));
    currentTextPos = minPos;

    if (closers[closersIndex].pos === minPos) {
      // on a position tie, closers are processed first
      const closer: Run = closers[closersIndex];
      closersIndex++;

      // by the assumptions this loop would not need the emptiness check, since nothing closes
      // before it opens, but the source keeps it and so does this
      while (openRuns.length > 0) {
        const popped: Run = openRuns.pop() as Run;
        if (popped.sameOpen(closer)) {
          // before closing, run the transformContent function over everything written since the
          // run was opened
          if (popped.transformContent !== null && popped.openPosInOutput >= 0) {
            const transform: (content: string) => string = popped.transformContent;
            textBuilder = textBuilder.substring(0, popped.openPosInOutput)
              + transform(textBuilder.substring(popped.openPosInOutput));
          }
          textBuilder += popped.close;
          break;
        }
        // keep popping and closing until the run that really needs closing turns up ...
        textBuilder += popped.close;
        tempStack.push(popped);
      }

      while (tempStack.length > 0) {
        // ... then reopen everything that did not need closing, e.g. in <b>b<i>b&i</b>i</i> the
        // </b> prints </i></b><i>, giving the valid <b>b<i>b&i</i></b><i>i</i>
        const popped: Run = tempStack.pop() as Run;
        textBuilder += popped.open;
        openRuns.push(popped);
      }
    } else {
      // unreachable when openersIndex >= openers.length, by how minPos is computed
      const opener: Run = openers[openersIndex];
      textBuilder += opener.open;
      opener.openPosInOutput = textBuilder.length; // saved for transforming on close
      openRuns.push(opener);
      openersIndex++;
    }
  }

  // append the last piece of text
  textBuilder += Entities.escape(content.substring(currentTextPos));

  return textBuilder
    .replace(new RegExp('\n', 'g'), '<br>')
    .replace(new RegExp('  ', 'g'), ' &nbsp;');
}

function addAllCommandRuns(attributedDescription: JsonObject, openers: Run[],
  closers: Run[]): void {
  for (const run of attributedDescription.getArray('commandRuns').streamAsJsonObjects()) {
    const navigationEndpoint: JsonObject = run.getObject('onTap').getObject('innertubeCommand');
    const startIndex: number = run.getInt('startIndex', -1);
    const length: number = run.getInt('length', 0);
    if (startIndex < 0 || length < 1 || navigationEndpoint.size() === 0) {
      continue;
    }

    const url: string | null = getUrlFromNavigationEndpoint(navigationEndpoint);
    if (url === null) {
      continue;
    }

    let isYoutubeUrl: boolean;
    try {
      const parsedUrl: ohosUrl.URL = stringToURL(url);
      isYoutubeUrl = isYoutubeURL(parsedUrl) || isYoutubeServiceURL(parsedUrl);
    } catch (ignored) {
      // should never happen; treat it as a generic URL, as the source does
      isYoutubeUrl = false;
    }

    const open: string = '<a href="' + Entities.escape(url) + '">';
    const transformContent: (content: string) => string = getTransformContentFun(run, isYoutubeUrl);
    openers.push(new Run(open, LINK_CLOSE, startIndex, transformContent));
    closers.push(new Run(open, LINK_CLOSE, startIndex + length, transformContent));
  }
}

function getTransformContentFun(run: JsonObject, isYoutube: boolean):
  (content: string) => string {
  // accessibility labels look like "Instagram Channel Link: instagram_profile_name"
  const accessibilityLabel: string = (run.getObject('onTapOptions')
    .getObject('accessibilityInfo')
    .getString('accessibilityLabel', '') as string)
    .replace(new RegExp(' Channel Link'), '');

  if (isYoutube || accessibilityLabel.length === 0
    || accessibilityLabel.startsWith('YouTube: ')) {
    // with no accessibility label, or a link pointing at YouTube, clean up the link text — see
    // LINK_CONTENT_CLEANER_REGEX above
    return (content: string): string => {
      LINK_CONTENT_CLEANER_REGEX.lastIndex = 0;
      const m: RegExpExecArray | null = LINK_CONTENT_CLEANER_REGEX.exec(content);
      return m === null ? content : m[1];
    };
  }
  // with an accessibility label, replace the link text with it: the YouTube website puts an icon
  // next to an ambiguous link text saying which service it belongs to, and the label carries the
  // same information, which an icon here could not
  return (content: string): string => accessibilityLabel;
}

function addAllStyleRuns(attributedDescription: JsonObject, openers: Run[],
  closers: Run[]): void {
  for (const run of attributedDescription.getArray('styleRuns').streamAsJsonObjects()) {
    const start: number = run.getInt('startIndex', -1);
    const length: number = run.getInt('length', 0);
    if (start < 0 || length < 1) {
      continue;
    }
    const end: number = start + length;

    if (run.has('strikethrough')) {
      openers.push(new Run(STRIKETHROUGH_OPEN, STRIKETHROUGH_CLOSE, start));
      closers.push(new Run(STRIKETHROUGH_OPEN, STRIKETHROUGH_CLOSE, end));
    }
    if (run.getBoolean('italic', false)) {
      openers.push(new Run(ITALIC_OPEN, ITALIC_CLOSE, start));
      closers.push(new Run(ITALIC_OPEN, ITALIC_CLOSE, end));
    }
    if (run.has('weightLabel') && run.getString('weightLabel') !== 'FONT_WEIGHT_NORMAL') {
      openers.push(new Run(BOLD_OPEN, BOLD_CLOSE, start));
      closers.push(new Run(BOLD_OPEN, BOLD_CLOSE, end));
    }
  }
}
