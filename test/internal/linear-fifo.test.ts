import { linearFifoOrderedRemoveProbe } from "bun:internal-for-testing";
import { expect, test } from "bun:test";

test("orderedRemoveItem preserves FIFO order in the wrapped tail sub-branch", () => {
  // write 12, read 8, write 10 -> head=8, count=14, buf_len=16.
  expect(linearFifoOrderedRemoveProbe(0)).toEqual([8, 9, 10, 11, 100, 101, 103, 104, 105, 106, 107, 108, 109]);
});

test("orderedRemoveItem preserves FIFO order in the wrapped prefix sub-branch", () => {
  // write 12, read 12, write 8 -> head=12, count=8, buf_len=16.
  expect(linearFifoOrderedRemoveProbe(1)).toEqual([200, 201, 202, 203, 204, 206, 207]);
});
