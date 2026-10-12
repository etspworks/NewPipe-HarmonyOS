/*
 * Port of org.schabi.newpipe.extractor.localization.TimeAgoParser (NewPipeExtractor v0.26.5).
 *
 * Turns a textual date like "3 days ago" into a real date, using the ago-phrases of one
 * localization. Row subtitles are wrong without it.
 */

import { ParsingException } from '../exceptions/Exceptions';
import { Parser } from '../core/Parser';
import { ChronoUnit, isDateBased, minus, truncatedToDays } from './ChronoUnit';
import { DateWrapper } from './DateWrapper';
import { PatternsHolder } from './TimeAgoPatterns';

/** Port of java.util.regex.Pattern.quote(): match the phrase literally. */
function quoteRegex(text: string): string {
  let quoted: string = '';
  for (const ch of text) {
    if ('\\^$.|?*+()[]{}'.includes(ch)) {
      quoted += '\\' + ch;
    } else {
      quoted += ch;
    }
  }
  return quoted;
}

export class TimeAgoParser {
  private readonly patternsHolder: PatternsHolder;
  private readonly now: Date;

  /**
   * Creates a parser with the specified language patterns and the time to compare against.
   */
  constructor(patternsHolder: PatternsHolder, now: Date) {
    this.patternsHolder = patternsHolder;
    this.now = now;
  }

  /** Parses a textual date in the format '2 days ago' into a DateWrapper. */
  parse(textualDate: string): DateWrapper {
    const specialCases: Map<ChronoUnit, Map<string, number>> = this.patternsHolder.specialCases();
    let specialResult: DateWrapper | null = null;
    specialCases.forEach((cases: Map<string, number>, chronoUnit: ChronoUnit): void => {
      cases.forEach((caseAmount: number, caseText: string): void => {
        if (specialResult === null && this.textualDateMatches(textualDate, caseText)) {
          specialResult = this.getResultFor(caseAmount, chronoUnit);
        }
      });
    });
    if (specialResult !== null) {
      return specialResult as DateWrapper;
    }

    return this.getResultFor(TimeAgoParser.parseTimeAgoAmount(textualDate),
      this.parseChronoUnit(textualDate));
  }

  private static parseTimeAgoAmount(textualDate: string): number {
    const digits: string = textualDate.replace(new RegExp('\\D+', 'g'), '');
    const amount: number = Number.parseInt(digits, 10);
    if (Number.isNaN(amount)) {
      // If there is no valid number in the textual date, assume it is 1 (as in 'a second ago').
      return 1;
    }
    return amount;
  }

  private parseChronoUnit(textualDate: string): ChronoUnit {
    const unitPhrases: Map<ChronoUnit, string[]> = this.patternsHolder.asMap();
    let found: ChronoUnit | null = null;
    unitPhrases.forEach((agoPhrases: string[], unit: ChronoUnit): void => {
      if (found !== null) {
        return;
      }
      for (const agoPhrase of agoPhrases) {
        if (this.textualDateMatches(textualDate, agoPhrase)) {
          found = unit;
          return;
        }
      }
    });
    if (found === null) {
      throw new ParsingException('Unable to parse the date: ' + textualDate);
    }
    return found as ChronoUnit;
  }

  private textualDateMatches(textualDate: string, agoPhrase: string): boolean {
    if (textualDate === agoPhrase) {
      return true;
    }

    if (this.patternsHolder.wordSeparator().length === 0) {
      return textualDate.toLowerCase().includes(agoPhrase.toLowerCase());
    }

    const escapedPhrase: string = quoteRegex(agoPhrase.toLowerCase());
    // Treat horizontal spaces as a normal one (non-breaking space, thin space, etc.), and split
    // on numbers too so strings like "2wk" parse.
    const escapedSeparator: string = this.patternsHolder.wordSeparator() === ' '
      ? '[ \\t\\xA0\\u1680\\u180e\\u2000-\\u200a\\u202f\\u205f\\u3000\\d]'
      : quoteRegex(this.patternsHolder.wordSeparator());

    // (^|separator)pattern($|separator)
    const pattern: string =
      '(^|' + escapedSeparator + ')' + escapedPhrase + '($|' + escapedSeparator + ')';

    return Parser.isMatch(new RegExp(pattern), textualDate.toLowerCase());
  }

  private getResultFor(timeAgoAmount: number, chronoUnit: ChronoUnit): DateWrapper {
    // minus one day is needed to prevent PrettyTime from showing '12 months ago'
    const localDateTime: Date = chronoUnit === ChronoUnit.YEARS
      ? minus(minus(this.now, timeAgoAmount, ChronoUnit.YEARS), 1, ChronoUnit.DAYS)
      : minus(this.now, timeAgoAmount, chronoUnit);
    const isApproximate: boolean = isDateBased(chronoUnit);
    const resolvedDateTime: Date =
      isApproximate ? truncatedToDays(localDateTime) : localDateTime;
    return new DateWrapper(resolvedDateTime, isApproximate);
  }
}
