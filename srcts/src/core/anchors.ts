// Comment-anchor registry. Control-flow nodes and Each items are represented in
// the DOM as a pair of comment markers (<!--irid:s:ID--> ... <!--irid:e:ID-->)
// rather than a wrapper element, so they stay valid inside restricted parents
// (<select>, <table>, <ul>). We maintain id -> {start, end} and keep it in sync
// as content is inserted/removed.

import { destroyWidgetsIn } from "./widgets";

interface AnchorPair {
  start: Comment;
  end: Comment;
}

export const anchors = new Map<string, AnchorPair>();
const ANCHOR_RE = /^irid:(s|e):(.+)$/;

export function indexAnchors(root: Node): void {
  const walker = document.createTreeWalker(root, NodeFilter.SHOW_COMMENT);
  const starts: Record<string, Comment> = {};
  let node: Node | null;
  while ((node = walker.nextNode())) {
    const comment = node as Comment;
    const m = comment.data.match(ANCHOR_RE);
    if (!m) continue;
    const kind = m[1];
    const id = m[2];
    if (kind === "s") {
      starts[id] = comment;
    } else if (starts[id]) {
      anchors.set(id, { start: starts[id], end: comment });
      delete starts[id];
    }
  }
}

export function unregisterAnchorsIn(root: Node): void {
  // root may be a DocumentFragment, Element, or a detached Comment.
  if (root.nodeType === 8) {
    const m = (root as Comment).data.match(ANCHOR_RE);
    if (m) anchors.delete(m[2]);
    return;
  }
  const walker = document.createTreeWalker(root, NodeFilter.SHOW_COMMENT);
  let n: Node | null;
  while ((n = walker.nextNode())) {
    const m2 = (n as Comment).data.match(ANCHOR_RE);
    if (m2) anchors.delete(m2[2]);
  }
}

// Parse HTML into a fragment using the anchor's parent as the parsing context, so
// restricted-content elements (<option>, <tr>, etc.) parse correctly.
export function parseFragment(html: string, contextNode: Node): DocumentFragment {
  const range = document.createRange();
  range.selectNodeContents(contextNode);
  return range.createContextualFragment(html);
}

// Move the full range [start..end] (inclusive) into a detached fragment. Runs
// widget destroy() then Shiny.unbindAll on element nodes in the range.
export function detachRange(startNode: Node, endNode: Node): DocumentFragment {
  const frag = document.createDocumentFragment();
  let n: Node | null = startNode;
  while (n && n !== endNode) {
    const next: Node | null = n.nextSibling;
    if (n.nodeType === 1) {
      // Destroy widget instances first, before unbindAll and before we move the
      // node into a detached fragment — destroy() hooks may want intact ancestors.
      destroyWidgetsIn(n);
      Shiny.unbindAll!(n as Element);
    }
    frag.appendChild(n);
    n = next;
  }
  frag.appendChild(endNode);
  return frag;
}

// Look up anchors with a lazy re-scan fallback. Dynamic content delivered via
// renderUI/iridOutput arrives as a Shiny output binding update (not a custom
// message), so we index its anchors on a miss before the swap/mutate fires.
export function lookupAnchors(id: string): AnchorPair | undefined {
  const a = anchors.get(id);
  if (a) return a;
  indexAnchors(document.body);
  return anchors.get(id);
}
