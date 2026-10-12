/*
 * Port of org.schabi.newpipe.extractor.utils.Parser (NewPipeExtractor v0.26.5).
 *
 * Java overloads each matcher on (String pattern | Pattern pattern); ArkTS has no overloading, so
 * the RegExp form keeps the source name and the string form gets the `OfString` suffix.
 *
 * A RegExp carrying the `g` flag keeps `lastIndex` between calls, which java.util.regex never
 * does, so every entry point resets it before matching.
 */

import { ParsingException } from '../exceptions/Exceptions';

export class RegexException extends ParsingException {
  constructor(message: string) {
    super(message);
    this.name = 'RegexException';
  }
}

export class Parser {
  /** Port of matchOrThrow(): the first match, or a RegexException naming the pattern. */
  static matchOrThrow(pattern: RegExp, input: string): RegExpExecArray {
    pattern.lastIndex = 0;
    const matcher: RegExpExecArray | null = pattern.exec(input);
    if (matcher !== null) {
      return matcher;
    }
    let errorMessage: string = 'Failed to find pattern "' + pattern.source + '"';
    if (input.length <= 1024) {
      errorMessage += ' inside of "' + input + '"';
    }
    throw new RegexException(errorMessage);
  }

  /** Match the given group of the pattern against the input and return it. */
  static matchGroup(pattern: RegExp, input: string, group: number): string {
    const matcher: RegExpExecArray = Parser.matchOrThrow(pattern, input);
    const value: string | undefined = matcher[group];
    if (value === undefined) {
      throw new RegexException('Group ' + group + ' did not match in pattern "'
        + pattern.source + '"');
    }
    return value;
  }

  static matchGroupOfString(pattern: string, input: string, group: number): string {
    return Parser.matchGroup(new RegExp(pattern), input, group);
  }

  static matchGroup1(pattern: RegExp, input: string): string {
    return Parser.matchGroup(pattern, input, 1);
  }

  static matchGroup1OfString(pattern: string, input: string): string {
    return Parser.matchGroup(new RegExp(pattern), input, 1);
  }

  /** First pattern of the array that matches; otherwise the first pattern's RegexException. */
  static matchMultiplePatterns(patterns: RegExp[], input: string): RegExpExecArray {
    let exception: RegexException | null = null;
    for (const pattern of patterns) {
      pattern.lastIndex = 0;
      const matcher: RegExpExecArray | null = pattern.exec(input);
      if (matcher !== null) {
        return matcher;
      }
      if (exception === null) {
        exception = new RegexException('Failed to find pattern "' + pattern.source + '"'
          // only pass input to the exception message when it is not too long
          + (input.length <= 1000 ? 'inside of "' + input + '"' : ''));
      }
    }
    throw exception !== null
      ? exception
      : new RegexException('Empty patterns array passed to matchMultiplePatterns');
  }

  static matchGroup1MultiplePatterns(patterns: RegExp[], input: string): string {
    const matcher: RegExpExecArray = Parser.matchMultiplePatterns(patterns, input);
    const value: string | undefined = matcher[1];
    if (value === undefined) {
      throw new RegexException('Group 1 did not match any of the patterns');
    }
    return value;
  }

  static isMatch(pattern: RegExp, input: string): boolean {
    pattern.lastIndex = 0;
    return pattern.test(input);
  }

  static isMatchOfString(pattern: string, input: string): boolean {
    return new RegExp(pattern).test(input);
  }

  /**
   * Port of compatParseMap(): `a=1&b=2` to a Map, later duplicates winning, values URL-decoded
   * exactly as Utils.decodeUrlUtf8 does (inlined so this module stays a leaf).
   */
  static compatParseMap(input: string): Map<string, string> {
    const parsed: Map<string, string> = new Map<string, string>();
    for (const arg of input.split('&')) {
      const splitArg: string[] = arg.split('=');
      if (splitArg.length > 1) {
        parsed.set(splitArg[0],
          decodeURIComponent(splitArg[1].replace(new RegExp('\\+', 'g'), '%20')));
      }
    }
    return parsed;
  }
}
