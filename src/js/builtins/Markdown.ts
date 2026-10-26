interface MarkdownEvent {
  phase: "enter" | "leave" | "text" | "rawText" | "hardBreak";
  kind: string;
  data: number;
  primary: string | null;
  secondary: string | null;
  checked: boolean | null;
}

interface MarkdownParseSession {
  parse(options?: unknown): { events: MarkdownEvent[]; legacy: boolean };
  release(): void;
}

export function render(input: unknown, callbacks?: unknown, options?: unknown): string {
  const ParseSession = $bindgenClass("MarkdownObject.schema.zig", "MarkdownParseSession") as {
    new (input: unknown): MarkdownParseSession;
  };
  const session = new ParseSession(input);

  try {
    const callbackNames = [
      "heading",
      "paragraph",
      "blockquote",
      "code",
      "list",
      "listItem",
      "hr",
      "table",
      "thead",
      "tbody",
      "tr",
      "th",
      "td",
      "html",
      "strong",
      "emphasis",
      "link",
      "image",
      "codespan",
      "strikethrough",
      "text",
    ];
    const handlers = {};
    if (callbacks !== undefined && callbacks !== null) {
      if (typeof callbacks !== "object" && typeof callbacks !== "function") {
        throw new TypeError("Markdown callbacks must be an object");
      }
      for (let index = 0; index < callbackNames.length; index++) {
        const name = callbackNames[index];
        const callback = callbacks[name];
        if (callback !== undefined) {
          if (typeof callback !== "function") throw new TypeError(`Markdown callback '${name}' must be a function`);
          handlers[name] = callback;
        }
      }
    }

    const { events } = session.parse(options);
    const stack = [{ kind: "none", children: [] }];

    const append = (entry, value) => {
      entry.children[entry.children.length] = value;
    };
    const concatenate = entry => {
      let result = "";
      for (let index = 0; index < entry.children.length; index++) {
        const child = entry.children[index];
        if (child !== undefined && child !== null) result += child;
      }
      return result;
    };
    const countLists = () => {
      let depth = 0;
      for (let index = 1; index < stack.length; index++) {
        const kind = stack[index].kind;
        if (kind === "orderedList" || kind === "unorderedList") depth++;
      }
      return depth;
    };
    const callbackName = kind => {
      switch (kind) {
        case "heading":
          return "heading";
        case "paragraph":
          return "paragraph";
        case "blockquote":
          return "blockquote";
        case "code":
          return "code";
        case "orderedList":
        case "unorderedList":
          return "list";
        case "listItem":
          return "listItem";
        case "horizontalRule":
          return "hr";
        case "table":
          return "table";
        case "tableHead":
          return "thead";
        case "tableBody":
          return "tbody";
        case "tableRow":
          return "tr";
        case "tableHeaderCell":
          return "th";
        case "tableCell":
          return "td";
        case "html":
          return "html";
        case "strong":
          return "strong";
        case "emphasis":
          return "emphasis";
        case "link":
          return "link";
        case "image":
          return "image";
        case "codeSpan":
          return "codespan";
        case "strikethrough":
          return "strikethrough";
        default:
          return undefined;
      }
    };
    const metadata = (entry, event) => {
      switch (entry.kind) {
        case "heading": {
          const result = { level: entry.data };
          if (event.primary !== null) result.id = event.primary;
          return result;
        }
        case "orderedList":
          return { ordered: true, start: entry.data, depth: entry.depth };
        case "unorderedList":
          return { ordered: false, start: undefined, depth: entry.depth };
        case "listItem":
          return {
            index: entry.index,
            depth: entry.depth,
            ordered: entry.ordered,
            start: entry.start,
            checked: entry.checked === null ? undefined : entry.checked,
          };
        case "code":
          return entry.primary === null ? undefined : { language: entry.primary };
        case "tableHeaderCell":
        case "tableCell":
          return { align: entry.primary === null ? undefined : entry.primary };
        case "link":
          return { href: entry.primary, title: entry.secondary === null ? undefined : entry.secondary };
        case "image": {
          const result = { src: entry.primary };
          if (entry.secondary !== null) result.title = entry.secondary;
          return result;
        }
        default:
          return undefined;
      }
    };
    const invoke = (callback, children, meta) => {
      const value =
        meta === undefined ? callback.$call(undefined, children) : callback.$call(undefined, children, meta);
      return value === undefined || value === null ? "" : `${value}`;
    };

    for (let index = 0; index < events.length; index++) {
      const event = events[index];
      const parent = stack[stack.length - 1];
      if (event.phase === "text") {
        const callback = handlers.text;
        append(parent, callback === undefined ? event.primary : invoke(callback, event.primary, undefined));
        continue;
      }
      if (event.phase === "rawText") {
        append(parent, event.primary);
        continue;
      }
      if (event.phase === "hardBreak") {
        append(parent, "\n");
        continue;
      }
      if (event.phase === "enter") {
        const entry = {
          kind: event.kind,
          data: event.data,
          primary: event.primary,
          secondary: event.secondary,
          checked: event.checked,
          children: [],
          depth: 0,
          index: 0,
          ordered: false,
          start: undefined,
          nextIndex: 0,
        };
        if (event.kind === "orderedList" || event.kind === "unorderedList") {
          entry.depth = countLists();
        } else if (event.kind === "listItem") {
          const list = stack[stack.length - 1];
          entry.index = list.nextIndex++;
          entry.depth = countLists() - 1;
          entry.ordered = list.kind === "orderedList";
          entry.start = entry.ordered ? list.data : undefined;
        }
        stack[stack.length] = entry;
        continue;
      }

      const entry = stack[stack.length - 1];
      stack.length--;
      const children = concatenate(entry);
      const name = callbackName(entry.kind);
      const callback = name === undefined ? undefined : handlers[name];
      append(
        stack[stack.length - 1],
        callback === undefined ? children : invoke(callback, children, metadata(entry, event)),
      );
    }

    return concatenate(stack[0]);
  } finally {
    session.release();
  }
}

export function react(input: unknown, components?: unknown, options?: unknown): unknown {
  const ParseSession = $bindgenClass("MarkdownObject.schema.zig", "MarkdownParseSession") as {
    new (input: unknown): MarkdownParseSession;
  };
  const session = new ParseSession(input);

  try {
    const componentNames = [
      "h1",
      "h2",
      "h3",
      "h4",
      "h5",
      "h6",
      "p",
      "blockquote",
      "ul",
      "ol",
      "li",
      "pre",
      "hr",
      "html",
      "table",
      "thead",
      "tbody",
      "tr",
      "th",
      "td",
      "em",
      "strong",
      "a",
      "img",
      "code",
      "del",
      "math",
      "u",
      "br",
    ];
    const replacements = {};
    if (components !== undefined && components !== null) {
      if (typeof components !== "object" && typeof components !== "function") {
        throw new TypeError("Markdown components must be an object");
      }
      for (let index = 0; index < componentNames.length; index++) {
        const name = componentNames[index];
        const component = components[name];
        if (typeof component !== "boolean" && !!component) replacements[name] = component;
      }
    }

    const { events, legacy } = session.parse(options);
    const elementSymbol = Symbol.for(legacy ? "react.element" : "react.transitional.element");
    const fragmentSymbol = Symbol.for("react.fragment");
    const stack = [{ kind: "none", children: [] }];

    const append = (entry, value) => {
      entry.children[entry.children.length] = value;
    };
    const tagName = entry => {
      switch (entry.kind) {
        case "heading":
          return `h${entry.data}`;
        case "paragraph":
          return "p";
        case "blockquote":
          return "blockquote";
        case "code":
          return "pre";
        case "unorderedList":
          return "ul";
        case "orderedList":
          return "ol";
        case "listItem":
          return "li";
        case "horizontalRule":
          return "hr";
        case "table":
          return "table";
        case "tableHead":
          return "thead";
        case "tableBody":
          return "tbody";
        case "tableRow":
          return "tr";
        case "tableHeaderCell":
          return "th";
        case "tableCell":
          return "td";
        case "html":
          return "html";
        case "emphasis":
          return "em";
        case "strong":
          return "strong";
        case "link":
        case "wikiLink":
          return "a";
        case "image":
          return "img";
        case "codeSpan":
          return "code";
        case "strikethrough":
          return "del";
        case "math":
        case "mathDisplay":
          return "math";
        case "underline":
          return "u";
      }
    };
    const element = (tag, props) => {
      const replacement = replacements[tag];
      return {
        $$typeof: elementSymbol,
        type: replacement === undefined ? tag : replacement,
        key: null,
        ref: null,
        props,
      };
    };
    const properties = (entry, event) => {
      const props = {};
      switch (entry.kind) {
        case "heading":
          if (event.primary !== null) props.id = event.primary;
          break;
        case "orderedList":
          props.start = entry.data;
          break;
        case "listItem":
          if (entry.checked !== null) props.checked = entry.checked;
          break;
        case "code":
          if (entry.primary !== null) props.language = entry.primary;
          break;
        case "tableHeaderCell":
        case "tableCell":
          if (entry.primary !== null) props.align = entry.primary;
          break;
        case "link":
          props.href = entry.primary;
          if (entry.secondary !== null) props.title = entry.secondary;
          break;
        case "image":
          props.src = entry.primary;
          if (entry.secondary !== null) props.title = entry.secondary;
          break;
        case "wikiLink":
          props.target = entry.primary;
          break;
        case "mathDisplay":
          props.display = true;
          break;
      }

      if (entry.kind === "image") {
        let alt: string | undefined;
        for (let index = 0; index < entry.children.length; index++) {
          const child = entry.children[index];
          if (typeof child === "string") alt = alt === undefined ? child : alt + child;
        }
        if (alt !== undefined) props.alt = alt;
      } else if (entry.kind !== "horizontalRule") {
        props.children = entry.children;
      }
      return props;
    };

    for (let index = 0; index < events.length; index++) {
      const event = events[index];
      const parent = stack[stack.length - 1];
      if (event.phase === "text" || event.phase === "rawText") {
        append(parent, event.primary);
        continue;
      }
      if (event.phase === "hardBreak") {
        append(parent, element("br", {}));
        continue;
      }
      if (event.phase === "enter") {
        stack[stack.length] = {
          kind: event.kind,
          data: event.data,
          primary: event.primary,
          secondary: event.secondary,
          checked: event.checked,
          children: [],
        };
        continue;
      }

      const entry = stack[stack.length - 1];
      stack.length--;
      append(stack[stack.length - 1], element(tagName(entry), properties(entry, event)));
    }

    return {
      $$typeof: elementSymbol,
      type: fragmentSymbol,
      key: null,
      ref: null,
      props: { children: stack[0].children },
    };
  } finally {
    session.release();
  }
}
