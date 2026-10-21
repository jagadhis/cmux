// Remark plugins for how replies render beyond plain GFM.

import type { Blockquote, Code, Paragraph, Root, RootContent, Text } from "mdast";

export const ALERT_KINDS = ["note", "tip", "important", "warning", "caution"] as const;
export type AlertKind = (typeof ALERT_KINDS)[number];

const ALERT_MARKER = /^\[!(note|tip|important|warning|caution)\][^\S\n]*(?:\n|$)/i;

type Parent = { children: RootContent[] };

function eachNode(node: Parent, visit: (child: RootContent) => void) {
  for (const child of node.children) {
    visit(child);
    if ("children" in child) eachNode(child as Parent, visit);
  }
}

/// GitHub alerts: a blockquote that opens with `[!NOTE]`, `[!TIP]`,
/// `[!IMPORTANT]`, `[!WARNING]` or `[!CAUTION]` becomes a titled callout. The
/// marker is removed; the blockquote carries the kind as classes that survive
/// sanitizing (see the schema in ChatMarkdown).
export function remarkAlerts() {
  return function transform(tree: Root) {
    eachNode(tree, (node) => {
      if (node.type !== "blockquote") return;
      const quote = node as Blockquote;
      const first = quote.children[0];
      if (first?.type !== "paragraph") return;
      const lead = (first as Paragraph).children[0];
      if (lead?.type !== "text") return;
      const match = ALERT_MARKER.exec((lead as Text).value);
      if (!match) return;
      const kind = match[1].toLowerCase() as AlertKind;
      (lead as Text).value = (lead as Text).value.slice(match[0].length);
      if (!(lead as Text).value) first.children.shift();
      // A marker on its own line leaves a break before the body.
      if (first.children[0]?.type === "break") first.children.shift();
      if (first.children.length === 0) quote.children.shift();
      quote.data = { ...quote.data, hProperties: { className: ["markdown-alert", `markdown-alert-${kind}`] } };
    });
  };
}

/// Carries a fence's meta (the text after its language, such as
/// `title="src/a.ts"`) to the rendered `<code>` as `data-meta`, where the code
/// block reads the file name from it.
export function remarkCodeMeta() {
  return function transform(tree: Root) {
    eachNode(tree, (node) => {
      if (node.type !== "code") return;
      const code = node as Code;
      if (!code.meta) return;
      const hProperties = { ...(code.data?.hProperties ?? {}), dataMeta: code.meta };
      code.data = { ...code.data, hProperties };
    });
  };
}
