/*
 * Port of com.grack.nanojson (TeamNewPipe fork e9d656d, vendored at input/source/nanojson):
 * JsonObject / JsonArray / JsonParser / JsonWriter / JsonBuilder / JsonParserException.
 *
 * WHAT IS PORTED AND WHAT IS NOT, and why:
 *   - The value model and its null-safe typed accessors ARE the library, and they are ported
 *     here method for method, with the source's exact defaults (getString -> null,
 *     getObject -> an empty JsonObject, getArray -> an empty JsonArray, getInt/getLong/
 *     getDouble -> 0, getBoolean -> false, getNumber -> null, and a value of the wrong type
 *     falls back to the default rather than throwing). 861 getObject / 856 getString /
 *     265 getArray call sites in the app and the extractor depend on exactly that behaviour.
 *   - JsonTokener / JsonReader / JsonParser's hand-written scanner are NOT transcribed:
 *     nanojson is a strict RFC-8259 parser (its only option, withLazyNumbers(), merely defers
 *     Number boxing, which ArkTS does not have), so the platform's own conforming parser is
 *     the capability mapping for it - CLAUDE.md Rule 10, mapping-tables section 5
 *     "JSON (Gson, Moshi, Codable) -> JSON.parse / JSON.stringify into typed classes".
 *     Parsed values are wrapped into JsonObject / JsonArray once, at parse time, so the
 *     instanceof checks the accessors make behave as in the source.
 */

import { toError } from '../core/Errors';

/** Anything that can sit in a JSON tree. Numbers are ArkTS `number`: Java's int/long/float/double all collapse here. */
export type JsonValue = string | number | boolean | JsonObject | JsonArray;

/** Port of JsonParserException. */
export class JsonParserException extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'JsonParserException';
  }
}

/** Port of JsonWriterException. */
export class JsonWriterException extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'JsonWriterException';
  }
}

/* ////////////////////////////////////////////////////////////////////////////
// Value model
//////////////////////////////////////////////////////////////////////////// */

export class JsonObject {
  private readonly entries: Map<string, JsonValue | null> = new Map<string, JsonValue | null>();

  static builder(): JsonBuilder {
    return new JsonBuilder(new JsonObject());
  }

  put(key: string, value: JsonValue | null): void {
    this.entries.set(key, value);
  }

  remove(key: string): void {
    this.entries.delete(key);
  }

  get(key: string): JsonValue | null {
    const value: JsonValue | null | undefined = this.entries.get(key);
    return value === undefined ? null : value;
  }

  has(key: string): boolean {
    return this.entries.has(key);
  }

  size(): number {
    return this.entries.size;
  }

  keys(): string[] {
    const names: string[] = [];
    for (const key of this.entries.keys()) {
      names.push(key);
    }
    return names;
  }

  isNull(key: string): boolean {
    return this.entries.has(key) && this.entries.get(key) === null;
  }

  isString(key: string): boolean {
    return typeof this.get(key) === 'string';
  }

  isNumber(key: string): boolean {
    return typeof this.get(key) === 'number';
  }

  isBoolean(key: string): boolean {
    return typeof this.get(key) === 'boolean';
  }

  getString(key: string, defaultValue: string | null = null): string | null {
    const value: JsonValue | null = this.get(key);
    return typeof value === 'string' ? value as string : defaultValue;
  }

  getBoolean(key: string, defaultValue: boolean = false): boolean {
    const value: JsonValue | null = this.get(key);
    return typeof value === 'boolean' ? value as boolean : defaultValue;
  }

  getNumber(key: string, defaultValue: number | null = null): number | null {
    const value: JsonValue | null = this.get(key);
    return typeof value === 'number' ? value as number : defaultValue;
  }

  getDouble(key: string, defaultValue: number = 0): number {
    const value: JsonValue | null = this.get(key);
    return typeof value === 'number' ? value as number : defaultValue;
  }

  /** Java's floatValue(); ArkTS has one number type, so this matches getDouble. */
  getFloat(key: string, defaultValue: number = 0): number {
    return this.getDouble(key, defaultValue);
  }

  /** Java's intValue() truncates towards zero. */
  getInt(key: string, defaultValue: number = 0): number {
    const value: JsonValue | null = this.get(key);
    return typeof value === 'number' ? Math.trunc(value as number) : defaultValue;
  }

  /**
   * Java's longValue(). ArkTS numbers are IEEE-754 doubles, so a value beyond 2^53 loses
   * precision; every long NewPipe reads (view/subscriber counts, durations, timestamps in ms)
   * is far below that.
   */
  getLong(key: string, defaultValue: number = 0): number {
    return this.getInt(key, defaultValue);
  }

  getObject(key: string, defaultValue: JsonObject | null = null): JsonObject {
    const value: JsonValue | null = this.get(key);
    if (value instanceof JsonObject) {
      return value as JsonObject;
    }
    return defaultValue === null ? new JsonObject() : defaultValue;
  }

  getArray(key: string, defaultValue: JsonArray | null = null): JsonArray {
    const value: JsonValue | null = this.get(key);
    if (value instanceof JsonArray) {
      return value as JsonArray;
    }
    return defaultValue === null ? new JsonArray() : defaultValue;
  }

  toString(): string {
    return JsonWriter.stringValue(this);
  }
}

export class JsonArray {
  private readonly items: Array<JsonValue | null> = [];

  static builder(): JsonBuilder {
    return new JsonBuilder(new JsonArray());
  }

  static fromValues(contents: Array<JsonValue | null>): JsonArray {
    const array: JsonArray = new JsonArray();
    for (const item of contents) {
      array.add(item);
    }
    return array;
  }

  add(value: JsonValue | null): void {
    this.items.push(value);
  }

  size(): number {
    return this.items.length;
  }

  get(index: number): JsonValue | null {
    if (index < 0 || index >= this.items.length) {
      return null;
    }
    return this.items[index];
  }

  has(index: number): boolean {
    return index >= 0 && index < this.items.length;
  }

  isNull(index: number): boolean {
    return this.has(index) && this.items[index] === null;
  }

  isString(index: number): boolean {
    return typeof this.get(index) === 'string';
  }

  isNumber(index: number): boolean {
    return typeof this.get(index) === 'number';
  }

  isBoolean(index: number): boolean {
    return typeof this.get(index) === 'boolean';
  }

  getString(index: number, defaultValue: string | null = null): string | null {
    const value: JsonValue | null = this.get(index);
    return typeof value === 'string' ? value as string : defaultValue;
  }

  getBoolean(index: number, defaultValue: boolean = false): boolean {
    const value: JsonValue | null = this.get(index);
    return typeof value === 'boolean' ? value as boolean : defaultValue;
  }

  getNumber(index: number, defaultValue: number | null = null): number | null {
    const value: JsonValue | null = this.get(index);
    return typeof value === 'number' ? value as number : defaultValue;
  }

  getDouble(index: number, defaultValue: number = 0): number {
    const value: JsonValue | null = this.get(index);
    return typeof value === 'number' ? value as number : defaultValue;
  }

  getFloat(index: number, defaultValue: number = 0): number {
    return this.getDouble(index, defaultValue);
  }

  getInt(index: number, defaultValue: number = 0): number {
    const value: JsonValue | null = this.get(index);
    return typeof value === 'number' ? Math.trunc(value as number) : defaultValue;
  }

  getLong(index: number, defaultValue: number = 0): number {
    return this.getInt(index, defaultValue);
  }

  getObject(index: number, defaultValue: JsonObject | null = null): JsonObject {
    const value: JsonValue | null = this.get(index);
    if (value instanceof JsonObject) {
      return value as JsonObject;
    }
    return defaultValue === null ? new JsonObject() : defaultValue;
  }

  getArray(index: number, defaultValue: JsonArray | null = null): JsonArray {
    const value: JsonValue | null = this.get(index);
    if (value instanceof JsonArray) {
      return value as JsonArray;
    }
    return defaultValue === null ? new JsonArray() : defaultValue;
  }

  /** Every element, in order. Java's ArrayList.stream() source. */
  toArray(): Array<JsonValue | null> {
    return this.items.slice();
  }

  /**
   * Port of streamAsJsonObjects(): the JsonObject elements only, skipping anything else.
   * RxJava/Java Streams have no ArkTS analogue, so this returns an array - the call sites
   * chain the array's own map/filter, which is what the source Stream chains do.
   */
  streamAsJsonObjects(): JsonObject[] {
    const objects: JsonObject[] = [];
    for (const item of this.items) {
      if (item instanceof JsonObject) {
        objects.push(item as JsonObject);
      }
    }
    return objects;
  }

  /** Port of streamAs(String.class), the only other streamAs() specialisation NewPipe uses. */
  streamAsStrings(): string[] {
    const strings: string[] = [];
    for (const item of this.items) {
      if (typeof item === 'string') {
        strings.push(item as string);
      }
    }
    return strings;
  }

  toString(): string {
    return JsonWriter.stringValue(this);
  }
}

/* ////////////////////////////////////////////////////////////////////////////
// Parsing
//////////////////////////////////////////////////////////////////////////// */

function wrapParsed(raw: Object | null): JsonValue | null {
  if (raw === null || raw === undefined) {
    return null;
  }
  if (Array.isArray(raw)) {
    const array: JsonArray = new JsonArray();
    for (const item of raw as Array<Object | null>) {
      array.add(wrapParsed(item));
    }
    return array;
  }
  const kind: string = typeof raw;
  if (kind === 'string') {
    return raw as string;
  }
  if (kind === 'number') {
    return raw as number;
  }
  if (kind === 'boolean') {
    return raw as boolean;
  }
  const record: Record<string, Object | null> = raw as Record<string, Object | null>;
  const object: JsonObject = new JsonObject();
  for (const key of Object.keys(record)) {
    object.put(key, wrapParsed(record[key]));
  }
  return object;
}

function parseText(text: string): JsonValue | null {
  let raw: Object | null;
  try {
    raw = JSON.parse(text) as Object | null;
  } catch (err) {
    // toError, not `${err}`: the platform's parse failure arrives as a plain object, which
    // stringifies to "[object Object]" and tells nobody what was malformed.
    throw new JsonParserException(toError(err).message);
  }
  return wrapParsed(raw);
}

/** Port of JsonParser.object(): parses a JSON document that must be an object. */
export class JsonObjectParserContext {
  /** No-op: ArkTS has no boxed Number to defer, so lazy numbers are meaningless here. */
  withLazyNumbers(): JsonObjectParserContext {
    return this;
  }

  from(text: string): JsonObject {
    const parsed: JsonValue | null = parseText(text);
    if (!(parsed instanceof JsonObject)) {
      throw new JsonParserException('did not find object');
    }
    return parsed as JsonObject;
  }
}

/** Port of JsonParser.array(): parses a JSON document that must be an array. */
export class JsonArrayParserContext {
  withLazyNumbers(): JsonArrayParserContext {
    return this;
  }

  from(text: string): JsonArray {
    const parsed: JsonValue | null = parseText(text);
    if (!(parsed instanceof JsonArray)) {
      throw new JsonParserException('did not find array');
    }
    return parsed as JsonArray;
  }
}

/** Port of JsonParser.any(). */
export class JsonAnyParserContext {
  withLazyNumbers(): JsonAnyParserContext {
    return this;
  }

  from(text: string): JsonValue | null {
    return parseText(text);
  }
}

export class JsonParser {
  static object(): JsonObjectParserContext {
    return new JsonObjectParserContext();
  }

  static array(): JsonArrayParserContext {
    return new JsonArrayParserContext();
  }

  static any(): JsonAnyParserContext {
    return new JsonAnyParserContext();
  }
}

/* ////////////////////////////////////////////////////////////////////////////
// Writing
//////////////////////////////////////////////////////////////////////////// */

function unwrap(value: JsonValue | null): Object | null {
  if (value === null) {
    return null;
  }
  if (value instanceof JsonObject) {
    const object: JsonObject = value as JsonObject;
    const record: Record<string, Object | null> = {};
    for (const key of object.keys()) {
      record[key] = unwrap(object.get(key));
    }
    return record;
  }
  if (value instanceof JsonArray) {
    const array: JsonArray = value as JsonArray;
    const list: Array<Object | null> = [];
    for (const item of array.toArray()) {
      list.push(unwrap(item));
    }
    return list;
  }
  return value as Object;
}

/**
 * The mutable tree the fluent writers build. `object()`/`array()` push a container,
 * `end()` pops it - exactly the nesting discipline of JsonWriterBase.
 *
 * The two source classes start from different states, so the constructor takes the difference:
 * JsonWriterBase starts empty (JsonWriter.string() is followed by the caller's own .object()),
 * while `JsonBuilder(T root)` creates the root container and pushes it before the caller writes
 * anything - which is why `JsonObject.builder().object("context")...end()` leaves the ROOT open
 * and the caller may keep adding keys to it.
 */
class JsonTree {
  private root: JsonValue | null = null;
  private rootSet: boolean = false;
  private readonly stack: Array<JsonValue> = [];
  /** Containers that stay on the stack for good: 1 for a builder's pre-opened root, else 0. */
  private floor: number = 0;

  constructor(root: JsonValue | null = null) {
    if (root !== null) {
      this.root = root;
      this.rootSet = true;
      this.stack.push(root);
      this.floor = 1;
    }
  }

  private current(): JsonValue | null {
    return this.stack.length === 0 ? null : this.stack[this.stack.length - 1];
  }

  /** Places a finished value in the enclosing container, or makes it the root. */
  private place(key: string | null, value: JsonValue | null): void {
    const container: JsonValue | null = this.current();
    if (container === null) {
      if (this.rootSet) {
        throw new JsonWriterException('two root values written');
      }
      this.root = value;
      this.rootSet = true;
      return;
    }
    if (container instanceof JsonObject) {
      if (key === null) {
        throw new JsonWriterException('a value inside an object needs a key');
      }
      (container as JsonObject).put(key, value);
      return;
    }
    if (key !== null) {
      throw new JsonWriterException('a value inside an array must not have a key');
    }
    (container as JsonArray).add(value);
  }

  putValue(key: string | null, value: JsonValue | null): void {
    this.place(key, value);
  }

  beginObject(key: string | null): void {
    const object: JsonObject = new JsonObject();
    this.place(key, object);
    this.stack.push(object);
  }

  beginArray(key: string | null): void {
    const array: JsonArray = new JsonArray();
    this.place(key, array);
    this.stack.push(array);
  }

  end(): void {
    if (this.stack.length <= this.floor) {
      // JsonBuilder.end() refuses to pop the root ("Cannot end the root object or array");
      // JsonWriterBase.end() has no root to protect.
      throw new JsonWriterException(this.floor === 0
        ? 'end() called outside an object or array'
        : 'Cannot end the root object or array');
    }
    this.stack.pop();
  }

  finish(): JsonValue | null {
    // JsonWriterBase.done() rejects an unclosed container; JsonBuilder.done() just returns the
    // root, "closing any unclosed objects" - so only the writer (floor 0) checks.
    if (this.floor === 0 && this.stack.length !== 0) {
      throw new JsonWriterException('done() called with an unclosed object or array');
    }
    return this.root;
  }
}

/** Port of JsonStringWriter: the object JsonWriter.string() returns. */
export class JsonStringWriter {
  private readonly tree: JsonTree = new JsonTree();

  object(key: string | null = null): JsonStringWriter {
    this.tree.beginObject(key);
    return this;
  }

  array(key: string | null = null): JsonStringWriter {
    this.tree.beginArray(key);
    return this;
  }

  /** One argument writes a bare value; two write a key/value pair, as in JsonWriterBase. */
  value(keyOrValue: JsonValue | null, value?: JsonValue | null): JsonStringWriter {
    if (value === undefined) {
      this.tree.putValue(null, keyOrValue);
    } else {
      this.tree.putValue(keyOrValue as string, value);
    }
    return this;
  }

  nul(key: string | null = null): JsonStringWriter {
    this.tree.putValue(key, null);
    return this;
  }

  end(): JsonStringWriter {
    this.tree.end();
    return this;
  }

  done(): string {
    return JSON.stringify(unwrap(this.tree.finish()));
  }
}

/** Port of JsonBuilder: the object JsonObject.builder() / JsonArray.builder() returns. */
export class JsonBuilder {
  private readonly tree: JsonTree;

  /** Port of `JsonBuilder(T root)`: the root container is open before the first write. */
  constructor(root: JsonValue) {
    this.tree = new JsonTree(root);
  }

  object(key: string | null = null): JsonBuilder {
    this.tree.beginObject(key);
    return this;
  }

  array(key: string | null = null): JsonBuilder {
    this.tree.beginArray(key);
    return this;
  }

  value(keyOrValue: JsonValue | null, value?: JsonValue | null): JsonBuilder {
    if (value === undefined) {
      this.tree.putValue(null, keyOrValue);
    } else {
      this.tree.putValue(keyOrValue as string, value);
    }
    return this;
  }

  nul(key: string | null = null): JsonBuilder {
    this.tree.putValue(key, null);
    return this;
  }

  end(): JsonBuilder {
    this.tree.end();
    return this;
  }

  done(): JsonValue | null {
    return this.tree.finish();
  }

  /** done() typed for the common `JsonObject.builder()...done()` shape. */
  doneObject(): JsonObject {
    const built: JsonValue | null = this.tree.finish();
    return built instanceof JsonObject ? built as JsonObject : new JsonObject();
  }
}

export class JsonWriter {
  /** Port of JsonWriter.string(): starts a fluent writer that done() turns into a String. */
  static string(): JsonStringWriter {
    return new JsonStringWriter();
  }

  /**
   * Port of JsonWriter.string(Object): serialises one value.
   *
   * Java resolves `JsonWriter.string()` and `JsonWriter.string(value)` by overload; ArkTS has no
   * method overloading, so the one-argument form is spelled `stringValue`. Every source call of
   * the shape `JsonWriter.string(builder.done())` becomes `JsonWriter.stringValue(...)`.
   */
  static stringValue(value: JsonValue | null): string {
    return JSON.stringify(unwrap(value));
  }

  /** Port of JsonWriter.escape(): the JSON string form of a value, quotes included. */
  static escape(value: string): string {
    return JSON.stringify(value);
  }
}
