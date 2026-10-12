/*
 * Port of io.noties.markwon:linkify 4.6.2 (LinkifyPlugin, vendored at input/source/Markwon),
 * together with the two extra span kinds NewPipe's own TextLinkifier adds on top of it:
 * hashtags and timestamps.
 *
 * LinkifyPlugin is a thin wrapper over android.text.util.Linkify: after Markwon renders the
 * markdown it runs Linkify over the result and turns bare text into URLSpans. There is no
 * android.text here, so this module produces the descriptors instead — start/end plus what the
 * link points at — and the UI (Phase 3) attaches the gestures:
 *   WEB_URL   -> open in the browser / RouterActivity equivalent
 *   EMAIL     -> mailto:
 *   HASHTAG   -> search the hashtag on the stream's own service
 *   TIMESTAMP -> seek the player to that position
 *
 * Priority and overlap follow TextLinkifier.changeLinkIntents(): explicit links first, then
 * timestamps, then hashtags, and a hashtag that overlaps an existing link is skipped.
 *
 * KNOWN CEILING: LinkifyPlugin.create() also enables Linkify.PHONE_NUMBERS, which on Android is
 * matched by libphonenumber against the device region. There is no such matcher here, and a
 * naive digit regex would swallow the timestamps this same text depends on, so phone numbers are
 * NOT linkified. Nothing else in the mask is dropped.
 */

export enum LinkKind {
  WEB_URL,
  EMAIL,
  HASHTAG,
  TIMESTAMP
}

export class LinkSpan {
  readonly kind: LinkKind;
  /** Index of the first character of the link inside the text it was found in. */
  readonly start: number;
  /** Index one past its last character. */
  readonly end: number;
  readonly text: string;
  /** The url to open, for WEB_URL and EMAIL; null for the two in-app kinds. */
  readonly url: string | null;
  /** The position to seek to, for TIMESTAMP; null otherwise. */
  readonly seconds: number | null;

  constructor(kind: LinkKind, start: number, end: number, text: string, url: string | null,
    seconds: number | null) {
    this.kind = kind;
    this.start = start;
    this.end = end;
    this.text = text;
    this.url = url;
    this.seconds = seconds;
  }
}

// A bare url, with or without a scheme, as Linkify.WEB_URLS matches one.
const WEB_URL_PATTERN: RegExp =
  /(?:https?:\/\/|www\.)[-\w@:%.+~#=]{1,256}\.[a-z]{2,24}\b(?:[-\w()@:%+.~#?&/=,;!$'*]*[-\w()@%+~#?&/=$*])?/gi;
const EMAIL_PATTERN: RegExp = /[\w.+-]+@[\w-]+(?:\.[\w-]+)+/g;
/** Hashtags with characters from any language, numbers or underscores (TextLinkifier). */
const HASHTAG_PATTERN: RegExp = /(#[\p{L}0-9_]+)/gu;
/** TimestampExtractor.TIMESTAMPS_PATTERN, verbatim. */
const TIMESTAMP_PATTERN: RegExp =
  /(?:^|(?!:)\W)(?:([0-5]?[0-9]):)?([0-5]?[0-9]):([0-5][0-9])(?=$|(?!:)\W)/g;

function overlaps(spans: LinkSpan[], start: number, end: number): boolean {
  for (const span of spans) {
    if (start < span.end && span.start < end) {
      return true;
    }
  }
  return false;
}

/**
 * Port of TimestampExtractor.getTimestampFromMatcher(): the seconds a `[hh:]mm:ss` match means,
 * or null when the match has neither two nor three parts.
 */
export function timestampSeconds(parsedTimestamp: string): number | null {
  const parts: string[] = parsedTimestamp.split(':');
  if (parts.length === 3) {
    return Number.parseInt(parts[0], 10) * 3600 + Number.parseInt(parts[1], 10) * 60
      + Number.parseInt(parts[2], 10);
  }
  if (parts.length === 2) {
    return Number.parseInt(parts[0], 10) * 60 + Number.parseInt(parts[1], 10);
  }
  return null;
}

/**
 * Every link in `text`, in priority order and never overlapping. `existing` are links the
 * markdown itself already declared, which keep their range.
 */
export function linkify(text: string, kinds: LinkKind[],
  existing: LinkSpan[] = []): LinkSpan[] {
  const spans: LinkSpan[] = [];
  for (const span of existing) {
    spans.push(span);
  }

  if (kinds.includes(LinkKind.WEB_URL)) {
    WEB_URL_PATTERN.lastIndex = 0;
    let match: RegExpExecArray | null = WEB_URL_PATTERN.exec(text);
    while (match !== null) {
      const start: number = match.index;
      const end: number = start + match[0].length;
      if (!overlaps(spans, start, end)) {
        const raw: string = match[0];
        const url: string = raw.startsWith('www.') ? 'https://' + raw : raw;
        spans.push(new LinkSpan(LinkKind.WEB_URL, start, end, raw, url, null));
      }
      match = WEB_URL_PATTERN.exec(text);
    }
  }

  if (kinds.includes(LinkKind.EMAIL)) {
    EMAIL_PATTERN.lastIndex = 0;
    let match: RegExpExecArray | null = EMAIL_PATTERN.exec(text);
    while (match !== null) {
      const start: number = match.index;
      const end: number = start + match[0].length;
      if (!overlaps(spans, start, end)) {
        spans.push(new LinkSpan(LinkKind.EMAIL, start, end, match[0], 'mailto:' + match[0], null));
      }
      match = EMAIL_PATTERN.exec(text);
    }
  }

  if (kinds.includes(LinkKind.TIMESTAMP)) {
    TIMESTAMP_PATTERN.lastIndex = 0;
    let match: RegExpExecArray | null = TIMESTAMP_PATTERN.exec(text);
    while (match !== null) {
      // The match may begin on the separator before the timestamp (the source reads group 1 or
      // group 2 for the same reason), so skip forward to the first digit.
      const wholeStart: number = match.index;
      const matched: string = match[0];
      const firstDigit: number = matched.search(/\d/);
      const start: number = wholeStart + (firstDigit < 0 ? 0 : firstDigit);
      const end: number = wholeStart + matched.length;
      const parsed: string = text.substring(start, end);
      const seconds: number | null = timestampSeconds(parsed);
      if (seconds !== null && !overlaps(spans, start, end)) {
        spans.push(new LinkSpan(LinkKind.TIMESTAMP, start, end, parsed, null, seconds));
      }
      match = TIMESTAMP_PATTERN.exec(text);
    }
  }

  if (kinds.includes(LinkKind.HASHTAG)) {
    HASHTAG_PATTERN.lastIndex = 0;
    let match: RegExpExecArray | null = HASHTAG_PATTERN.exec(text);
    while (match !== null) {
      const start: number = match.index;
      const end: number = start + match[0].length;
      // Do not add a hashtag span where a link already is, as TextLinkifier does not either.
      if (!overlaps(spans, start, end)) {
        spans.push(new LinkSpan(LinkKind.HASHTAG, start, end, match[0], null, null));
      }
      match = HASHTAG_PATTERN.exec(text);
    }
  }

  spans.sort((a: LinkSpan, b: LinkSpan): number => a.start - b.start);
  return spans;
}

/** The mask LinkifyPlugin.create() uses, minus PHONE_NUMBERS; see the header note. */
export function linkifyAll(text: string, existing: LinkSpan[] = []): LinkSpan[] {
  return linkify(text, [LinkKind.WEB_URL, LinkKind.EMAIL, LinkKind.TIMESTAMP, LinkKind.HASHTAG],
    existing);
}
