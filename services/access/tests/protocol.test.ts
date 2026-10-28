import { expect, test } from "bun:test";
import { parseJSON } from "../src/protocol";

test.each([
  '{"limit":1,"limit":2}',
  '{"nested":[{"limit":1,"l\\u0069mit":2}]}',
  '{"outer":{"nested":{"x":1,"x":2}}}',
])("duplicate JSON keys are rejected at every nesting level", (text) => {
  expect(() => parseJSON(text)).toThrow("duplicate_json_key");
});

test("repeated keys in separate objects remain valid", () => {
  expect(parseJSON('{"items":[{"x":1},{"x":2}]}')).toEqual({
    items: [{ x: 1 }, { x: 2 }],
  });
});
