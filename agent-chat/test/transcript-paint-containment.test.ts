// WKWebView keeps GPU backing memory for the #messages scroller's content
// while a live chat streams, unless the transcript is a paint-containment
// boundary: cmux Home chat pages grew past 3 GB within an hour without it.
const css = await Bun.file("public/app.css").text();

const rule = /\.turn-list\s*\{([^}]*)\}/.exec(css);
if (!rule) throw new Error("missing .turn-list rule");
if (!/contain:\s*[^;]*\b(paint|content|strict)\b/.test(rule[1])) {
  throw new Error(".turn-list must use paint containment so streaming chats don't grow GPU memory");
}

console.log("transcript paint containment: OK");

export {};
