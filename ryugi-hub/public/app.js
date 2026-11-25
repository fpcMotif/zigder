const CHART_COLORS = [
  "#334155",
  "#1d4ed8",
  "#0f766e",
  "#b45309",
  "#6d28d9",
  "#be123c"
];

const DOC_TEMPLATE = `<doc>
  <h1>New Architecture Document</h1>
  <alert type="note">
    <p>Authored in Ryugi Hub and persisted in Cloudflare D1.</p>
  </alert>
  <h2>Context</h2>
  <p>Describe the design decision, tradeoffs, and verification criteria.</p>
  <p>Pick an option: <ask id="decision-1" recommend="option-a"><option value="option-a">Option A (Recommended)</option><option value="option-b">Option B</option></ask></p>
</doc>`;

const WB_TEMPLATE = JSON.stringify(
  {
    type: "excalidraw",
    version: 2,
    source: "ryugi",
    appState: { name: "New Architecture Whiteboard", viewBackgroundColor: "#ffffff" },
    files: {},
    elements: [
      {
        id: "f-main",
        type: "frame",
        name: "System Flow",
        children: ["n-input", "n-core", "a-1"]
      },
      {
        id: "n-input",
        type: "rectangle",
        x: 40,
        y: 60,
        width: 220,
        height: 84,
        backgroundColor: "#eef4ff",
        strokeColor: "#1d4ed8",
        fillStyle: "solid",
        roundness: { type: 3 },
        label: { text: "Client / Request" }
      },
      {
        id: "n-core",
        type: "rectangle",
        x: 380,
        y: 60,
        width: 220,
        height: 84,
        backgroundColor: "#f0fdf4",
        strokeColor: "#15803d",
        fillStyle: "solid",
        roundness: { type: 3 },
        label: { text: "Worker + D1 Storage" }
      },
      {
        id: "a-1",
        type: "arrow",
        x: 260,
        y: 102,
        width: 120,
        height: 0,
        start: { id: "n-input" },
        end: { id: "n-core" },
        label: { text: "REST / JSON" }
      }
    ]
  },
  null,
  2
);

const state = {
  projects: [],
  projectId: "",
  modules: [],
  artifacts: [],
  activeArtifact: null,
  typeFilter: "",
  moduleFilter: "",
  searchQuery: "",
  activeTab: "view",
  wbFrameFilter: "all",
  wbMode: "svg",
  wbZoom: 1,
  deleteConfirmId: "",
  mermaidApi: null
};

const els = {
  projectSelect: document.getElementById("project-select"),
  searchInput: document.getElementById("search-input"),
  planBadge: document.getElementById("plan-badge"),
  typeFilters: document.getElementById("type-filters"),
  moduleFilters: document.getElementById("module-filters"),
  artifactList: document.getElementById("artifact-list"),
  artifactCountLabel: document.getElementById("artifact-count-label"),
  emptyState: document.getElementById("empty-state"),
  workspace: document.getElementById("workspace"),
  artTypePill: document.getElementById("art-type-pill"),
  artSlug: document.getElementById("art-slug"),
  artRevPill: document.getElementById("art-rev-pill"),
  artSizeLabel: document.getElementById("art-size-label"),
  artUpdatedLabel: document.getElementById("art-updated-label"),
  artTitle: document.getElementById("art-title"),
  artModules: document.getElementById("art-modules"),
  tabRevCount: document.getElementById("tab-rev-count"),
  tabCommentCount: document.getElementById("tab-comment-count"),
  docViewer: document.getElementById("doc-viewer"),
  wbViewer: document.getElementById("wb-viewer"),
  wbFramePills: document.getElementById("wb-frame-pills"),
  wbModeToggle: document.getElementById("wb-mode-toggle"),
  wbZoomLabel: document.getElementById("wb-zoom-label"),
  wbCanvasWrap: document.getElementById("wb-canvas-wrap"),
  wbCanvasInner: document.getElementById("wb-canvas-inner"),
  rawViewer: document.getElementById("raw-viewer"),
  editForm: document.getElementById("edit-form"),
  editTitle: document.getElementById("edit-title"),
  editNote: document.getElementById("edit-note"),
  editModulesChecks: document.getElementById("edit-modules-checks"),
  editContent: document.getElementById("edit-content"),
  btnDownloadSource: document.getElementById("btn-download-source"),
  btnDeleteArtifact: document.getElementById("btn-delete-artifact"),
  revisionsTbody: document.getElementById("revisions-tbody"),
  commentForm: document.getElementById("comment-form"),
  commentAuthor: document.getElementById("comment-author"),
  commentBody: document.getElementById("comment-body"),
  commentsList: document.getElementById("comments-list"),
  sidebar: document.getElementById("sidebar"),
  sidebarBackdrop: document.getElementById("sidebar-backdrop"),
  menuToggle: document.getElementById("menu-toggle"),
  modalBackdrop: document.getElementById("modal-backdrop"),
  modalTitle: document.getElementById("modal-title"),
  modalBody: document.getElementById("modal-body"),
  modalClose: document.getElementById("modal-close"),
  toastRegion: document.getElementById("toast-region")
};

function showToast(message, isError = false) {
  const node = document.createElement("div");
  node.className = isError ? "toast error" : "toast";
  node.textContent = message;
  els.toastRegion.appendChild(node);
  setTimeout(() => {
    node.remove();
  }, 3400);
}

function formatBytes(bytes) {
  if (!Number.isFinite(bytes) || bytes < 1024) {
    return `${bytes || 0} B`;
  }
  if (bytes < 1024 * 1024) {
    return `${(bytes / 1024).toFixed(1)} KB`;
  }
  return `${(bytes / (1024 * 1024)).toFixed(2)} MB`;
}

function formatDate(iso) {
  if (!iso) {
    return "";
  }
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) {
    return iso;
  }
  return d.toLocaleString(undefined, {
    month: "short",
    day: "numeric",
    hour: "2-digit",
    minute: "2-digit"
  });
}

function formatChartNumber(val, fmt) {
  if (typeof val !== "number" || !Number.isFinite(val)) {
    return "";
  }
  const unit = fmt && typeof fmt.unit === "string" ? ` ${fmt.unit}` : "";
  if (fmt && fmt.compact && Math.abs(val) >= 1000) {
    if (Math.abs(val) >= 1000000) {
      return `${(val / 1000000).toFixed(1)}M${unit}`;
    }
    return `${(val / 1000).toFixed(1)}k${unit}`;
  }
  if (fmt && typeof fmt.decimals === "number") {
    return `${Number(val.toFixed(fmt.decimals))}${unit}`;
  }
  return `${Number.isInteger(val) ? val : Number(val.toFixed(2))}${unit}`;
}

function getAuthHeaders() {
  const token = sessionStorage.getItem("ryugi_hub_admin_token") || "";
  if (!token) {
    return {};
  }
  return { authorization: `Bearer ${token}` };
}

async function apiFetch(path, options = {}) {
  const method = (options.method || "GET").toUpperCase();
  const headers = {
    ...(options.headers || {}),
    ...(method !== "GET" ? getAuthHeaders() : {})
  };
  if (options.body && typeof options.body === "string" && !headers["content-type"]) {
    headers["content-type"] = "application/json";
  }
  const res = await fetch(path, { ...options, method, headers });
  const text = await res.text();
  let data = null;
  try {
    data = JSON.parse(text);
  } catch {
    data = null;
  }
  if (!res.ok) {
    const errMsg = data && typeof data.error === "string" ? data.error : `HTTP ${res.status}`;
    throw new Error(errMsg);
  }
  return data;
}

function svgEl(tag, attrs = {}, textContent = null) {
  const node = document.createElementNS("http://www.w3.org/2000/svg", tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (v !== undefined && v !== null) {
      node.setAttribute(k, String(v));
    }
  }
  if (textContent !== null) {
    node.textContent = textContent;
  }
  return node;
}

function safeHref(raw) {
  if (!raw || typeof raw !== "string") {
    return null;
  }
  const trimmed = raw.trim();
  if (
    trimmed.startsWith("https://") ||
    trimmed.startsWith("http://") ||
    trimmed.startsWith("/")
  ) {
    return trimmed;
  }
  return null;
}

function toggleMobileSidebar(open) {
  if (open) {
    els.sidebar.classList.add("open");
    els.sidebarBackdrop.hidden = false;
  } else {
    els.sidebar.classList.remove("open");
    els.sidebarBackdrop.hidden = true;
  }
}

async function getMermaid() {
  if (state.mermaidApi) {
    return state.mermaidApi;
  }
  const mod = await import("https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.esm.min.mjs");
  const api = mod.default;
  api.initialize({
    startOnLoad: false,
    securityLevel: "strict",
    theme: "neutral",
    themeVariables: { fontSize: "12px" },
    state: { nodeSpacing: 110, rankSpacing: 85, padding: 16 },
    flowchart: { nodeSpacing: 110, rankSpacing: 85 }
  });
  state.mermaidApi = api;
  return api;
}

function extractRichtextNodes(el) {
  if (el.content && el.content.root && Array.isArray(el.content.root.children)) {
    return el.content.root.children;
  }
  return null;
}

function appendLexicalChildren(parent, children) {
  for (const child of children) {
    if (!child || typeof child !== "object") {
      continue;
    }
    if (child.type === "text") {
      const txt = typeof child.text === "string" ? child.text : "";
      const fmt = typeof child.format === "number" ? child.format : 0;
      let node = document.createTextNode(txt);
      if ((fmt & 16) !== 0) {
        const code = document.createElement("code");
        code.style.background = "rgba(24,24,27,0.06)";
        code.style.padding = "1px 4px";
        code.style.borderRadius = "3px";
        code.style.fontFamily = "var(--font-mono)";
        code.style.fontSize = "0.9em";
        code.appendChild(node);
        node = code;
      }
      if ((fmt & 1) !== 0) {
        const strong = document.createElement("strong");
        strong.appendChild(node);
        node = strong;
      }
      if ((fmt & 2) !== 0) {
        const em = document.createElement("em");
        em.appendChild(node);
        node = em;
      }
      parent.appendChild(node);
    } else if (child.type === "linebreak") {
      parent.appendChild(document.createElement("br"));
    } else if (Array.isArray(child.children)) {
      appendLexicalChildren(parent, child.children);
    }
  }
}

function buildRichtextElement(el) {
  const wrap = document.createElement("div");
  wrap.setAttribute("xmlns", "http://www.w3.org/1999/xhtml");
  wrap.style.background = el.backgroundColor && el.backgroundColor !== "transparent" ? el.backgroundColor : "#f4f6fa";
  wrap.style.border = "1px solid #d4cfc5";
  wrap.style.borderRadius = "8px";
  wrap.style.padding = "12px 16px";
  wrap.style.fontFamily = "-apple-system, BlinkMacSystemFont, Segoe UI, sans-serif";
  wrap.style.fontSize = "13.5px";
  wrap.style.lineHeight = "1.5";
  wrap.style.color = "#18181b";
  wrap.style.boxSizing = "border-box";
  wrap.style.width = "100%";
  wrap.style.height = "100%";

  const lexicalChildren = extractRichtextNodes(el);
  if (lexicalChildren) {
    for (const block of lexicalChildren) {
      if (!block || typeof block !== "object") {
        continue;
      }
      if (block.type === "heading") {
        const tag = /^h[1-6]$/.test(block.tag || "") ? block.tag : "h3";
        const h = document.createElement(tag);
        h.style.margin = "0 0 6px";
        h.style.fontSize = "15px";
        h.style.fontWeight = "700";
        appendLexicalChildren(h, block.children || []);
        wrap.appendChild(h);
      } else {
        const p = document.createElement("p");
        p.style.margin = "0";
        appendLexicalChildren(p, block.children || []);
        wrap.appendChild(p);
      }
    }
    return wrap;
  }

  if (typeof el.xml === "string" && el.xml.trim().length > 0) {
    const parser = new DOMParser();
    const doc = parser.parseFromString(`<root>${el.xml}</root>`, "application/xml");
    if (!doc.querySelector("parsererror")) {
      for (const child of Array.from(doc.documentElement.children)) {
        const node = document.createElement(
          /^h[1-6]$/.test(child.tagName) ? child.tagName : "p"
        );
        node.style.margin = child.tagName.startsWith("h") ? "0 0 6px" : "0";
        if (child.tagName.startsWith("h")) {
          node.style.fontSize = "15px";
          node.style.fontWeight = "700";
        }
        renderInlineXml(child, node);
        wrap.appendChild(node);
      }
      return wrap;
    }
  }

  wrap.textContent = el.text || "";
  return wrap;
}

function getElementBounds(el, allById) {
  if (el.type === "frame") {
    if (typeof el.width === "number" && typeof el.height === "number") {
      return { x: el.x || 0, y: el.y || 0, w: el.width, h: el.height };
    }
    const kids = Array.isArray(el.children) ? el.children : [];
    let minX = Infinity;
    let minY = Infinity;
    let maxX = -Infinity;
    let maxY = -Infinity;
    for (const cid of kids) {
      const child = allById.get(cid);
      if (!child || child.isDeleted) {
        continue;
      }
      const b = getElementBounds(child, allById);
      minX = Math.min(minX, b.x);
      minY = Math.min(minY, b.y);
      maxX = Math.max(maxX, b.x + b.w);
      maxY = Math.max(maxY, b.y + b.h);
    }
    if (!Number.isFinite(minX)) {
      return { x: 0, y: 0, w: 400, h: 240 };
    }
    return { x: minX - 24, y: minY - 24, w: maxX - minX + 48, h: maxY - minY + 48 };
  }

  if (el.type === "arrow" || el.type === "line") {
    const pts = Array.isArray(el.points) && el.points.length >= 2
      ? el.points
      : [[0, 0], [el.width || 0, el.height || 0]];
    const ox = el.x || 0;
    const oy = el.y || 0;
    let minX = Infinity;
    let minY = Infinity;
    let maxX = -Infinity;
    let maxY = -Infinity;
    for (const pt of pts) {
      const px = ox + (pt[0] || 0);
      const py = oy + (pt[1] || 0);
      minX = Math.min(minX, px);
      minY = Math.min(minY, py);
      maxX = Math.max(maxX, px);
      maxY = Math.max(maxY, py);
    }
    return { x: minX, y: minY, w: Math.max(1, maxX - minX), h: Math.max(1, maxY - minY) };
  }

  const w = typeof el.width === "number" ? el.width : 200;
  const h = typeof el.height === "number" ? el.height : el.type === "richtext" ? 130 : 80;
  return { x: el.x || 0, y: el.y || 0, w, h };
}

function renderExcalidrawSvg(scene, frameIdFilter = "all") {
  const rawElements = Array.isArray(scene.elements) ? scene.elements : [];
  const active = rawElements.filter((el) => el && !el.isDeleted);
  const byId = new Map();
  for (const el of active) {
    if (el.id) {
      byId.set(el.id, el);
    }
  }

  let visible = active;
  let targetFrame = null;
  if (frameIdFilter && frameIdFilter !== "all") {
    targetFrame = byId.get(frameIdFilter) || null;
    if (targetFrame) {
      const childSet = new Set(Array.isArray(targetFrame.children) ? targetFrame.children : []);
      visible = active.filter(
        (el) => el.id === targetFrame.id || el.frameId === targetFrame.id || childSet.has(el.id)
      );
      const visibleIds = new Set(visible.map((e) => e.id));
      for (const el of active) {
        if (el.containerId && visibleIds.has(el.containerId) && !visibleIds.has(el.id)) {
          visible.push(el);
          visibleIds.add(el.id);
        }
      }
    }
  }

  let minX = Infinity;
  let minY = Infinity;
  let maxX = -Infinity;
  let maxY = -Infinity;

  if (targetFrame) {
    const fb = getElementBounds(targetFrame, byId);
    minX = fb.x;
    minY = fb.y - 26;
    maxX = fb.x + fb.w;
    maxY = fb.y + fb.h;
  } else {
    for (const el of visible) {
      const b = getElementBounds(el, byId);
      const topPad = el.type === "frame" ? 26 : 0;
      minX = Math.min(minX, b.x);
      minY = Math.min(minY, b.y - topPad);
      maxX = Math.max(maxX, b.x + b.w);
      maxY = Math.max(maxY, b.y + b.h);
    }
  }

  if (!Number.isFinite(minX)) {
    minX = 0;
    minY = 0;
    maxX = 640;
    maxY = 360;
  }

  const pad = 24;
  const vbX = Math.floor(minX - pad);
  const vbY = Math.floor(minY - pad);
  const vbW = Math.max(160, Math.ceil(maxX - minX + pad * 2));
  const vbH = Math.max(120, Math.ceil(maxY - minY + pad * 2));

  const svg = svgEl("svg", {
    viewBox: `${vbX} ${vbY} ${vbW} ${vbH}`,
    width: vbW,
    height: vbH,
    style: "max-width: 100%; height: auto; display: block; background: #ffffff; border-radius: 8px;"
  });

  const defs = svgEl("defs");
  const filter = svgEl("filter", { id: "ryugi-shadow", x: "-10%", y: "-10%", width: "120%", height: "130%" });
  filter.appendChild(
    svgEl("feDropShadow", { dx: "0", dy: "2", stdDeviation: "3", "flood-color": "#18181b", "flood-opacity": "0.08" })
  );
  defs.appendChild(filter);
  svg.appendChild(defs);

  const ordered = [
    ...visible.filter((e) => e.type === "frame"),
    ...visible.filter((e) => e.type !== "frame" && e.type !== "text" && e.type !== "arrow" && e.type !== "line"),
    ...visible.filter((e) => e.type === "arrow" || e.type === "line"),
    ...visible.filter((e) => e.type === "text")
  ];

  for (const el of ordered) {
    const b = getElementBounds(el, byId);
    const stroke = el.strokeColor || "#1e1e1e";
    const bg = el.backgroundColor && el.backgroundColor !== "transparent" ? el.backgroundColor : "none";

    if (el.type === "frame") {
      svg.appendChild(
        svgEl("rect", {
          x: b.x,
          y: b.y,
          width: b.w,
          height: b.h,
          rx: 10,
          fill: "none",
          stroke: "#d4cfc5",
          "stroke-width": 1.5
        })
      );
      if (el.name) {
        svg.appendChild(
          svgEl(
            "text",
            {
              x: b.x + 4,
              y: b.y - 8,
              "font-size": 12,
              "font-weight": 600,
              fill: "#78716c"
            },
            el.name
          )
        );
      }
      continue;
    }

    if (el.type === "rectangle") {
      const rect = svgEl("rect", {
        x: b.x,
        y: b.y,
        width: b.w,
        height: b.h,
        rx: el.roundness ? 12 : 0,
        fill: bg,
        stroke,
        "stroke-width": el.strokeWidth || 2
      });
      if (el.shadow) {
        rect.setAttribute("filter", "url(#ryugi-shadow)");
      }
      svg.appendChild(rect);
      if (el.label && typeof el.label.text === "string" && (!el.boundElements || el.boundElements.length === 0)) {
        drawCenteredLines(svg, el.label.text, b.x + b.w / 2, b.y + b.h / 2, stroke, 16);
      }
      continue;
    }

    if (el.type === "ellipse") {
      svg.appendChild(
        svgEl("ellipse", {
          cx: b.x + b.w / 2,
          cy: b.y + b.h / 2,
          rx: b.w / 2,
          ry: b.h / 2,
          fill: bg,
          stroke,
          "stroke-width": el.strokeWidth || 2
        })
      );
      if (el.label && typeof el.label.text === "string" && (!el.boundElements || el.boundElements.length === 0)) {
        drawCenteredLines(svg, el.label.text, b.x + b.w / 2, b.y + b.h / 2, stroke, 16);
      }
      continue;
    }

    if (el.type === "diamond") {
      const cx = b.x + b.w / 2;
      const cy = b.y + b.h / 2;
      svg.appendChild(
        svgEl("polygon", {
          points: `${cx},${b.y} ${b.x + b.w},${cy} ${cx},${b.y + b.h} ${b.x},${cy}`,
          fill: bg,
          stroke,
          "stroke-width": el.strokeWidth || 2
        })
      );
      continue;
    }

    if (el.type === "arrow" || el.type === "line") {
      const pts = Array.isArray(el.points) && el.points.length >= 2
        ? el.points
        : [[0, 0], [el.width || 0, el.height || 0]];
      const ox = el.x || 0;
      const oy = el.y || 0;
      const absPts = pts.map((p) => [ox + (p[0] || 0), oy + (p[1] || 0)]);
      const d = absPts.map((p, idx) => `${idx === 0 ? "M" : "L"} ${p[0]} ${p[1]}`).join(" ");
      svg.appendChild(
        svgEl("path", {
          d,
          fill: "none",
          stroke,
          "stroke-width": el.strokeWidth || 2,
          "stroke-linecap": "round",
          "stroke-linejoin": "round"
        })
      );

      if (el.type === "arrow" && el.endArrowhead !== null) {
        const last = absPts[absPts.length - 1];
        const prev = absPts[absPts.length - 2];
        drawArrowHead(svg, prev[0], prev[1], last[0], last[1], stroke);
      }
      if (el.type === "arrow" && el.startArrowhead === "arrow") {
        drawArrowHead(svg, absPts[1][0], absPts[1][1], absPts[0][0], absPts[0][1], stroke);
      }
      if (el.label && typeof el.label.text === "string" && (!el.boundElements || el.boundElements.length === 0)) {
        const midX = (absPts[0][0] + absPts[absPts.length - 1][0]) / 2;
        const midY = (absPts[0][1] + absPts[absPts.length - 1][1]) / 2;
        drawCenteredLines(svg, el.label.text, midX, midY, stroke, 15, true);
      }
      continue;
    }

    if (el.type === "richtext") {
      const fo = svgEl("foreignObject", {
        x: b.x,
        y: b.y,
        width: b.w,
        height: Math.max(b.h, 110)
      });
      if (el.shadow) {
        fo.setAttribute("filter", "url(#ryugi-shadow)");
      }
      fo.appendChild(buildRichtextElement(el));
      svg.appendChild(fo);
      continue;
    }

    if (el.type === "text") {
      const contentText = typeof el.text === "string" ? el.text : "";
      if (!contentText) {
        continue;
      }
      const container = el.containerId ? byId.get(el.containerId) : null;
      const isArrowLabel = container && (container.type === "arrow" || container.type === "line");
      if (isArrowLabel) {
        svg.appendChild(
          svgEl("rect", {
            x: b.x - 6,
            y: b.y - 2,
            width: b.w + 12,
            height: b.h + 4,
            rx: 5,
            fill: "#ffffff",
            opacity: "0.94"
          })
        );
      }
      const lines = contentText.split("\n");
      const fontSize = Math.min(el.fontSize || 18, 17);
      const lineH = fontSize * (el.lineHeight || 1.25);
      const totalH = lines.length * lineH;
      const startY = b.y + (b.h - totalH) / 2 + fontSize * 0.85;
      const align = el.textAlign || "center";
      const anchor = align === "left" ? "start" : align === "right" ? "end" : "middle";
      const textX = align === "left" ? b.x : align === "right" ? b.x + b.w : b.x + b.w / 2;

      const textNode = svgEl("text", {
        x: textX,
        y: startY,
        "text-anchor": anchor,
        "font-size": fontSize,
        "font-weight": 500,
        fill: stroke
      });
      lines.forEach((line, idx) => {
        const tspan = svgEl(
          "tspan",
          {
            x: textX,
            dy: idx === 0 ? 0 : lineH
          },
          line
        );
        textNode.appendChild(tspan);
      });
      svg.appendChild(textNode);
    }
  }

  return svg;
}

function drawArrowHead(svg, x1, y1, x2, y2, color) {
  const angle = Math.atan2(y2 - y1, x2 - x1);
  const len = 10;
  const spread = Math.PI / 6.5;
  const p1x = x2 - len * Math.cos(angle - spread);
  const p1y = y2 - len * Math.sin(angle - spread);
  const p2x = x2 - len * Math.cos(angle + spread);
  const p2y = y2 - len * Math.sin(angle + spread);
  svg.appendChild(
    svgEl("path", {
      d: `M ${p1x} ${p1y} L ${x2} ${y2} L ${p2x} ${p2y}`,
      fill: "none",
      stroke: color,
      "stroke-width": 2,
      "stroke-linecap": "round",
      "stroke-linejoin": "round"
    })
  );
}

function drawCenteredLines(svg, text, cx, cy, color, fontSize, backdrop = false) {
  const lines = text.split("\n");
  const lineH = fontSize * 1.25;
  const startY = cy - ((lines.length - 1) * lineH) / 2 + fontSize * 0.35;
  if (backdrop) {
    const estW = Math.max(...lines.map((l) => l.length)) * fontSize * 0.55 + 16;
    const estH = lines.length * lineH + 6;
    svg.appendChild(
      svgEl("rect", {
        x: cx - estW / 2,
        y: cy - estH / 2,
        width: estW,
        height: estH,
        rx: 5,
        fill: "#ffffff",
        opacity: "0.94"
      })
    );
  }
  const t = svgEl("text", {
    x: cx,
    y: startY,
    "text-anchor": "middle",
    "font-size": fontSize,
    "font-weight": 500,
    fill: color
  });
  lines.forEach((line, idx) => {
    t.appendChild(
      svgEl("tspan", { x: cx, dy: idx === 0 ? 0 : lineH }, line)
    );
  });
  svg.appendChild(t);
}

function renderChartCard(spec) {
  const card = document.createElement("div");
  card.className = "chart-card";

  const head = document.createElement("div");
  head.className = "chart-head";
  const titleEl = document.createElement("div");
  titleEl.className = "chart-title";
  titleEl.textContent = spec.title || "Chart";
  head.appendChild(titleEl);
  if (spec.subtitle) {
    const subEl = document.createElement("div");
    subEl.className = "chart-sub";
    subEl.textContent = spec.subtitle;
    head.appendChild(subEl);
  }
  card.appendChild(head);

  const svgWrap = document.createElement("div");
  svgWrap.className = "chart-svg-wrap";

  if (spec.type === "pie") {
    const seriesKey = spec.series?.[0]?.key;
    const rows = Array.isArray(spec.data) ? spec.data : [];
    const total = rows.reduce((acc, r) => acc + Math.max(0, Number(r[seriesKey]) || 0), 0);
    const size = 220;
    const cx = 110;
    const cy = 110;
    const r = 88;
    const svg = svgEl("svg", { viewBox: `0 0 ${size} ${size}`, width: size, height: size, style: "display: block;" });

    let angle = -Math.PI / 2;
    const legend = document.createElement("div");
    legend.className = "chart-legend";

    rows.forEach((row, idx) => {
      const val = Math.max(0, Number(row[seriesKey]) || 0);
      const frac = total > 0 ? val / total : 0;
      const slice = frac * Math.PI * 2;
      const color = CHART_COLORS[idx % CHART_COLORS.length];
      if (slice > 0.001) {
        const x1 = cx + r * Math.cos(angle);
        const y1 = cy + r * Math.sin(angle);
        const x2 = cx + r * Math.cos(angle + slice);
        const y2 = cy + r * Math.sin(angle + slice);
        const largeArc = slice > Math.PI ? 1 : 0;
        const path = svgEl("path", {
          d: `M ${cx} ${cy} L ${x1} ${y1} A ${r} ${r} 0 ${largeArc} 1 ${x2} ${y2} Z`,
          fill: color,
          stroke: "#ffffff",
          "stroke-width": 2
        });
        path.appendChild(
          svgEl("title", {}, `${row[spec.x]}: ${formatChartNumber(val, spec.format)} (${(frac * 100).toFixed(1)}%)`)
        );
        svg.appendChild(path);
      }
      angle += slice;

      const item = document.createElement("div");
      item.className = "legend-item";
      const sw = document.createElement("span");
      sw.className = "legend-swatch";
      sw.style.background = color;
      const lbl = document.createElement("span");
      lbl.textContent = `${row[spec.x]}: ${formatChartNumber(val, spec.format)} (${(frac * 100).toFixed(1)}%)`;
      item.append(sw, lbl);
      legend.appendChild(item);
    });

    if (spec.donut) {
      svg.appendChild(svgEl("circle", { cx, cy, r: 46, fill: "#ffffff" }));
      svg.appendChild(
        svgEl("text", { x: cx, y: cy + 5, "text-anchor": "middle", "font-size": 14, "font-weight": 700, fill: "#18181b" }, formatChartNumber(total, spec.format))
      );
    }

    const rowLayout = document.createElement("div");
    rowLayout.style.display = "flex";
    rowLayout.style.flexWrap = "wrap";
    rowLayout.style.alignItems = "center";
    rowLayout.style.gap = "20px";
    rowLayout.appendChild(svg);
    rowLayout.appendChild(legend);
    svgWrap.appendChild(rowLayout);
  } else {
    const rows = Array.isArray(spec.data) ? spec.data : [];
    const series = Array.isArray(spec.series) ? spec.series : [];
    const refs = Array.isArray(spec.refs) ? spec.refs : [];
    let maxVal = 0;
    for (const r of rows) {
      for (const s of series) {
        const v = Number(r[s.key]);
        if (Number.isFinite(v)) {
          maxVal = Math.max(maxVal, v);
        }
      }
    }
    for (const rf of refs) {
      if (Number.isFinite(Number(rf.y))) {
        maxVal = Math.max(maxVal, Number(rf.y));
      }
    }
    const yMax = maxVal > 0 ? maxVal * 1.15 : 10;

    const W = 740;
    const H = 270;
    const padL = 62;
    const padR = refs.length > 0 ? 148 : 24;
    const padT = 24;
    const padB = 42;
    const plotW = W - padL - padR;
    const plotH = H - padT - padB;

    const svg = svgEl("svg", {
      viewBox: `0 0 ${W} ${H}`,
      style: "width: 100%; min-width: 480px; height: auto; display: block;"
    });

    const ticks = 4;
    for (let i = 0; i <= ticks; i += 1) {
      const val = (yMax / ticks) * i;
      const y = padT + plotH - (val / yMax) * plotH;
      svg.appendChild(
        svgEl("line", { x1: padL, y1: y, x2: W - padR, y2: y, stroke: "#ece9e2", "stroke-width": 1 })
      );
      svg.appendChild(
        svgEl("text", { x: padL - 8, y: y + 4, "text-anchor": "end", "font-size": 11, fill: "#78716c" }, formatChartNumber(val, spec.format))
      );
    }

    for (const rf of refs) {
      const ry = padT + plotH - (Number(rf.y) / yMax) * plotH;
      svg.appendChild(
        svgEl("line", {
          x1: padL,
          y1: ry,
          x2: W - padR,
          y2: ry,
          stroke: "#b45309",
          "stroke-width": 1.5,
          "stroke-dasharray": "5 4"
        })
      );
      if (rf.label) {
        svg.appendChild(
          svgEl(
            "text",
            {
              x: W - padR + 8,
              y: Math.min(padT + plotH - 2, ry + 4),
              "text-anchor": "start",
              "font-size": 11,
              "font-weight": 600,
              fill: "#b45309"
            },
            rf.label
          )
        );
      }
    }

    const groupW = rows.length > 0 ? plotW / rows.length : plotW;
    const barGap = 6;
    const usableW = Math.min(groupW * 0.72, series.length * 46 + 10);
    const barW = Math.max(12, (usableW - barGap * (series.length - 1)) / Math.max(1, series.length));

    rows.forEach((row, rIdx) => {
      const groupCenter = padL + groupW * (rIdx + 0.5);
      const startX = groupCenter - (series.length * barW + (series.length - 1) * barGap) / 2;

      series.forEach((s, sIdx) => {
        const val = Number(row[s.key]) || 0;
        const barH = Math.max(2, (val / yMax) * plotH);
        const bx = startX + sIdx * (barW + barGap);
        const by = padT + plotH - barH;
        const isHighlighted = spec.highlight ? s.key === spec.highlight : false;
        const color = spec.highlight
          ? isHighlighted
            ? "#1d4ed8"
            : "#94a3b8"
          : CHART_COLORS[sIdx % CHART_COLORS.length];

        const rect = svgEl("rect", {
          x: bx,
          y: by,
          width: barW,
          height: barH,
          rx: 4,
          fill: color
        });
        rect.appendChild(
          svgEl("title", {}, `${row[spec.x]} · ${s.label || s.key}: ${formatChartNumber(val, spec.format)}`)
        );
        svg.appendChild(rect);

        svg.appendChild(
          svgEl(
            "text",
            {
              x: bx + barW / 2,
              y: by - 5,
              "text-anchor": "middle",
              "font-size": 10.5,
              "font-weight": 600,
              fill: isHighlighted ? "#1d4ed8" : "#57534e",
              stroke: "#ffffff",
              "stroke-width": 3,
              "paint-order": "stroke"
            },
            formatChartNumber(val, spec.format)
          )
        );
      });

      svg.appendChild(
        svgEl(
          "text",
          {
            x: groupCenter,
            y: padT + plotH + 18,
            "text-anchor": "middle",
            "font-size": 11.5,
            "font-weight": 500,
            fill: "#18181b"
          },
          String(row[spec.x] ?? "")
        )
      );
    });

    svgWrap.appendChild(svg);

    if (series.length > 1) {
      const legend = document.createElement("div");
      legend.className = "chart-legend";
      series.forEach((s, idx) => {
        const item = document.createElement("div");
        item.className = "legend-item";
        const sw = document.createElement("span");
        sw.className = "legend-swatch";
        sw.style.background = spec.highlight
          ? s.key === spec.highlight
            ? "#1d4ed8"
            : "#94a3b8"
          : CHART_COLORS[idx % CHART_COLORS.length];
        const lbl = document.createElement("span");
        lbl.textContent = s.label || s.key;
        item.append(sw, lbl);
        legend.appendChild(item);
      });
      card.appendChild(svgWrap);
      card.appendChild(legend);
    } else {
      card.appendChild(svgWrap);
    }
  }

  if (spec.type === "pie") {
    card.appendChild(svgWrap);
  }

  if (spec.source) {
    const src = document.createElement("div");
    src.className = "chart-source";
    src.textContent = `Source: ${spec.source}`;
    card.appendChild(src);
  }
  return card;
}

function renderAskCard(askEl, artifact) {
  const askId = askEl.getAttribute("id") || "question";
  const recommend = askEl.getAttribute("recommend") || "";
  const placeholder = askEl.getAttribute("placeholder") || "Enter your response...";
  const options = Array.from(askEl.children).filter((c) => c.tagName.toLowerCase() === "option");
  const saved = (artifact.ask_responses && artifact.ask_responses[askId]) || null;

  const card = document.createElement("div");
  card.className = "ask-card";

  const head = document.createElement("div");
  head.className = "ask-head";
  const titleSpan = document.createElement("strong");
  titleSpan.textContent = options.length > 0 ? "Decision Control" : "Response Prompt";
  const idSpan = document.createElement("span");
  idSpan.className = "ask-id";
  idSpan.textContent = `#${askId}`;
  head.append(titleSpan, idSpan);
  card.appendChild(head);

  const statusSpan = document.createElement("span");
  statusSpan.className = saved ? "pill pill-emerald" : "pill pill-subtle";
  statusSpan.textContent = saved
    ? `Saved to D1 · ${formatDate(saved.updated_at)}`
    : "Draft (not saved yet)";

  if (options.length > 0) {
    const optList = document.createElement("div");
    optList.className = "ask-options";
    let selectedVal = saved?.choice_value ?? recommend;

    const optionButtons = [];
    for (const opt of options) {
      const val = opt.getAttribute("value") || opt.textContent || "";
      const row = document.createElement("label");
      row.className = val === selectedVal ? "ask-option selected" : "ask-option";

      const left = document.createElement("span");
      left.className = "ask-option-left";
      const radio = document.createElement("input");
      radio.type = "radio";
      radio.name = `ask-${askId}`;
      radio.value = val;
      radio.checked = val === selectedVal;
      radio.addEventListener("change", () => {
        selectedVal = val;
        for (const entry of optionButtons) {
          entry.row.classList.toggle("selected", entry.val === selectedVal);
        }
      });
      const text = document.createElement("span");
      text.textContent = opt.textContent || val;
      left.append(radio, text);
      row.appendChild(left);

      if (val === recommend) {
        const badge = document.createElement("span");
        badge.className = "pill pill-accent";
        badge.textContent = "Recommended";
        row.appendChild(badge);
      }

      optionButtons.push({ row, val });
      optList.appendChild(row);
    }

    const footer = document.createElement("div");
    footer.className = "ask-footer";
    const saveBtn = document.createElement("button");
    saveBtn.type = "button";
    saveBtn.className = "btn btn-primary btn-sm";
    saveBtn.textContent = "Save Choice";
    saveBtn.addEventListener("click", async () => {
      try {
        const res = await apiFetch(
          `/api/artifacts/${encodeURIComponent(artifact.id)}/asks/${encodeURIComponent(askId)}`,
          {
            method: "POST",
            body: JSON.stringify({ choice_value: selectedVal, response_text: null })
          }
        );
        artifact.ask_responses[askId] = res.ask_response;
        statusSpan.className = "pill pill-emerald";
        statusSpan.textContent = `Saved to D1 · ${formatDate(res.ask_response.updated_at)}`;
        showToast(`Saved decision "${selectedVal}" to D1`);
        await refreshArtifactsListOnly();
      } catch (err) {
        showToast(err.message, true);
      }
    });
    footer.append(statusSpan, saveBtn);
    card.append(optList, footer);
  } else {
    const row = document.createElement("div");
    row.className = "ask-text-row";
    const input = document.createElement("input");
    input.type = "text";
    input.placeholder = placeholder;
    input.value = saved?.response_text || "";
    const saveBtn = document.createElement("button");
    saveBtn.type = "button";
    saveBtn.className = "btn btn-primary btn-sm";
    saveBtn.textContent = "Save Note";
    saveBtn.addEventListener("click", async () => {
      try {
        const res = await apiFetch(
          `/api/artifacts/${encodeURIComponent(artifact.id)}/asks/${encodeURIComponent(askId)}`,
          {
            method: "POST",
            body: JSON.stringify({ choice_value: null, response_text: input.value })
          }
        );
        artifact.ask_responses[askId] = res.ask_response;
        statusSpan.className = "pill pill-emerald";
        statusSpan.textContent = `Saved to D1 · ${formatDate(res.ask_response.updated_at)}`;
        showToast("Saved response to D1");
        await refreshArtifactsListOnly();
      } catch (err) {
        showToast(err.message, true);
      }
    });
    row.append(input, saveBtn);
    const footer = document.createElement("div");
    footer.className = "ask-footer";
    footer.appendChild(statusSpan);
    card.append(row, footer);
  }

  return card;
}

function renderInlineXml(xmlNode, domTarget, artifact = null, afterBlocks = []) {
  for (const child of Array.from(xmlNode.childNodes)) {
    if (child.nodeType === Node.TEXT_NODE) {
      domTarget.appendChild(document.createTextNode(child.textContent || ""));
      continue;
    }
    if (child.nodeType !== Node.ELEMENT_NODE) {
      continue;
    }
    const tag = child.tagName.toLowerCase();
    if (tag === "br") {
      domTarget.appendChild(document.createElement("br"));
    } else if (tag === "b" || tag === "strong") {
      const el = document.createElement("strong");
      renderInlineXml(child, el, artifact, afterBlocks);
      domTarget.appendChild(el);
    } else if (tag === "i" || tag === "em") {
      const el = document.createElement("em");
      renderInlineXml(child, el, artifact, afterBlocks);
      domTarget.appendChild(el);
    } else if (tag === "u") {
      const el = document.createElement("u");
      renderInlineXml(child, el, artifact, afterBlocks);
      domTarget.appendChild(el);
    } else if (tag === "s" || tag === "del" || tag === "strike") {
      const el = document.createElement("s");
      renderInlineXml(child, el, artifact, afterBlocks);
      domTarget.appendChild(el);
    } else if (tag === "code") {
      const el = document.createElement("code");
      el.textContent = child.textContent || "";
      domTarget.appendChild(el);
    } else if (tag === "mark") {
      const el = document.createElement("mark");
      renderInlineXml(child, el, artifact, afterBlocks);
      domTarget.appendChild(el);
    } else if (tag === "sub" || tag === "sup") {
      const el = document.createElement(tag);
      renderInlineXml(child, el, artifact, afterBlocks);
      domTarget.appendChild(el);
    } else if (tag === "a") {
      const href = safeHref(child.getAttribute("href"));
      if (href) {
        const a = document.createElement("a");
        a.href = href;
        a.target = "_blank";
        a.rel = "noopener noreferrer";
        renderInlineXml(child, a, artifact, afterBlocks);
        domTarget.appendChild(a);
      } else {
        renderInlineXml(child, domTarget, artifact, afterBlocks);
      }
    } else if (tag === "ref") {
      const targetKind = ["whiteboard", "document", "html", "artboard", "slides"].find((k) =>
        child.hasAttribute(k)
      );
      if (targetKind) {
        const slug = child.getAttribute(targetKind) || "";
        const btn = document.createElement("button");
        btn.type = "button";
        btn.className = "ref-chip";
        btn.textContent = (child.textContent || "").trim() || `${targetKind}/${slug}`;
        btn.addEventListener("click", () => {
          const targetId = `${state.projectId}:${targetKind}:${slug}`;
          selectArtifact(targetId);
        });
        domTarget.appendChild(btn);
      }
    } else if (tag === "ask" && artifact) {
      afterBlocks.push(renderAskCard(child, artifact));
    } else {
      renderInlineXml(child, domTarget, artifact, afterBlocks);
    }
  }
}

async function renderEmbedWhiteboard(container, slug, frameId, projectId) {
  const card = document.createElement("div");
  card.className = "embed-card";

  const head = document.createElement("div");
  head.className = "embed-head";
  const label = document.createElement("div");
  label.className = "chart-title";
  label.textContent = `Embedded Whiteboard: ${slug}${frameId ? ` (${frameId})` : ""}`;
  const openBtn = document.createElement("button");
  openBtn.type = "button";
  openBtn.className = "btn btn-ghost btn-sm";
  openBtn.textContent = "Open whiteboard";
  openBtn.addEventListener("click", () => {
    selectArtifact(`${projectId}:whiteboard:${slug}`);
  });
  head.append(label, openBtn);
  card.appendChild(head);

  const box = document.createElement("div");
  box.className = "embed-svg-box";
  box.textContent = "Loading whiteboard frame...";
  card.appendChild(box);
  container.appendChild(card);

  try {
    const res = await apiFetch(
      `/api/artifacts/by-ref?project=${encodeURIComponent(projectId)}&type=whiteboard&slug=${encodeURIComponent(slug)}`
    );
    const scene = JSON.parse(res.artifact.content);
    box.textContent = "";
    box.appendChild(renderExcalidrawSvg(scene, frameId || "all"));
  } catch (err) {
    box.textContent = `Could not resolve whiteboard "${slug}": ${err.message}`;
  }
}

async function renderMermaidCard(container, code) {
  const card = document.createElement("div");
  card.className = "mermaid-card";
  const head = document.createElement("div");
  head.className = "chart-head";
  const title = document.createElement("div");
  title.className = "chart-title";
  title.textContent = "State Diagram (Mermaid)";
  head.appendChild(title);
  card.appendChild(head);

  const body = document.createElement("div");
  body.className = "chart-svg-wrap";
  const pre = document.createElement("pre");
  pre.textContent = code;
  body.appendChild(pre);
  card.appendChild(body);
  container.appendChild(card);

  try {
    const mermaid = await getMermaid();
    const id = `mmd-${Math.random().toString(36).slice(2, 9)}`;
    const { svg } = await mermaid.render(id, code);
    const parsed = new DOMParser().parseFromString(svg, "image/svg+xml");
    const svgNode = parsed.documentElement;
    if (svgNode && svgNode.tagName.toLowerCase() === "svg") {
      svgNode.style.maxWidth = "100%";
      svgNode.style.height = "auto";
      body.textContent = "";
      body.appendChild(document.importNode(svgNode, true));
    }
  } catch {
  }
}

function renderXmlBlocks(nodes, parent, artifact) {
  for (const el of nodes) {
    if (el.nodeType !== Node.ELEMENT_NODE) {
      continue;
    }
    const tag = el.tagName.toLowerCase();

    if (/^h[1-6]$/.test(tag)) {
      const h = document.createElement(tag);
      renderInlineXml(el, h, artifact);
      parent.appendChild(h);
    } else if (tag === "p") {
      const children = Array.from(el.children);
      if (
        children.length === 1 &&
        children[0].tagName.toLowerCase() === "ref" &&
        children[0].getAttribute("embed") === "true" &&
        children[0].hasAttribute("whiteboard")
      ) {
        const refEl = children[0];
        renderEmbedWhiteboard(
          parent,
          refEl.getAttribute("whiteboard") || "",
          refEl.getAttribute("frame") || "all",
          artifact.project_id
        );
        continue;
      }
      const p = document.createElement("p");
      const afterBlocks = [];
      renderInlineXml(el, p, artifact, afterBlocks);
      if (p.childNodes.length > 0 && p.textContent.trim().length > 0) {
        parent.appendChild(p);
      }
      for (const blk of afterBlocks) {
        parent.appendChild(blk);
      }
    } else if (tag === "alert") {
      const kind = el.getAttribute("type") || "note";
      const box = document.createElement("div");
      box.className = `doc-alert doc-alert-${kind}`;
      const lbl = document.createElement("div");
      lbl.className = "doc-alert-label";
      lbl.textContent = kind;
      box.appendChild(lbl);
      renderXmlBlocks(Array.from(el.children), box, artifact);
      parent.appendChild(box);
    } else if (tag === "details") {
      const det = document.createElement("details");
      det.className = "doc-details";
      if (el.getAttribute("open") === "true") {
        det.open = true;
      }
      const sum = document.createElement("summary");
      sum.textContent = el.getAttribute("summary") || "Details";
      const body = document.createElement("div");
      body.className = "doc-details-body";
      renderXmlBlocks(Array.from(el.children), body, artifact);
      det.append(sum, body);
      parent.appendChild(det);
    } else if (tag === "ul" || tag === "ol") {
      const isChecklist = tag === "ul" && el.getAttribute("type") === "check";
      const list = document.createElement(tag);
      if (isChecklist) {
        list.className = "checklist";
      }
      for (const liNode of Array.from(el.children)) {
        if (liNode.tagName.toLowerCase() !== "li") {
          continue;
        }
        const li = document.createElement("li");
        if (isChecklist) {
          li.className = "checklist-item";
          const checked = liNode.getAttribute("checked") === "true";
          const box = document.createElement("span");
          box.className = checked ? "check-box checked" : "check-box";
          box.textContent = checked ? "✓" : "";
          const span = document.createElement("span");
          renderInlineXml(liNode, span, artifact);
          li.append(box, span);
        } else {
          renderInlineXml(liNode, li, artifact);
        }
        list.appendChild(li);
      }
      parent.appendChild(list);
    } else if (tag === "table") {
      const wrap = document.createElement("div");
      wrap.className = "table-wrap";
      const tbl = document.createElement("table");
      tbl.className = "data-table";
      const thead = document.createElement("thead");
      const tbody = document.createElement("tbody");
      for (const trNode of Array.from(el.children)) {
        if (trNode.tagName.toLowerCase() !== "tr") {
          continue;
        }
        const tr = document.createElement("tr");
        let isHeader = false;
        for (const cellNode of Array.from(trNode.children)) {
          const cTag = cellNode.tagName.toLowerCase();
          if (cTag === "th") {
            isHeader = true;
          }
          const cell = document.createElement(cTag === "th" ? "th" : "td");
          renderInlineXml(cellNode, cell, artifact);
          tr.appendChild(cell);
        }
        if (isHeader) {
          thead.appendChild(tr);
        } else {
          tbody.appendChild(tr);
        }
      }
      if (thead.children.length > 0) {
        tbl.appendChild(thead);
      }
      tbl.appendChild(tbody);
      wrap.appendChild(tbl);
      parent.appendChild(wrap);
    } else if (tag === "steps") {
      const wrap = document.createElement("div");
      wrap.className = "doc-steps";
      let idx = 0;
      for (const stepNode of Array.from(el.children)) {
        if (stepNode.tagName.toLowerCase() !== "step") {
          continue;
        }
        idx += 1;
        const row = document.createElement("div");
        row.className = "doc-step";
        const num = document.createElement("span");
        num.className = "doc-step-num";
        num.textContent = String(idx);
        const body = document.createElement("div");
        body.className = "doc-step-body";
        const title = document.createElement("div");
        title.className = "doc-step-title";
        title.textContent = stepNode.getAttribute("title") || `Step ${idx}`;
        body.appendChild(title);
        renderXmlBlocks(Array.from(stepNode.children), body, artifact);
        row.append(num, body);
        wrap.appendChild(row);
      }
      parent.appendChild(wrap);
    } else if (tag === "chart") {
      try {
        const spec = JSON.parse(el.textContent || "{}");
        parent.appendChild(renderChartCard(spec));
      } catch (err) {
        const pre = document.createElement("pre");
        pre.textContent = `Invalid chart JSON: ${err.message}`;
        parent.appendChild(pre);
      }
    } else if (tag === "mermaid") {
      renderMermaidCard(parent, (el.textContent || "").trim());
    } else if (tag === "codeblock") {
      const card = document.createElement("div");
      card.className = "code-card";
      const head = document.createElement("div");
      head.className = "code-card-head";
      head.textContent = el.getAttribute("lang") || "text";
      const pre = document.createElement("pre");
      pre.textContent = el.textContent || "";
      card.append(head, pre);
      parent.appendChild(card);
    } else if (tag === "blockquote") {
      const bq = document.createElement("blockquote");
      bq.style.margin = "0";
      bq.style.padding = "6px 14px";
      bq.style.borderLeft = "3px solid var(--border-strong)";
      bq.style.color = "var(--ink-secondary)";
      renderXmlBlocks(Array.from(el.children), bq, artifact);
      parent.appendChild(bq);
    } else if (tag === "hr") {
      parent.appendChild(document.createElement("hr"));
    }
  }
}

function renderDocumentArtifact(artifact) {
  els.docViewer.textContent = "";
  const parser = new DOMParser();
  const xml = parser.parseFromString(artifact.content || "<doc></doc>", "application/xml");
  const parseErr = xml.querySelector("parsererror");
  if (parseErr) {
    const pre = document.createElement("pre");
    pre.textContent = `XML Parse Error: ${parseErr.textContent}\n\n${artifact.content}`;
    els.docViewer.appendChild(pre);
    return;
  }
  renderXmlBlocks(Array.from(xml.documentElement.children), els.docViewer, artifact);
}

function renderWhiteboardArtifact(artifact) {
  els.wbFramePills.textContent = "";
  els.wbCanvasInner.textContent = "";

  let scene;
  try {
    scene = JSON.parse(artifact.content || "{}");
  } catch (err) {
    els.wbCanvasInner.textContent = `Invalid Excalidraw JSON: ${err.message}`;
    return;
  }

  const frames = (Array.isArray(scene.elements) ? scene.elements : []).filter(
    (e) => e && !e.isDeleted && e.type === "frame"
  );

  const allPill = document.createElement("button");
  allPill.type = "button";
  allPill.className = state.wbFrameFilter === "all" ? "chip active" : "chip";
  allPill.textContent = "All frames";
  allPill.addEventListener("click", () => {
    state.wbFrameFilter = "all";
    renderWhiteboardArtifact(artifact);
  });
  els.wbFramePills.appendChild(allPill);

  for (const frame of frames) {
    const btn = document.createElement("button");
    btn.type = "button";
    btn.className = state.wbFrameFilter === frame.id ? "chip active" : "chip";
    btn.textContent = frame.name || frame.id;
    btn.addEventListener("click", () => {
      state.wbFrameFilter = frame.id;
      renderWhiteboardArtifact(artifact);
    });
    els.wbFramePills.appendChild(btn);
  }

  const modeBtns = els.wbModeToggle.querySelectorAll(".seg-btn");
  modeBtns.forEach((b) => {
    const mode = b.getAttribute("data-mode");
    b.classList.toggle("active", mode === state.wbMode);
    if (mode === "png") {
      b.disabled = !artifact.has_render;
      b.title = artifact.has_render ? "View stored PNG snapshot" : "No PNG snapshot stored";
    }
  });

  if (state.wbMode === "png" && artifact.has_render) {
    const img = document.createElement("img");
    img.className = "wb-png";
    img.alt = artifact.title;
    img.src = `/api/artifacts/${encodeURIComponent(artifact.id)}/render.png?rev=${artifact.revision}`;
    els.wbCanvasInner.style.transform = `scale(${state.wbZoom})`;
    els.wbCanvasInner.appendChild(img);
  } else {
    const svg = renderExcalidrawSvg(scene, state.wbFrameFilter);
    els.wbCanvasInner.style.transform = `scale(${state.wbZoom})`;
    els.wbCanvasInner.appendChild(svg);
  }
  els.wbZoomLabel.textContent = `${Math.round(state.wbZoom * 100)}%`;
}

function renderSidebar() {
  const types = ["", "document", "whiteboard", "html"];
  els.typeFilters.textContent = "";
  for (const t of types) {
    const chip = document.createElement("button");
    chip.type = "button";
    chip.className = state.typeFilter === t ? "chip active" : "chip";
    chip.textContent = t === "" ? "All" : t;
    chip.addEventListener("click", async () => {
      state.typeFilter = t;
      await refreshArtifactsListOnly();
    });
    els.typeFilters.appendChild(chip);
  }

  els.moduleFilters.textContent = "";
  const allModChip = document.createElement("button");
  allModChip.type = "button";
  allModChip.className = state.moduleFilter === "" ? "chip active" : "chip";
  allModChip.textContent = "All";
  allModChip.addEventListener("click", async () => {
    state.moduleFilter = "";
    await refreshArtifactsListOnly();
  });
  els.moduleFilters.appendChild(allModChip);

  for (const mod of state.modules) {
    const chip = document.createElement("button");
    chip.type = "button";
    chip.className = state.moduleFilter === mod.id ? "chip active" : "chip";
    chip.title = mod.description || "";
    chip.textContent = mod.name;
    chip.addEventListener("click", async () => {
      state.moduleFilter = state.moduleFilter === mod.id ? "" : mod.id;
      await refreshArtifactsListOnly();
    });
    els.moduleFilters.appendChild(chip);
  }

  els.artifactList.textContent = "";
  els.artifactCountLabel.textContent = String(state.artifacts.length);
  for (const art of state.artifacts) {
    const btn = document.createElement("button");
    btn.type = "button";
    btn.className =
      state.activeArtifact && state.activeArtifact.id === art.id
        ? "artifact-item active"
        : "artifact-item";
    btn.addEventListener("click", () => {
      toggleMobileSidebar(false);
      selectArtifact(art.id);
    });

    const top = document.createElement("div");
    top.className = "artifact-item-top";
    const title = document.createElement("span");
    title.className = "artifact-item-title";
    title.textContent = art.title;
    const rev = document.createElement("span");
    rev.className = "pill pill-subtle";
    rev.textContent = `r${art.revision}`;
    top.append(title, rev);

    const sub = document.createElement("div");
    sub.className = "artifact-item-sub";
    const typeSpan = document.createElement("span");
    typeSpan.textContent = art.type;
    const sizeSpan = document.createElement("span");
    sizeSpan.textContent = formatBytes(art.byte_length);
    const cSpan = document.createElement("span");
    cSpan.textContent = `${art.comment_count || 0} comments`;
    sub.append(typeSpan, document.createTextNode("·"), sizeSpan, document.createTextNode("·"), cSpan);

    btn.append(top, sub);
    els.artifactList.appendChild(btn);
  }
}

function renderActiveArtifact() {
  const art = state.activeArtifact;
  if (!art) {
    els.workspace.hidden = true;
    els.emptyState.hidden = false;
    return;
  }
  els.emptyState.hidden = true;
  els.workspace.hidden = false;

  els.artTypePill.textContent = art.type;
  els.artSlug.textContent = `${art.project_id}/${art.type}/${art.slug}`;
  els.artRevPill.textContent = `r${art.revision}`;
  els.artSizeLabel.textContent = formatBytes(art.byte_length);
  els.artUpdatedLabel.textContent = `Updated ${formatDate(art.updated_at)}`;
  els.artTitle.textContent = art.title;

  els.artModules.textContent = "";
  for (const modId of art.modules || []) {
    const mod = state.modules.find((m) => m.id === modId);
    const chip = document.createElement("span");
    chip.className = "pill";
    chip.textContent = mod ? mod.name : modId;
    els.artModules.appendChild(chip);
  }

  els.tabRevCount.textContent = String((art.revisions || []).length);
  els.tabCommentCount.textContent = String((art.comments || []).length);

  document.querySelectorAll(".tab-btn").forEach((b) => {
    b.classList.toggle("active", b.getAttribute("data-tab") === state.activeTab);
  });
  document.getElementById("tab-view").hidden = state.activeTab !== "view";
  document.getElementById("tab-edit").hidden = state.activeTab !== "edit";
  document.getElementById("tab-revisions").hidden = state.activeTab !== "revisions";
  document.getElementById("tab-comments").hidden = state.activeTab !== "comments";

  if (state.activeTab === "view") {
    els.docViewer.hidden = art.type !== "document";
    els.wbViewer.hidden = art.type !== "whiteboard";
    els.rawViewer.hidden = art.type === "document" || art.type === "whiteboard";
    if (art.type === "document") {
      renderDocumentArtifact(art);
    } else if (art.type === "whiteboard") {
      renderWhiteboardArtifact(art);
    } else {
      els.rawViewer.textContent = "";
      const card = document.createElement("div");
      card.className = "code-card";
      const pre = document.createElement("pre");
      pre.textContent = art.content || "";
      card.appendChild(pre);
      els.rawViewer.appendChild(card);
    }
  }

  els.editTitle.value = art.title;
  els.editNote.value = "";
  els.editContent.value = art.content;
  els.editModulesChecks.textContent = "";
  for (const mod of state.modules) {
    const lbl = document.createElement("label");
    lbl.className = "chip";
    const cb = document.createElement("input");
    cb.type = "checkbox";
    cb.value = mod.id;
    cb.checked = (art.modules || []).includes(mod.id);
    const txt = document.createElement("span");
    txt.textContent = mod.name;
    lbl.append(cb, txt);
    els.editModulesChecks.appendChild(lbl);
  }
  state.deleteConfirmId = "";
  els.btnDeleteArtifact.textContent = "Delete Artifact";

  els.revisionsTbody.textContent = "";
  for (const rev of art.revisions || []) {
    const tr = document.createElement("tr");
    const tdRev = document.createElement("td");
    tdRev.textContent = `r${rev.revision}`;
    const tdNote = document.createElement("td");
    tdNote.textContent = rev.note || "Snapshot";
    const tdSize = document.createElement("td");
    tdSize.textContent = formatBytes(rev.byte_length);
    const tdDate = document.createElement("td");
    tdDate.textContent = formatDate(rev.created_at);
    const tdAct = document.createElement("td");
    if (rev.revision !== art.revision) {
      const btn = document.createElement("button");
      btn.type = "button";
      btn.className = "btn btn-ghost btn-sm";
      btn.textContent = "Restore";
      btn.addEventListener("click", async () => {
        try {
          const res = await apiFetch(
            `/api/artifacts/${encodeURIComponent(art.id)}/restore`,
            {
              method: "POST",
              body: JSON.stringify({ revision: rev.revision })
            }
          );
          state.activeArtifact = res.artifact;
          showToast(`Restored r${rev.revision} as r${res.artifact.revision}`);
          await refreshArtifactsListOnly();
          renderActiveArtifact();
        } catch (err) {
          showToast(err.message, true);
        }
      });
      tdAct.appendChild(btn);
    } else {
      const pill = document.createElement("span");
      pill.className = "pill pill-accent";
      pill.textContent = "Current";
      tdAct.appendChild(pill);
    }
    tr.append(tdRev, tdNote, tdSize, tdDate, tdAct);
    els.revisionsTbody.appendChild(tr);
  }

  els.commentsList.textContent = "";
  if ((art.comments || []).length === 0) {
    const p = document.createElement("p");
    p.className = "panel-sub";
    p.textContent = "No comments yet. Start a review thread above.";
    els.commentsList.appendChild(p);
  } else {
    for (const c of art.comments || []) {
      const item = document.createElement("div");
      item.className = c.resolved ? "comment-item resolved" : "comment-item";
      const head = document.createElement("div");
      head.className = "comment-head";
      const left = document.createElement("div");
      const auth = document.createElement("span");
      auth.className = "comment-author";
      auth.textContent = c.author;
      const dt = document.createElement("span");
      dt.className = "meta-text";
      dt.textContent = ` · ${formatDate(c.created_at)}`;
      left.append(auth, dt);

      const acts = document.createElement("div");
      acts.className = "comment-actions";
      const resBtn = document.createElement("button");
      resBtn.type = "button";
      resBtn.className = "btn btn-ghost btn-sm";
      resBtn.textContent = c.resolved ? "Reopen" : "Resolve";
      resBtn.addEventListener("click", async () => {
        try {
          await apiFetch(`/api/comments/${c.id}`, {
            method: "PATCH",
            body: JSON.stringify({ resolved: !c.resolved })
          });
          await selectArtifact(art.id);
        } catch (err) {
          showToast(err.message, true);
        }
      });
      const delBtn = document.createElement("button");
      delBtn.type = "button";
      delBtn.className = "btn btn-danger btn-sm";
      delBtn.textContent = "Delete";
      delBtn.addEventListener("click", async () => {
        try {
          await apiFetch(`/api/comments/${c.id}`, { method: "DELETE" });
          await selectArtifact(art.id);
        } catch (err) {
          showToast(err.message, true);
        }
      });
      acts.append(resBtn, delBtn);
      head.append(left, acts);

      const body = document.createElement("p");
      body.textContent = c.body;
      item.append(head, body);
      els.commentsList.appendChild(item);
    }
  }
}

async function selectArtifact(id) {
  try {
    const res = await apiFetch(`/api/artifacts/${encodeURIComponent(id)}`);
    state.activeArtifact = res.artifact;
    state.wbFrameFilter = "all";
    state.wbMode = "svg";
    state.wbZoom = 1;
    const url = new URL(window.location.href);
    url.searchParams.set("artifact", id);
    window.history.replaceState({}, "", url.toString());
    renderSidebar();
    renderActiveArtifact();
  } catch (err) {
    showToast(err.message, true);
  }
}

async function refreshArtifactsListOnly() {
  const params = new URLSearchParams();
  if (state.projectId) {
    params.set("project", state.projectId);
  }
  if (state.typeFilter) {
    params.set("type", state.typeFilter);
  }
  if (state.moduleFilter) {
    params.set("module", state.moduleFilter);
  }
  if (state.searchQuery) {
    params.set("q", state.searchQuery);
  }
  const res = await apiFetch(`/api/artifacts?${params.toString()}`);
  state.artifacts = res.artifacts || [];
  renderSidebar();
}

async function loadProjectData(projectId) {
  state.projectId = projectId;
  const modRes = await apiFetch(`/api/projects/${encodeURIComponent(projectId)}/modules`);
  state.modules = modRes.modules || [];
  await refreshArtifactsListOnly();

  const urlArtifact = new URL(window.location.href).searchParams.get("artifact");
  if (urlArtifact && state.artifacts.some((a) => a.id === urlArtifact)) {
    await selectArtifact(urlArtifact);
    return;
  }
  const preferred =
    state.artifacts.find((a) => a.type === "document") || state.artifacts[0] || null;
  if (preferred) {
    await selectArtifact(preferred.id);
  } else {
    state.activeArtifact = null;
    renderActiveArtifact();
  }
}

function openModal(title, buildBodyFn) {
  els.modalTitle.textContent = title;
  els.modalBody.textContent = "";
  buildBodyFn(els.modalBody);
  els.modalBackdrop.hidden = false;
}

function closeModal() {
  els.modalBackdrop.hidden = true;
}

function openNewArtifactModal() {
  openModal("Create or Import Artifact", (body) => {
    const form = document.createElement("form");
    form.className = "editor-form";
    form.style.border = "none";
    form.style.padding = "0";
    form.style.boxShadow = "none";

    const grid = document.createElement("div");
    grid.className = "form-grid";

    const typeField = document.createElement("label");
    typeField.className = "field";
    const typeLbl = document.createElement("span");
    typeLbl.textContent = "Type";
    const typeSel = document.createElement("select");
    for (const t of ["document", "whiteboard", "html"]) {
      const o = document.createElement("option");
      o.value = t;
      o.textContent = t;
      typeSel.appendChild(o);
    }
    typeField.append(typeLbl, typeSel);

    const slugField = document.createElement("label");
    slugField.className = "field";
    const slugLbl = document.createElement("span");
    slugLbl.textContent = "Slug (lowercase-kebab)";
    const slugIn = document.createElement("input");
    slugIn.type = "text";
    slugIn.required = true;
    slugIn.placeholder = "retry-policy";
    slugField.append(slugLbl, slugIn);
    grid.append(typeField, slugField);

    const titleField = document.createElement("label");
    titleField.className = "field";
    const titleLbl = document.createElement("span");
    titleLbl.textContent = "Title";
    const titleIn = document.createElement("input");
    titleIn.type = "text";
    titleIn.required = true;
    titleIn.placeholder = "Retry Policy Architecture";
    titleField.append(titleLbl, titleIn);

    const fileField = document.createElement("label");
    fileField.className = "field";
    const fileLbl = document.createElement("span");
    fileLbl.textContent = "Optional: Import doc.xml / scene.excalidraw / .html file";
    const fileIn = document.createElement("input");
    fileIn.type = "file";
    fileIn.accept = ".xml,.excalidraw,.json,.html";
    fileField.append(fileLbl, fileIn);

    const contentField = document.createElement("label");
    contentField.className = "field";
    const contentLbl = document.createElement("span");
    contentLbl.textContent = "Content";
    const contentArea = document.createElement("textarea");
    contentArea.rows = 10;
    contentArea.value = DOC_TEMPLATE;
    contentField.append(contentLbl, contentArea);

    typeSel.addEventListener("change", () => {
      if (typeSel.value === "whiteboard") {
        contentArea.value = WB_TEMPLATE;
      } else if (typeSel.value === "document") {
        contentArea.value = DOC_TEMPLATE;
      } else {
        contentArea.value = "<!doctype html><html><body><h1>Demo</h1></body></html>";
      }
    });

    fileIn.addEventListener("change", async () => {
      const f = fileIn.files?.[0];
      if (!f) {
        return;
      }
      const txt = await f.text();
      contentArea.value = txt;
      if (f.name.endsWith(".excalidraw") || f.name.endsWith(".json")) {
        typeSel.value = "whiteboard";
      } else if (f.name.endsWith(".xml")) {
        typeSel.value = "document";
      } else if (f.name.endsWith(".html")) {
        typeSel.value = "html";
      }
      if (!slugIn.value) {
        slugIn.value = f.name.replace(/\.[^.]+$/, "").toLowerCase().replace(/[^a-z0-9-]+/g, "-");
      }
      if (!titleIn.value) {
        titleIn.value = slugIn.value;
      }
    });

    const submitRow = document.createElement("div");
    submitRow.className = "editor-actions";
    const submitBtn = document.createElement("button");
    submitBtn.type = "submit";
    submitBtn.className = "btn btn-primary";
    submitBtn.textContent = "Save to D1";
    submitRow.appendChild(submitBtn);

    form.append(grid, titleField, fileField, contentField, submitRow);
    form.addEventListener("submit", async (e) => {
      e.preventDefault();
      try {
        const res = await apiFetch("/api/artifacts", {
          method: "POST",
          body: JSON.stringify({
            project_id: state.projectId || "zigder",
            type: typeSel.value,
            slug: slugIn.value,
            title: titleIn.value,
            content: contentArea.value,
            modules: state.moduleFilter ? [state.moduleFilter] : []
          })
        });
        closeModal();
        showToast(`Created ${res.artifact.type}/${res.artifact.slug}`);
        await refreshArtifactsListOnly();
        await selectArtifact(res.artifact.id);
      } catch (err) {
        showToast(err.message, true);
      }
    });

    body.appendChild(form);
  });
}

function openModulesModal() {
  openModal("Manage Projects & Modules", (body) => {
    const projBox = document.createElement("div");
    projBox.className = "panel-card";
    const pTitle = document.createElement("h3");
    pTitle.textContent = "Create or Switch Project";
    const pRow = document.createElement("div");
    pRow.className = "ask-text-row";
    const pidIn = document.createElement("input");
    pidIn.placeholder = "project-slug";
    const pNameIn = document.createElement("input");
    pNameIn.placeholder = "Display Name";
    const pBtn = document.createElement("button");
    pBtn.type = "button";
    pBtn.className = "btn btn-primary btn-sm";
    pBtn.textContent = "Create Project";
    pBtn.addEventListener("click", async () => {
      if (!pidIn.value.trim()) {
        return;
      }
      try {
        const res = await apiFetch("/api/projects", {
          method: "POST",
          body: JSON.stringify({ id: pidIn.value, name: pNameIn.value || pidIn.value })
        });
        closeModal();
        showToast(`Project "${res.project.id}" ready`);
        await initApp(res.project.id);
      } catch (err) {
        showToast(err.message, true);
      }
    });
    pRow.append(pidIn, pNameIn, pBtn);
    projBox.append(pTitle, pRow);

    const modBox = document.createElement("div");
    modBox.className = "panel-card";
    const mTitle = document.createElement("h3");
    mTitle.textContent = `Modules for "${state.projectId}"`;
    const modJsonField = document.createElement("label");
    modJsonField.className = "field";
    const mSpan = document.createElement("span");
    mSpan.textContent = "Module Vocabulary JSON";
    const mArea = document.createElement("textarea");
    mArea.rows = 12;
    mArea.value = JSON.stringify(state.modules, null, 2);
    modJsonField.append(mSpan, mArea);
    const saveMods = document.createElement("button");
    saveMods.type = "button";
    saveMods.className = "btn btn-primary";
    saveMods.textContent = "Save Modules";
    saveMods.addEventListener("click", async () => {
      try {
        const parsed = JSON.parse(mArea.value);
        await apiFetch(`/api/projects/${encodeURIComponent(state.projectId)}/modules`, {
          method: "PUT",
          body: JSON.stringify({ modules: parsed })
        });
        closeModal();
        showToast("Updated module vocabulary in D1");
        await loadProjectData(state.projectId);
      } catch (err) {
        showToast(err.message, true);
      }
    });
    modBox.append(mTitle, modJsonField, saveMods);

    body.append(projBox, modBox);
  });
}

async function openSyncModal() {
  openModal("CLI Sync & Cloudflare D1 Storage", async (body) => {
    const infoCard = document.createElement("div");
    infoCard.className = "panel-card";
    const h3 = document.createElement("h3");
    h3.textContent = "Live Storage Summary (Cloudflare Workers Free + D1)";
    const summary = document.createElement("p");
    summary.className = "panel-sub";
    summary.textContent = "Loading live database stats...";
    infoCard.append(h3, summary);

    const cliCard = document.createElement("div");
    cliCard.className = "code-card";
    const cliHead = document.createElement("div");
    cliHead.className = "code-card-head";
    cliHead.textContent = "Sync any local .ryugi/ workspace into this Cloudflare D1 hub";
    const cliPre = document.createElement("pre");
    cliPre.textContent = `bun run scripts/sync.ts -- --url ${window.location.origin} --dir /path/to/repo`;
    cliCard.append(cliHead, cliPre);

    const authCard = document.createElement("div");
    authCard.className = "panel-card";
    const ah3 = document.createElement("h3");
    ah3.textContent = "Optional Write Token (ADMIN_TOKEN)";
    const ap = document.createElement("p");
    ap.className = "panel-sub";
    ap.textContent = "If you set a Wrangler secret ADMIN_TOKEN, paste it here for this browser session.";
    const aRow = document.createElement("div");
    aRow.className = "ask-text-row";
    const aIn = document.createElement("input");
    aIn.type = "password";
    aIn.placeholder = "Bearer token (sessionStorage only)";
    aIn.value = sessionStorage.getItem("ryugi_hub_admin_token") || "";
    const aSave = document.createElement("button");
    aSave.type = "button";
    aSave.className = "btn btn-ghost btn-sm";
    aSave.textContent = "Save Token";
    aSave.addEventListener("click", () => {
      sessionStorage.setItem("ryugi_hub_admin_token", aIn.value.trim());
      showToast(aIn.value.trim() ? "Session write token stored" : "Session write token cleared");
    });
    aRow.append(aIn, aSave);
    authCard.append(ah3, ap, aRow);

    body.append(infoCard, cliCard, authCard);

    try {
      const health = await apiFetch("/api/health");
      const c = health.counts || {};
      summary.textContent = `Projects: ${c.projects ?? 0} · Modules: ${c.modules ?? 0} · Artifacts: ${c.artifacts ?? 0} · Comments: ${c.comments ?? 0} · Saved Ask Decisions: ${c.ask_responses ?? 0} · Write Auth: ${health.auth_required ? "Protected" : "Open"}`;
    } catch (err) {
      summary.textContent = `Failed to load stats: ${err.message}`;
    }
  });
}

function wireEvents() {
  els.menuToggle.addEventListener("click", () => {
    toggleMobileSidebar(!els.sidebar.classList.contains("open"));
  });
  els.sidebarBackdrop.addEventListener("click", () => toggleMobileSidebar(false));

  els.projectSelect.addEventListener("change", () => {
    loadProjectData(els.projectSelect.value);
  });

  let searchTimer = null;
  els.searchInput.addEventListener("input", () => {
    clearTimeout(searchTimer);
    searchTimer = setTimeout(() => {
      state.searchQuery = els.searchInput.value.trim();
      refreshArtifactsListOnly();
    }, 150);
  });

  document.querySelectorAll(".tab-btn").forEach((btn) => {
    btn.addEventListener("click", () => {
      state.activeTab = btn.getAttribute("data-tab") || "view";
      renderActiveArtifact();
    });
  });

  els.wbModeToggle.querySelectorAll(".seg-btn").forEach((btn) => {
    btn.addEventListener("click", () => {
      if (btn.disabled) {
        return;
      }
      state.wbMode = btn.getAttribute("data-mode") || "svg";
      if (state.activeArtifact) {
        renderWhiteboardArtifact(state.activeArtifact);
      }
    });
  });

  document.getElementById("wb-zoom-out").addEventListener("click", () => {
    state.wbZoom = Math.max(0.4, Number((state.wbZoom - 0.15).toFixed(2)));
    if (state.activeArtifact) {
      renderWhiteboardArtifact(state.activeArtifact);
    }
  });
  document.getElementById("wb-zoom-in").addEventListener("click", () => {
    state.wbZoom = Math.min(2.2, Number((state.wbZoom + 0.15).toFixed(2)));
    if (state.activeArtifact) {
      renderWhiteboardArtifact(state.activeArtifact);
    }
  });
  document.getElementById("wb-zoom-fit").addEventListener("click", () => {
    state.wbZoom = 1;
    if (state.activeArtifact) {
      renderWhiteboardArtifact(state.activeArtifact);
    }
  });

  els.editForm.addEventListener("submit", async (e) => {
    e.preventDefault();
    const art = state.activeArtifact;
    if (!art) {
      return;
    }
    const mods = Array.from(
      els.editModulesChecks.querySelectorAll("input[type=checkbox]:checked")
    ).map((i) => i.value);
    try {
      const res = await apiFetch(`/api/artifacts/${encodeURIComponent(art.id)}`, {
        method: "PUT",
        body: JSON.stringify({
          title: els.editTitle.value.trim() || art.title,
          note: els.editNote.value.trim(),
          modules: mods,
          content: els.editContent.value
        })
      });
      state.activeArtifact = res.artifact;
      state.activeTab = "view";
      showToast(`Saved revision r${res.artifact.revision}`);
      await refreshArtifactsListOnly();
      renderActiveArtifact();
    } catch (err) {
      showToast(err.message, true);
    }
  });

  els.btnDownloadSource.addEventListener("click", () => {
    const art = state.activeArtifact;
    if (!art) {
      return;
    }
    const ext =
      art.type === "document" ? "doc.xml" : art.type === "whiteboard" ? "scene.excalidraw" : `${art.slug}.txt`;
    const blob = new Blob([art.content || ""], { type: "text/plain;charset=utf-8" });
    const a = document.createElement("a");
    a.href = URL.createObjectURL(blob);
    a.download = `${art.slug}-${ext}`;
    a.click();
    URL.revokeObjectURL(a.href);
  });

  els.btnDeleteArtifact.addEventListener("click", async () => {
    const art = state.activeArtifact;
    if (!art) {
      return;
    }
    if (state.deleteConfirmId !== art.id) {
      state.deleteConfirmId = art.id;
      els.btnDeleteArtifact.textContent = "Confirm Delete?";
      return;
    }
    try {
      await apiFetch(`/api/artifacts/${encodeURIComponent(art.id)}`, { method: "DELETE" });
      showToast(`Deleted ${art.type}/${art.slug}`);
      await loadProjectData(state.projectId);
    } catch (err) {
      showToast(err.message, true);
    }
  });

  els.commentForm.addEventListener("submit", async (e) => {
    e.preventDefault();
    const art = state.activeArtifact;
    if (!art) {
      return;
    }
    try {
      await apiFetch(`/api/artifacts/${encodeURIComponent(art.id)}/comments`, {
        method: "POST",
        body: JSON.stringify({
          author: els.commentAuthor.value.trim() || "Reviewer",
          body: els.commentBody.value.trim()
        })
      });
      els.commentBody.value = "";
      showToast("Comment posted to D1");
      await selectArtifact(art.id);
      await refreshArtifactsListOnly();
    } catch (err) {
      showToast(err.message, true);
    }
  });

  document.getElementById("btn-new-artifact").addEventListener("click", openNewArtifactModal);
  document.getElementById("empty-new-btn").addEventListener("click", openNewArtifactModal);
  document.getElementById("btn-modules").addEventListener("click", openModulesModal);
  document.getElementById("btn-sync-info").addEventListener("click", openSyncModal);
  document.getElementById("empty-sync-btn").addEventListener("click", openSyncModal);
  els.modalClose.addEventListener("click", closeModal);
  els.modalBackdrop.addEventListener("click", (e) => {
    if (e.target === els.modalBackdrop) {
      closeModal();
    }
  });
}

async function initApp(preferredProjectId = "") {
  try {
    const projRes = await apiFetch("/api/projects");
    state.projects = projRes.projects || [];
    els.projectSelect.textContent = "";
    if (state.projects.length === 0) {
      const opt = document.createElement("option");
      opt.value = "zigder";
      opt.textContent = "zigder (empty)";
      els.projectSelect.appendChild(opt);
      state.projectId = "zigder";
      state.artifacts = [];
      state.activeArtifact = null;
      renderSidebar();
      renderActiveArtifact();
      return;
    }

    for (const p of state.projects) {
      const opt = document.createElement("option");
      opt.value = p.id;
      opt.textContent = `${p.name} (${p.artifact_count})`;
      els.projectSelect.appendChild(opt);
    }

    const chosen =
      preferredProjectId && state.projects.some((p) => p.id === preferredProjectId)
        ? preferredProjectId
        : state.projects[0].id;
    els.projectSelect.value = chosen;
    await loadProjectData(chosen);
  } catch (err) {
    showToast(`Failed to connect to API: ${err.message}`, true);
  }
}

wireEvents();
initApp();
