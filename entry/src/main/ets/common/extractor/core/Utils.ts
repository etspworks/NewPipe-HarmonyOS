/*
 * Port of org.schabi.newpipe.extractor.utils.Utils (NewPipeExtractor v0.26.5).
 *
 * ArkTS has no overloading, so Java's three isNullOrEmpty overloads become isNullOrEmpty (string),
 * isListNullOrEmpty and isMapNullOrEmpty, and the four getStringResultFromRegexArray overloads
 * become one that takes RegExp[] plus an explicit group.
 */

import { url as ohosUrl } from '@kit.ArkTS';
import { ParsingException } from '../exceptions/Exceptions';
import { Parser, RegexException } from './Parser';

export const HTTP: string = 'http://';
export const HTTPS: string = 'https://';

const M_PATTERN: RegExp = new RegExp('(https?)?://m\\.');
const WWW_PATTERN: RegExp = new RegExp('(https?)?://www\\.');

/**
 * Encode to the application/x-www-form-urlencoded form java.net.URLEncoder produces: space is
 * `+`, and `*`, `-`, `.` and `_` stay literal while `!`, `'`, `(`, `)` and `~` do not.
 */
export function encodeUrlUtf8(text: string): string {
  const encoded: string = encodeURIComponent(text);
  let out: string = '';
  for (const ch of encoded) {
    if (ch === '!' || ch === '\'' || ch === '(' || ch === ')' || ch === '~') {
      out += '%' + ch.charCodeAt(0).toString(16).toUpperCase();
    } else {
      out += ch;
    }
  }
  return out.replace(new RegExp('%20', 'g'), '+');
}

/** Decode the same form: `+` is a space, as in java.net.URLDecoder. */
export function decodeUrlUtf8(encoded: string): string {
  return decodeURIComponent(encoded.replace(new RegExp('\\+', 'g'), '%20'));
}

/** Remove all non-digit characters: `1 234 567 views` -> `1234567`. */
export function removeNonDigitCharacters(toRemove: string): string {
  return toRemove.replace(new RegExp('\\D+', 'g'), '');
}

/** Convert a mixed number word to a number: `1.23K` -> 1230, `1.23M` -> 1230000. */
export function mixedNumberWordToLong(numberWord: string): number {
  let multiplier: string = '';
  try {
    multiplier = Parser.matchGroupOfString('[\\d]+([\\.,][\\d]+)?([KMBkmb])+', numberWord, 2);
  } catch (ignored) {
    multiplier = '';
  }
  const count: number = Number.parseFloat(
    Parser.matchGroup1OfString('([\\d]+([\\.,][\\d]+)?)', numberWord).replace(',', '.'));
  const upper: string = multiplier.toUpperCase();
  if (upper === 'K') {
    return Math.trunc(count * 1e3);
  }
  if (upper === 'M') {
    return Math.trunc(count * 1e6);
  }
  if (upper === 'B') {
    return Math.trunc(count * 1e9);
  }
  return Math.trunc(count);
}

/** Throws if the url does not match the pattern. */
export function checkUrl(pattern: RegExp, urlToCheck: string): void {
  if (isNullOrEmpty(urlToCheck)) {
    throw new Error('Url can\'t be null or empty');
  }
  if (!Parser.isMatch(pattern, urlToCheck.toLowerCase())) {
    throw new ParsingException('Url doesn\'t match the pattern');
  }
}

export function replaceHttpWithHttps(inputUrl: string | null): string | null {
  if (inputUrl === null) {
    return null;
  }
  if (inputUrl.startsWith(HTTP)) {
    return HTTPS + inputUrl.substring(HTTP.length);
  }
  return inputUrl;
}

/**
 * Value of a URL query parameter by name, or null. If the query is given multiple times only the
 * first value is returned, as in the source.
 */
export function getQueryValue(parsedUrl: ohosUrl.URL, parameterName: string): string | null {
  let urlQuery: string = parsedUrl.search;
  if (urlQuery.startsWith('?')) {
    urlQuery = urlQuery.substring(1);
  }
  if (urlQuery.length > 0) {
    for (const param of urlQuery.split('&')) {
      const separator: number = param.indexOf('=');
      if (separator < 0) {
        continue;
      }
      const query: string = decodeUrlUtf8(param.substring(0, separator));
      if (query === parameterName) {
        return decodeUrlUtf8(param.substring(separator + 1));
      }
    }
  }
  return null;
}

/** Convert a string to a URL object, defaulting to HTTPS when no protocol is given. */
export function stringToURL(inputUrl: string): ohosUrl.URL {
  try {
    return new ohosUrl.URL(inputUrl);
  } catch (e) {
    if (!inputUrl.includes('://')) {
      return new ohosUrl.URL(HTTPS + inputUrl);
    }
    throw e;
  }
}

export function isHTTP(parsedUrl: ohosUrl.URL): boolean {
  const protocol: string = urlProtocol(parsedUrl);
  if (protocol !== 'http' && protocol !== 'https') {
    return false;
  }
  // An empty port means the default port for the scheme, which is what the source accepts too.
  if (parsedUrl.port.length === 0) {
    return true;
  }
  const defaultPort: string = protocol === 'http' ? '80' : '443';
  return parsedUrl.port === defaultPort;
}

/** `URL.protocol` carries the trailing colon; java.net.URL.getProtocol() does not. */
export function urlProtocol(parsedUrl: ohosUrl.URL): string {
  const protocol: string = parsedUrl.protocol;
  return protocol.endsWith(':') ? protocol.substring(0, protocol.length - 1) : protocol;
}

export function removeMAndWWWFromUrl(inputUrl: string): string {
  if (Parser.isMatch(M_PATTERN, inputUrl)) {
    return inputUrl.replace('m.', '');
  }
  if (Parser.isMatch(WWW_PATTERN, inputUrl)) {
    return inputUrl.replace('www.', '');
  }
  return inputUrl;
}

export function removeUTF8BOM(text: string): string {
  let result: string = text;
  if (result.startsWith('﻿')) {
    result = result.substring(1);
  }
  if (result.endsWith('﻿')) {
    result = result.substring(0, result.length - 1);
  }
  return result;
}

/** `protocol://authority` of the url. */
export function getBaseUrl(inputUrl: string): string {
  try {
    const uri: ohosUrl.URL = stringToURL(inputUrl);
    return urlProtocol(uri) + '://' + uri.host;
  } catch (e) {
    const message: string = e instanceof Error ? (e as Error).message : `${e}`;
    if (message.startsWith('unknown protocol: ')) {
      // Return just the protocol (e.g. vnd.youtube)
      return message.substring('unknown protocol: '.length);
    }
    throw new ParsingException('Malformed url: ' + inputUrl,
      e instanceof Error ? e as Error : null);
  }
}

/** If the url is a Google search redirect, return the real url it points at. */
export function followGoogleRedirectIfNeeded(inputUrl: string): string {
  try {
    const decoded: ohosUrl.URL = stringToURL(inputUrl);
    if (decoded.hostname.includes('google') && decoded.pathname === '/url') {
      return decodeUrlUtf8(Parser.matchGroup1OfString('&url=([^&]+)(?:&|$)', inputUrl));
    }
  } catch (ignored) {
    // URL is not a Google search redirect
  }
  return inputUrl;
}

export function isNullOrEmpty(str: string | null | undefined): boolean {
  return str === null || str === undefined || str.length === 0;
}

export function isListNullOrEmpty<T>(list: T[] | null | undefined): boolean {
  return list === null || list === undefined || list.length === 0;
}

export function isMapNullOrEmpty<K, V>(map: Map<K, V> | null | undefined): boolean {
  return map === null || map === undefined || map.size === 0;
}

export function isBlank(text: string | null | undefined): boolean {
  return text === null || text === undefined || text.trim().length === 0;
}

/** Join a map as `key<mapJoin>value` pairs separated by `delimiter`. */
export function joinMap(delimiter: string, mapJoin: string, elements: Map<string, string>): string {
  const parts: string[] = [];
  elements.forEach((value: string, key: string): void => {
    parts.push(key + mapJoin + value);
  });
  return parts.join(delimiter);
}

/** Concatenate all non-null, non-empty strings which are not equal to `"null"`. */
export function nonEmptyAndNullJoin(delimiter: string, elements: (string | null)[]): string {
  const kept: string[] = [];
  for (const element of elements) {
    if (!isNullOrEmpty(element) && element !== 'null') {
      kept.push(element as string);
    }
  }
  return kept.join(delimiter);
}

/**
 * First result of an array of regexes inside an input, on the given group (`0` in the source's
 * two-argument overloads).
 */
export function getStringResultFromRegexArray(input: string, regexes: RegExp[],
  group: number = 0): string {
  for (const regex of regexes) {
    try {
      return Parser.matchGroup(regex, input, group);
    } catch (ignored) {
      // try the next regex, exactly as the source does
    }
  }
  throw new RegexException('No regex matched the input on group ' + group);
}
