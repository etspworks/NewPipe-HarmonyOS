/*
 * Port of org.schabi.newpipe.extractor.utils.{Logger, ExtractorLogger} (NewPipeExtractor v0.26.5).
 *
 * ArkTS has no method overloading, so each level collapses to ONE signature carrying the optional
 * arguments and cause the Java overloads split across four methods. Nothing is logged until the
 * app installs a Logger (the source's EmptyLogger default).
 */

export enum LogLevel {
  DEBUG,
  WARN,
  ERROR
}

export interface Logger {
  debug(tag: string, message: string, throwable: Error | null): void;
  warn(tag: string, message: string, throwable: Error | null): void;
  error(tag: string, message: string, throwable: Error | null): void;
}

export class ExtractorLogger {
  private static logger: Logger | null = null;

  static setLogger(customLogger: Logger | null): void {
    ExtractorLogger.logger = customLogger;
  }

  /**
   * Port of ExtractorLogger.format(): `{}` and `{name}` are positional placeholders, `{{` and
   * `}}` escape a literal brace, and a placeholder with no argument left is copied verbatim.
   */
  static format(template: string, args: Object[]): string {
    if (args.length === 0) {
      return template;
    }
    let result: string = '';
    let cursorIndex: number = 0;
    let argIndex: number = 0;
    const n: number = template.length;
    while (cursorIndex < n) {
      const ch: string = template.charAt(cursorIndex);

      if (ch === '{' && cursorIndex + 1 < n && template.charAt(cursorIndex + 1) === '{') {
        result += '{';
        cursorIndex += 2;
        continue;
      }
      if (ch === '}' && cursorIndex + 1 < n && template.charAt(cursorIndex + 1) === '}') {
        result += '}';
        cursorIndex += 2;
        continue;
      }
      if (ch === '{') {
        const closeBraceIndex: number = template.indexOf('}', cursorIndex + 1);
        if (closeBraceIndex < 0) {
          result += template.substring(cursorIndex, n);
          break;
        }
        if (argIndex < args.length) {
          const arg: Object = args[argIndex];
          argIndex++;
          result += `${arg}`;
        } else {
          result += template.substring(cursorIndex, closeBraceIndex + 1);
        }
        cursorIndex = closeBraceIndex + 1;
        continue;
      }
      result += ch;
      cursorIndex++;
    }
    return result;
  }

  private static log(level: LogLevel, tag: string, template: string, args: Object[],
    cause: Error | null): void {
    const installed: Logger | null = ExtractorLogger.logger;
    if (installed === null) {
      return;
    }
    const message: string = ExtractorLogger.format(template, args);
    if (level === LogLevel.DEBUG) {
      installed.debug(tag, message, cause);
    } else if (level === LogLevel.WARN) {
      installed.warn(tag, message, cause);
    } else {
      installed.error(tag, message, cause);
    }
  }

  static d(tag: string, template: string, args: Object[] = [], cause: Error | null = null): void {
    ExtractorLogger.log(LogLevel.DEBUG, tag, template, args, cause);
  }

  static w(tag: string, template: string, args: Object[] = [], cause: Error | null = null): void {
    ExtractorLogger.log(LogLevel.WARN, tag, template, args, cause);
  }

  static e(tag: string, template: string, args: Object[] = [], cause: Error | null = null): void {
    ExtractorLogger.log(LogLevel.ERROR, tag, template, args, cause);
  }
}
