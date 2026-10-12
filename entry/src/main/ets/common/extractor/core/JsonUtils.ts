/*
 * Port of org.schabi.newpipe.extractor.utils.JsonUtils (NewPipeExtractor v0.26.5).
 *
 * Java's getInstanceOf(..., Class<T>) narrows by reflection; ArkTS has no Class token, so each
 * accessor checks the runtime shape itself and throws the same "Wrong data type at path" error.
 */

import { JsonArray, JsonObject, JsonParser, JsonValue } from '../json/NanoJson';
import { Document, Jsoup } from '../html/Jsoup';
import { ParsingException } from '../exceptions/Exceptions';

export class JsonUtils {
  /** The value at a dotted path, never null; throws if any segment is missing. */
  static getValue(object: JsonObject, path: string): JsonValue {
    const keys: string[] = path.split('.');
    const parentObject: JsonObject | null =
      JsonUtils.walk(object, keys.slice(0, keys.length - 1));
    if (parentObject === null) {
      throw new ParsingException('Unable to get ' + path);
    }
    const result: JsonValue | null = parentObject.get(keys[keys.length - 1]);
    if (result === null) {
      throw new ParsingException('Unable to get ' + path);
    }
    return result;
  }

  static getString(object: JsonObject, path: string): string {
    const value: JsonValue = JsonUtils.getValue(object, path);
    if (typeof value !== 'string') {
      throw new ParsingException('Wrong data type at path ' + path);
    }
    return value as string;
  }

  static getBoolean(object: JsonObject, path: string): boolean {
    const value: JsonValue = JsonUtils.getValue(object, path);
    if (typeof value !== 'boolean') {
      throw new ParsingException('Wrong data type at path ' + path);
    }
    return value as boolean;
  }

  static getNumber(object: JsonObject, path: string): number {
    const value: JsonValue = JsonUtils.getValue(object, path);
    if (typeof value !== 'number') {
      throw new ParsingException('Wrong data type at path ' + path);
    }
    return value as number;
  }

  static getObject(object: JsonObject, path: string): JsonObject {
    const value: JsonValue = JsonUtils.getValue(object, path);
    if (!(value instanceof JsonObject)) {
      throw new ParsingException('Wrong data type at path ' + path);
    }
    return value as JsonObject;
  }

  static getArray(object: JsonObject, path: string): JsonArray {
    const value: JsonValue = JsonUtils.getValue(object, path);
    if (!(value instanceof JsonArray)) {
      throw new ParsingException('Wrong data type at path ' + path);
    }
    return value as JsonArray;
  }

  /** The value at `path` of every object in the array. */
  static getValues(array: JsonArray, path: string): JsonValue[] {
    const result: JsonValue[] = [];
    for (let i = 0; i < array.size(); i++) {
      result.push(JsonUtils.getValue(array.getObject(i), path));
    }
    return result;
  }

  private static walk(object: JsonObject, keys: string[]): JsonObject | null {
    let result: JsonObject | null = object;
    for (const key of keys) {
      const next: JsonValue | null = result === null ? null : result.get(key);
      if (next === null || !(next instanceof JsonObject)) {
        return null;
      }
      result = next as JsonObject;
    }
    return result;
  }

  static toJsonArray(responseBody: string): JsonArray {
    try {
      return JsonParser.array().from(responseBody);
    } catch (e) {
      throw new ParsingException('Could not parse JSON', e instanceof Error ? e as Error : null);
    }
  }

  static toJsonObject(responseBody: string): JsonObject {
    try {
      return JsonParser.object().from(responseBody);
    } catch (e) {
      throw new ParsingException('Could not parse JSON', e instanceof Error ? e as Error : null);
    }
  }

  /**
   * Get an attribute of a web page as JSON: the value of `variable` on the first element that
   * carries that attribute, parsed as an object (originally a part of bandcampDirect).
   */
  static getJsonData(html: string, variable: string): JsonObject {
    const document: Document = Jsoup.parse(html);
    const json: string = document.getElementsByAttribute(variable).attr(variable);
    return JsonParser.object().from(json);
  }

  static getStringListFromJsonArray(array: JsonArray): string[] {
    const strings: string[] = [];
    for (let i = 0; i < array.size(); i++) {
      const value: JsonValue | null = array.get(i);
      if (typeof value === 'string') {
        strings.push(value as string);
      }
    }
    return strings;
  }
}
