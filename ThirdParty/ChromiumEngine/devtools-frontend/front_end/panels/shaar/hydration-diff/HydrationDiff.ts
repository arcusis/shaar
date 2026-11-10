// Copyright 2026 The Shaar Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

export const MISMATCH_LIMIT = 80;

const SKIPPED_TAGS = new Set(['script', 'style', 'noscript', 'link']);
const IGNORED_ATTRIBUTES = new Set([
  'nonce',
  'data-reactroot',
  'data-reactid',
  'data-react-checksum',
]);
const MOUNT_IDS = new Set([
  'root',
  'app',
  '__next',
  '__nuxt',
  '___gatsby',
  'app-root',
  'svelte',
  'q-app',
  '__sapper',
]);
// These render with no text child. A mount that only holds them is not an empty shell.
const RENDERED_TAGS = new Set([
  'audio',
  'canvas',
  'embed',
  'iframe',
  'img',
  'input',
  'math',
  'object',
  'picture',
  'select',
  'svg',
  'textarea',
  'video',
]);
// A rows-by-columns matrix past this many cells is not allocated. The middle
// then matches keys in order instead.
const ALIGN_CELL_CAP = 4096;

export type HydrationNotice = 'not-html'|'client-shell-empty'|'client-shell-mount';

export interface HydrationAttribute {
  name: string;
  value: string;
}

export interface HydrationNode {
  kind: 'element'|'text';
  name: string;
  value: string;
  attributes: HydrationAttribute[];
  children: HydrationNode[];
  backendNodeId: number|null;
}

export interface HydrationMismatch {
  path: string;
  kind: 'missing'|'extra'|'attribute'|'text';
  attributeName: string;
  server: string;
  page: string;
  backendNodeId: number|null;
}

export interface HydrationReport {
  notice: HydrationNotice|null;
  mismatches: HydrationMismatch[];
  truncated: boolean;
}

export interface SnapshotRareString {
  index?: number[];
  value?: number[];
}

export interface SnapshotNodes {
  parentIndex?: number[];
  nodeType?: number[];
  nodeName?: number[];
  nodeValue?: number[];
  backendNodeId?: number[];
  attributes?: number[][];
  shadowRootType?: SnapshotRareString;
  pseudoType?: SnapshotRareString;
}

export interface SnapshotPayload {
  documents?: Array<{nodes?: SnapshotNodes}>;
  strings?: string[];
}

interface AlignPair {
  left: HydrationNode|null;
  right: HydrationNode|null;
}

export function looksLikeHTML(html: string): boolean {
  return /<\/?[a-z][\s\S]*>/i.test(html);
}

export function emptyBody(): HydrationNode {
  return elementNode('body');
}

export function elementNode(
    name: string, attributes: HydrationAttribute[] = [], children: HydrationNode[] = [],
    backendNodeId: number|null = null): HydrationNode {
  return {
    kind: 'element',
    name: name.toLowerCase(),
    value: '',
    attributes: normalizeAttributes(attributes),
    children,
    backendNodeId,
  };
}

export function textNode(value: string, backendNodeId: number|null = null): HydrationNode {
  return {
    kind: 'text',
    name: '#text',
    value: normalizeText(value),
    attributes: [],
    children: [],
    backendNodeId,
  };
}

export function bodyNode(children: HydrationNode[]): HydrationNode {
  return elementNode('body', [], children);
}

export function treeFromHTML(html: string): HydrationNode {
  if (typeof DOMParser === 'undefined') {
    throw new Error('DOMParser is not available');
  }
  const document = new DOMParser().parseFromString(html, 'text/html');
  return treeFromDOMNode(document.body);
}

export function treeFromSnapshot(snapshot: SnapshotPayload): HydrationNode {
  const document = snapshot.documents?.[0];
  const nodes = document?.nodes;
  const strings = snapshot.strings ?? [];
  if (!nodes?.nodeName || !nodes.nodeType) {
    return emptyBody();
  }
  const count = nodes.nodeName.length;
  const skipped = skippedNodeIndexes(nodes, count);
  const childrenOf = new Map<number, number[]>();
  let root = -1;
  for (let index = 0; index < count; index++) {
    if (skipped.has(index)) {
      continue;
    }
    const parent = nodes.parentIndex?.[index] ?? -1;
    if (parent < 0 || skipped.has(parent)) {
      if (root < 0) {
        root = index;
      }
      continue;
    }
    const children = childrenOf.get(parent) ?? [];
    children.push(index);
    childrenOf.set(parent, children);
  }
  const bodyIndex = root < 0 ? -1 : findBodyIndex(root, nodes, strings, childrenOf);
  if (bodyIndex < 0) {
    return emptyBody();
  }
  return convertSnapshotNode(bodyIndex, nodes, strings, childrenOf) ?? emptyBody();
}

export function diffServerHTML(
    html: string, hydrated: HydrationNode|null,
    parse: (html: string) => HydrationNode = treeFromHTML): HydrationReport {
  if (!looksLikeHTML(html)) {
    return {notice: 'not-html', mismatches: [], truncated: false};
  }
  let server: HydrationNode;
  try {
    server = parse(html);
  } catch {
    return {notice: 'not-html', mismatches: [], truncated: false};
  }
  return diffHydrationTrees(server, hydrated);
}

export function diffHydrationTrees(server: HydrationNode|null, hydrated: HydrationNode|null): HydrationReport {
  const serverBody = server ?? emptyBody();
  const hydratedBody = hydrated ?? emptyBody();
  const report: HydrationReport = {
    notice: clientShellNotice(serverBody, hydratedBody),
    mismatches: [],
    truncated: false,
  };
  diffNodes(serverBody, hydratedBody, 'body', report);
  return report;
}

function clientShellNotice(server: HydrationNode, hydrated: HydrationNode): HydrationNotice|null {
  if (!hasRenderedContent(hydrated)) {
    return null;
  }
  if (server.children.length === 0) {
    return 'client-shell-empty';
  }
  if (server.children.every(isEmptyMount)) {
    return 'client-shell-mount';
  }
  return null;
}

function hasRenderedContent(body: HydrationNode): boolean {
  return body.children.some(child => !isEmptyMount(child));
}

function isEmptyMount(node: HydrationNode): boolean {
  if (node.kind !== 'element') {
    return false;
  }
  const id = attributeValue(node, 'id');
  if (!MOUNT_IDS.has(id)) {
    return false;
  }
  return node.children.every(isEmptyElement);
}

function isEmptyElement(node: HydrationNode): boolean {
  if (node.kind === 'text') {
    return node.value.length === 0;
  }
  if (RENDERED_TAGS.has(node.name)) {
    return false;
  }
  return node.children.every(isEmptyElement);
}

function diffNodes(server: HydrationNode, hydrated: HydrationNode, path: string, report: HydrationReport): void {
  if (report.truncated) {
    return;
  }
  if (server.kind === 'text' || hydrated.kind === 'text') {
    diffText(server, hydrated, path, report);
    return;
  }
  diffAttributes(server, hydrated, path, report);
  diffChildren(server.children, hydrated.children, path, hydrated.backendNodeId, report);
}

function diffText(server: HydrationNode, hydrated: HydrationNode, path: string, report: HydrationReport): void {
  if (server.value === hydrated.value) {
    return;
  }
  pushMismatch(report, {
    path,
    kind: 'text',
    attributeName: '',
    server: server.value,
    page: hydrated.value,
    backendNodeId: hydrated.backendNodeId,
  });
}

function diffAttributes(server: HydrationNode, hydrated: HydrationNode, path: string, report: HydrationReport): void {
  const serverAttributes = attributeMap(server);
  const pageAttributes = attributeMap(hydrated);
  const names = new Set([...serverAttributes.keys(), ...pageAttributes.keys()]);
  for (const name of [...names].sort()) {
    const serverValue = serverAttributes.get(name) ?? '';
    const pageValue = pageAttributes.get(name) ?? '';
    if (serverValue === pageValue) {
      continue;
    }
    pushMismatch(report, {
      path,
      kind: 'attribute',
      attributeName: name,
      server: serverValue,
      page: pageValue,
      backendNodeId: hydrated.backendNodeId,
    });
  }
}

function diffChildren(
    serverChildren: HydrationNode[], hydratedChildren: HydrationNode[], path: string,
    parentBackendNodeId: number|null, report: HydrationReport): void {
  const pairs = alignByKey(serverChildren, hydratedChildren, nodeKey);
  for (const pair of pairs) {
    if (report.truncated) {
      return;
    }
    if (pair.left && pair.right) {
      diffNodes(pair.left, withFallbackId(pair.right, parentBackendNodeId), childPath(path, pair.right), report);
      continue;
    }
    if (pair.left) {
      pushMismatch(report, {
        path: childPath(path, pair.left),
        kind: 'missing',
        attributeName: '',
        server: nodeSummary(pair.left),
        page: '',
        backendNodeId: null,
      });
      continue;
    }
    if (pair.right) {
      const pageNode = withFallbackId(pair.right, parentBackendNodeId);
      pushMismatch(report, {
        path: childPath(path, pageNode),
        kind: 'extra',
        attributeName: '',
        server: '',
        page: nodeSummary(pageNode),
        backendNodeId: pageNode.backendNodeId,
      });
    }
  }
}

function withFallbackId(node: HydrationNode, parentBackendNodeId: number|null): HydrationNode {
  if (node.kind !== 'text' || node.backendNodeId !== null || parentBackendNodeId === null) {
    return node;
  }
  return {...node, backendNodeId: parentBackendNodeId};
}

function pushMismatch(report: HydrationReport, mismatch: HydrationMismatch): void {
  if (report.mismatches.length >= MISMATCH_LIMIT) {
    report.truncated = true;
    return;
  }
  report.mismatches.push(mismatch);
}

function alignByKey(left: HydrationNode[], right: HydrationNode[], key: (node: HydrationNode) => string): AlignPair[] {
  const leftKeys = left.map(key);
  const rightKeys = right.map(key);
  let prefix = 0;
  const shared = Math.min(leftKeys.length, rightKeys.length);
  while (prefix < shared && leftKeys[prefix] === rightKeys[prefix]) {
    prefix++;
  }
  let suffix = 0;
  while (suffix < shared - prefix &&
         leftKeys[leftKeys.length - 1 - suffix] === rightKeys[rightKeys.length - 1 - suffix]) {
    suffix++;
  }
  const pairs: AlignPair[] = [];
  for (let index = 0; index < prefix; index++) {
    pairs.push({left: left[index], right: right[index]});
  }
  const middleLeft = left.slice(prefix, left.length - suffix);
  const middleRight = right.slice(prefix, right.length - suffix);
  if (middleLeft.length > 0 || middleRight.length > 0) {
    const middle = alignMiddle(
        middleLeft, middleRight, leftKeys.slice(prefix, leftKeys.length - suffix),
        rightKeys.slice(prefix, rightKeys.length - suffix));
    for (const pair of middle) {
      pairs.push(pair);
    }
  }
  for (let index = 0; index < suffix; index++) {
    pairs.push({
      left: left[left.length - suffix + index],
      right: right[right.length - suffix + index],
    });
  }
  return pairs;
}

function alignMiddle(
    left: HydrationNode[], right: HydrationNode[], leftKeys: string[], rightKeys: string[]): AlignPair[] {
  if (leftKeys.length * rightKeys.length > ALIGN_CELL_CAP) {
    return alignInKeyOrder(left, right, leftKeys, rightKeys);
  }
  const scores = alignmentScores(leftKeys, rightKeys);
  const pairs: AlignPair[] = [];
  let i = 0;
  let j = 0;
  while (i < left.length && j < right.length) {
    if (leftKeys[i] === rightKeys[j]) {
      pairs.push({left: left[i], right: right[j]});
      i++;
      j++;
      continue;
    }
    if (scores[i + 1][j] >= scores[i][j + 1]) {
      pairs.push({left: left[i], right: null});
      i++;
      continue;
    }
    pairs.push({left: null, right: right[j]});
    j++;
  }
  while (i < left.length) {
    pairs.push({left: left[i], right: null});
    i++;
  }
  while (j < right.length) {
    pairs.push({left: null, right: right[j]});
    j++;
  }
  return pairs;
}

function alignmentScores(leftKeys: string[], rightKeys: string[]): number[][] {
  const rows = leftKeys.length;
  const columns = rightKeys.length;
  if (rows * columns > ALIGN_CELL_CAP) {
    throw new Error('alignment matrix exceeds the cell cap');
  }
  const scores: number[][] = [];
  for (let i = 0; i <= rows; i++) {
    scores.push(new Array<number>(columns + 1).fill(0));
  }
  for (let i = rows - 1; i >= 0; i--) {
    for (let j = columns - 1; j >= 0; j--) {
      if (leftKeys[i] === rightKeys[j]) {
        scores[i][j] = scores[i + 1][j + 1] + 1;
      } else {
        scores[i][j] = Math.max(scores[i + 1][j], scores[i][j + 1]);
      }
    }
  }
  return scores;
}

function alignInKeyOrder(
    left: HydrationNode[], right: HydrationNode[], leftKeys: string[], rightKeys: string[]): AlignPair[] {
  const buckets = new Map<string, number[]>();
  for (let index = 0; index < rightKeys.length; index++) {
    const key = rightKeys[index];
    let bucket = buckets.get(key);
    if (!bucket) {
      bucket = [];
      buckets.set(key, bucket);
    }
    bucket.push(index);
  }
  const cursor = new Map<string, number>();
  const matchedRight = new Array<number>(left.length).fill(-1);
  let lastRight = -1;
  for (let index = 0; index < left.length; index++) {
    const key = leftKeys[index];
    const bucket = buckets.get(key);
    if (!bucket) {
      continue;
    }
    let position = cursor.get(key) ?? 0;
    while (position < bucket.length && bucket[position] <= lastRight) {
      position++;
    }
    if (position >= bucket.length) {
      cursor.set(key, position);
      continue;
    }
    matchedRight[index] = bucket[position];
    lastRight = bucket[position];
    cursor.set(key, position + 1);
  }
  return pairsFromMatches(left, right, matchedRight);
}

function pairsFromMatches(left: HydrationNode[], right: HydrationNode[], matchedRight: number[]): AlignPair[] {
  const pairs: AlignPair[] = [];
  let rightIndex = 0;
  for (let leftIndex = 0; leftIndex < left.length; leftIndex++) {
    const match = matchedRight[leftIndex];
    if (match < 0) {
      pairs.push({left: left[leftIndex], right: null});
      continue;
    }
    while (rightIndex < match) {
      pairs.push({left: null, right: right[rightIndex]});
      rightIndex++;
    }
    pairs.push({left: left[leftIndex], right: right[match]});
    rightIndex = match + 1;
  }
  while (rightIndex < right.length) {
    pairs.push({left: null, right: right[rightIndex]});
    rightIndex++;
  }
  return pairs;
}

function nodeKey(node: HydrationNode): string {
  if (node.kind === 'text') {
    return '#text';
  }
  const id = attributeValue(node, 'id');
  return id ? `${node.name}#${id}` : node.name;
}

function childPath(parent: string, node: HydrationNode): string {
  return `${parent} > ${nodeLabel(node)}`;
}

function nodeLabel(node: HydrationNode): string {
  if (node.kind === 'text') {
    return '#text';
  }
  const id = attributeValue(node, 'id');
  return id ? `${node.name}#${id}` : node.name;
}

function nodeSummary(node: HydrationNode): string {
  if (node.kind === 'text') {
    return clip(node.value);
  }
  return nodeLabel(node);
}

function clip(value: string): string {
  if (value.length <= 120) {
    return value;
  }
  return `${value.slice(0, 117)}...`;
}

function attributeMap(node: HydrationNode): Map<string, string> {
  const values = new Map<string, string>();
  for (const attribute of node.attributes) {
    values.set(attribute.name, attribute.value);
  }
  return values;
}

function attributeValue(node: HydrationNode, name: string): string {
  return node.attributes.find(attribute => attribute.name === name)?.value ?? '';
}

function treeFromDOMNode(node: ParentNode|null): HydrationNode {
  if (!node) {
    return emptyBody();
  }
  const converted = convertDOMNode(node as unknown as DOMLike);
  if (!converted || converted.name !== 'body') {
    return emptyBody();
  }
  return converted;
}

interface DOMLike {
  nodeType: number;
  nodeName: string;
  nodeValue: string|null;
  childNodes?: ArrayLike<DOMLike>;
  attributes?: ArrayLike<{name: string, value: string}>;
}

function convertDOMNode(node: DOMLike): HydrationNode|null {
  if (node.nodeType === 3) {
    const value = normalizeText(node.nodeValue ?? '');
    if (!value) {
      return null;
    }
    return textNode(value);
  }
  if (node.nodeType !== 1) {
    return null;
  }
  const name = node.nodeName.toLowerCase();
  if (SKIPPED_TAGS.has(name)) {
    return null;
  }
  const children: HydrationNode[] = [];
  const childNodes = node.childNodes ?? [];
  for (let index = 0; index < childNodes.length; index++) {
    const child = convertDOMNode(childNodes[index]);
    if (child) {
      children.push(child);
    }
  }
  const attributes: HydrationAttribute[] = [];
  const sourceAttributes = node.attributes ?? [];
  for (let index = 0; index < sourceAttributes.length; index++) {
    attributes.push({name: sourceAttributes[index].name, value: sourceAttributes[index].value});
  }
  return elementNode(name, attributes, children);
}

function skippedNodeIndexes(nodes: SnapshotNodes, count: number): Set<number> {
  const skipped = new Set<number>();
  markRare(skipped, nodes.shadowRootType);
  markRare(skipped, nodes.pseudoType);
  const parents = nodes.parentIndex ?? [];
  for (let index = 0; index < count; index++) {
    const parent = parents[index] ?? -1;
    if (parent >= 0 && skipped.has(parent)) {
      skipped.add(index);
    }
  }
  return skipped;
}

function markRare(skipped: Set<number>, rare: SnapshotRareString|undefined): void {
  for (const index of rare?.index ?? []) {
    skipped.add(index);
  }
}

function findBodyIndex(
    root: number, nodes: SnapshotNodes, strings: string[], childrenOf: Map<number, number[]>): number {
  const pending = [root];
  while (pending.length) {
    const index = pending.pop() ?? -1;
    if (index < 0) {
      continue;
    }
    const name = stringAt(strings, nodes.nodeName?.[index]).toLowerCase();
    if (name === 'body') {
      return index;
    }
    const children = childrenOf.get(index) ?? [];
    for (let child = children.length - 1; child >= 0; child--) {
      pending.push(children[child]);
    }
  }
  return -1;
}

function convertSnapshotNode(
    index: number, nodes: SnapshotNodes, strings: string[],
    childrenOf: Map<number, number[]>): HydrationNode|null {
  const nodeType = nodes.nodeType?.[index] ?? 0;
  if (nodeType === 3) {
    const value = normalizeText(stringAt(strings, nodes.nodeValue?.[index]));
    if (!value) {
      return null;
    }
    return textNode(value, backendId(nodes, index));
  }
  if (nodeType !== 1) {
    return null;
  }
  const name = stringAt(strings, nodes.nodeName?.[index]).toLowerCase();
  if (SKIPPED_TAGS.has(name)) {
    return null;
  }
  const children: HydrationNode[] = [];
  for (const childIndex of childrenOf.get(index) ?? []) {
    const child = convertSnapshotNode(childIndex, nodes, strings, childrenOf);
    if (child) {
      children.push(child);
    }
  }
  return elementNode(name, snapshotAttributes(nodes, strings, index), children, backendId(nodes, index));
}

function snapshotAttributes(nodes: SnapshotNodes, strings: string[], index: number): HydrationAttribute[] {
  const encoded = nodes.attributes?.[index] ?? [];
  const attributes: HydrationAttribute[] = [];
  for (let cursor = 0; cursor + 1 < encoded.length; cursor += 2) {
    attributes.push({
      name: stringAt(strings, encoded[cursor]),
      value: stringAt(strings, encoded[cursor + 1]),
    });
  }
  return attributes;
}

function backendId(nodes: SnapshotNodes, index: number): number|null {
  const id = nodes.backendNodeId?.[index];
  if (id === undefined || id <= 0) {
    return null;
  }
  return id;
}

function stringAt(strings: string[], index: number|undefined): string {
  if (index === undefined || index < 0 || index >= strings.length) {
    return '';
  }
  return strings[index] ?? '';
}

function normalizeAttributes(attributes: HydrationAttribute[]): HydrationAttribute[] {
  const normalized: HydrationAttribute[] = [];
  for (const attribute of attributes) {
    const name = attribute.name.toLowerCase();
    if (IGNORED_ATTRIBUTES.has(name)) {
      continue;
    }
    const value = normalizeAttribute(name, attribute.value);
    if (name === 'class' && !value) {
      continue;
    }
    normalized.push({name, value});
  }
  normalized.sort((left, right) => left.name.localeCompare(right.name));
  return normalized;
}

function normalizeAttribute(name: string, value: string): string {
  const collapsed = normalizeText(value);
  if (name !== 'class') {
    return collapsed;
  }
  return collapsed.split(' ').filter(token => token.length > 0).sort().join(' ');
}

function normalizeText(value: string): string {
  return value.replace(/\s+/g, ' ').trim();
}
