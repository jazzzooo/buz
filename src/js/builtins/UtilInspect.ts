type Inspect = typeof import("util").inspect;

export function callCustomInspect(
  this: unknown,
  callback: (...args: any[]) => unknown,
  depth: number,
  maxDepth: number,
  colors: boolean,
  sorted: boolean,
  compact: boolean,
  inspect: Inspect,
  stylize: (value: string, style: string) => string,
) {
  "use strict";
  return callback.$call(this, depth, { stylize, depth: maxDepth, colors, sorted, compact }, inspect);
}

// This is passed to [util.inspect.custom](..., { stylize }) to help users colorize parts.
export function getStylizeWithColor(inspect: Inspect) {
  return function stylizeWithColor(str: string, styleType: string) {
    const style = inspect.styles[styleType];
    if (style !== undefined) {
      const color = inspect.colors[style];
      if (color !== undefined) return `\u001b[${color[0]}m${str}\u001b[${color[1]}m`;
    }
    return str;
  };
}

export function stylizeWithNoColor(str: string) {
  return str;
}
