import { useSyncExternalStore } from "react";
import type { Provider } from "../session";
import { currentThemeRevision, subscribeThemeChanges } from "../theme";

const PROVIDER_COLOR: Record<string, string> = {
  claude: "#d97757",
  codex: "#10a37f",
  opencode: "#f2a600",
  pi: "#8b7cff",
  gemini: "#4285f4",
};

export function colorFor(id: string): string {
  if (PROVIDER_COLOR[id]) return PROVIDER_COLOR[id];
  let h = 0;
  for (const c of id) h = (h * 31 + c.charCodeAt(0)) % 360;
  // Mid lightness reads on both light and dark backgrounds.
  return `hsl(${h} 60% 48%)`;
}

export function basename(p: string): string {
  const t = String(p || "").replace(/\/+$/, "");
  return t.split("/").pop() || t || "~";
}

function Dot({ id }: { id: string }) {
  return <span className="dot" style={{ background: colorFor(id), color: colorFor(id) }} />;
}

function themeIsDark(): boolean {
  const scheme = getComputedStyle(document.documentElement).getPropertyValue("--color-scheme").trim();
  if (scheme === "light" || scheme === "dark") return scheme === "dark";
  const bg = getComputedStyle(document.documentElement).getPropertyValue("--bg").trim();
  const m = bg.match(/^#([0-9a-f]{6})$/i);
  if (!m) return true;
  const n = parseInt(m[1], 16);
  const r = (n >> 16) & 255;
  const g = (n >> 8) & 255;
  const b = n & 255;
  return (r * 299 + g * 587 + b * 114) / 1000 < 150;
}

function DrawnProviderIcon({ id }: { id: string }) {
  const color = colorFor(id);
  if (id === "claude") {
    return (
      <svg className="provider-icon" viewBox="0 0 16 16" style={{ color }}>
        <path d="M8 1.7v12.6M1.7 8h12.6M3.5 3.5l9 9M12.5 3.5l-9 9" fill="none" stroke="currentColor" strokeWidth="1.45" strokeLinecap="round" />
      </svg>
    );
  }
  if (id === "codex") {
    return (
      <svg className="provider-icon" viewBox="0 0 16 16" style={{ color }}>
        <path d="M8 1.8l4.9 2.8v5.7L8 13.2l-4.9-2.9V4.6L8 1.8zm0 0v4.1m4.9-1.3L9.3 6.7m-6.2-2.1l3.6 2.1m-3.6 3.6l3.6-2.1m6.2 2.1L9.3 8.2M8 13.2V9.1" fill="none" stroke="currentColor" strokeWidth="1.2" strokeLinecap="round" strokeLinejoin="round" />
      </svg>
    );
  }
  if (id === "opencode") {
    return (
      <svg className="provider-icon" viewBox="0 0 16 16" style={{ color }}>
        <rect x="2.2" y="3" width="11.6" height="10" rx="2" fill="none" stroke="currentColor" strokeWidth="1.25" />
        <path d="M4.6 6.1l2 1.9-2 1.9M7.9 10.1h3.1" fill="none" stroke="currentColor" strokeWidth="1.25" strokeLinecap="round" strokeLinejoin="round" />
      </svg>
    );
  }
  if (id === "pi") {
    return (
      <svg className="provider-icon" viewBox="0 0 16 16" style={{ color }}>
        <text x="8" y="11.8" textAnchor="middle" fontSize="13" fontWeight="400" fill="currentColor">π</text>
      </svg>
    );
  }
  if (id === "gemini") {
    return (
      <svg className="provider-icon" viewBox="0 0 16 16" style={{ color }}>
        <path d="M8 1.8c.7 3.1 2.1 4.5 5.2 5.2C10.1 7.7 8.7 9.1 8 12.2 7.3 9.1 5.9 7.7 2.8 7 5.9 6.3 7.3 4.9 8 1.8z" fill="currentColor" />
      </svg>
    );
  }
  return <Dot id={id} />;
}

export function ProviderIcon({ provider }: { provider: Provider }) {
  // Re-render on live theme changes so the light/dark icon variant follows.
  useSyncExternalStore(subscribeThemeChanges, currentThemeRevision, () => 0);
  const src = themeIsDark() ? (provider.iconDarkUrl ?? provider.iconUrl) : provider.iconUrl;
  if (!src) return <DrawnProviderIcon id={provider.id} />;
  return <span className="provider-icon-img" aria-hidden="true" style={{ backgroundImage: `url(${src})` }} />;
}

export const ArrowUp = () => (
  <svg viewBox="0 0 16 16" width="16" height="16"><path d="M8 13V3.5M4 7l4-4 4 4" fill="none" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round" /></svg>
);
export const Chevron = () => (
  <svg viewBox="0 0 10 6" width="10" height="6"><path d="M1 1l4 4 4-4" fill="none" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" strokeLinejoin="round" /></svg>
);
export const Check = () => (
  <svg viewBox="0 0 12 12" width="12" height="12"><path d="M2.5 6.2l2.3 2.3L9.5 3.5" fill="none" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round" /></svg>
);
export const FolderIcon = () => (
  <svg viewBox="0 0 14 12" width="13" height="11" fill="none" stroke="currentColor" strokeWidth="1.2"><path d="M1 3.4c0-.7.5-1.3 1.2-1.3h2.5l1.2 1.4h5.7c.7 0 1.2.6 1.2 1.3v4.9c0 .7-.5 1.3-1.2 1.3H2.2C1.5 11 1 10.4 1 9.7z" /></svg>
);
export const SparkIcon = () => (
  <svg viewBox="0 0 16 16" width="15" height="15"><path d="M8 2v12M2 8h12M3.8 3.8l8.4 8.4M12.2 3.8l-8.4 8.4" fill="none" stroke="currentColor" strokeWidth="1.35" strokeLinecap="round" /></svg>
);
export const BoltIcon = () => (
  <svg viewBox="0 0 16 16" width="15" height="15"><path d="M8.8 1.8L3.9 8.7h3.6l-.5 5.5 5.1-7.1H8.4l.4-5.3z" fill="currentColor" /></svg>
);
export function BarsIcon({ filled = 4, bars = 4 }: { filled?: number; bars?: number }) {
  const count = Math.max(1, bars);
  const active = Math.max(0, Math.min(count, filled));
  return (
    <svg viewBox="0 0 16 16" width="15" height="15" aria-hidden="true">
      {Array.from({ length: count }, (_, i) => {
        const x = 3 + (i * 10) / Math.max(1, count - 1);
        const h = 2.2 + (i * 8.2) / Math.max(1, count - 1);
        return (
          <path
            key={i}
            d={`M${x.toFixed(1)} 12V${(12 - h).toFixed(1)}`}
            fill="none"
            stroke="currentColor"
            strokeWidth="1.7"
            strokeLinecap="round"
            opacity={i < active ? 1 : 0.35}
          />
        );
      })}
    </svg>
  );
}
export const PlanIcon = () => (
  <svg viewBox="0 0 16 16" width="15" height="15"><path d="M2.5 4.3l3.4-1.5 4.2 1.5 3.4-1.5v8.9l-3.4 1.5-4.2-1.5-3.4 1.5V4.3zM5.9 2.8v8.9M10.1 4.3v8.9" fill="none" stroke="currentColor" strokeWidth="1.25" strokeLinecap="round" strokeLinejoin="round" /></svg>
);
export const ShieldIcon = () => (
  <svg viewBox="0 0 16 16" width="15" height="15"><path d="M8 2.2l4.7 1.7v3.6c0 3.1-1.9 5.3-4.7 6.3-2.8-1-4.7-3.2-4.7-6.3V3.9L8 2.2z" fill="none" stroke="currentColor" strokeWidth="1.25" strokeLinejoin="round" /><path d="M5.8 7.9l1.4 1.4 3-3.1" fill="none" stroke="currentColor" strokeWidth="1.35" strokeLinecap="round" strokeLinejoin="round" /></svg>
);
export const EllipsisIcon = () => (
  <svg viewBox="0 0 16 16" width="15" height="15"><path d="M3.5 8h.1M8 8h.1M12.5 8h.1" fill="none" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round" /></svg>
);
export const SearchIcon = () => (
  <svg viewBox="0 0 16 16" width="14" height="14"><path d="M7 12.2a5.2 5.2 0 1 1 0-10.4 5.2 5.2 0 0 1 0 10.4zM11 11l3 3" fill="none" stroke="currentColor" strokeWidth="1.35" strokeLinecap="round" /></svg>
);
export const CopyIcon = () => (
  <svg viewBox="0 0 16 16" width="14" height="14"><path d="M5.2 5.2h7.1v7.1H5.2zM3.7 10.8H3V3.7h7.1v.7" fill="none" stroke="currentColor" strokeWidth="1.25" strokeLinejoin="round" /></svg>
);

export const ExpandIcon = () => (
  <svg viewBox="0 0 16 16" width="14" height="14"><path d="M9.5 2.8h3.7v3.7M13.2 2.8L9 7M6.5 13.2H2.8V9.5M2.8 13.2L7 9" fill="none" stroke="currentColor" strokeWidth="1.3" strokeLinecap="round" strokeLinejoin="round" /></svg>
);
export const CloseIcon = () => (
  <svg viewBox="0 0 16 16" width="14" height="14"><path d="M4 4l8 8M12 4l-8 8" fill="none" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" /></svg>
);

export function PinwheelSpinner({ size = 14 }: { size?: number }) {
  return (
    <svg className="pinwheel-spinner" viewBox="0 0 16 16" width={size} height={size} aria-hidden="true">
      {Array.from({ length: 8 }, (_, i) => (
        <line
          key={i}
          x1="8"
          y1="2.5"
          x2="8"
          y2="5"
          stroke="currentColor"
          strokeWidth="1.6"
          strokeLinecap="round"
          opacity={0.2 + i * 0.1}
          transform={`rotate(${i * 45} 8 8)`}
        />
      ))}
    </svg>
  );
}

export const FileIcon = () => (
  <svg viewBox="0 0 16 16" width="13" height="13" aria-hidden="true"><path d="M4 1.8h5.2L12.5 5v9.2H4zM9 1.8V5.3h3.5" fill="none" stroke="currentColor" strokeWidth="1.2" strokeLinejoin="round" /></svg>
);

const ALERT_ICON_PATHS: Record<string, string> = {
  note: "M8 14.2A6.2 6.2 0 1 0 8 1.8a6.2 6.2 0 0 0 0 12.4zM8 7.3v4M8 4.9v.1",
  tip: "M6 12.2h4M6.6 14.2h2.8M5.4 9.9C4.5 9.1 3.9 8 3.9 6.7a4.1 4.1 0 1 1 8.2 0c0 1.3-.6 2.4-1.5 3.2-.4.4-.6.8-.6 1.3v1H6v-1c0-.5-.2-.9-.6-1.3z",
  important: "M2.3 2.3h11.4v8.6H8.6L5.4 13.7v-2.8H2.3zM8 4.8v3M8 9.4v.1",
  warning: "M8 2.2l6.3 11H1.7zM8 6.6v3.2M8 11.6v.1",
  caution: "M5.4 1.8h5.2l3.6 3.6v5.2l-3.6 3.6H5.4l-3.6-3.6V5.4zM8 4.9v3.8M8 10.9v.1",
};

export const AlertIcon = ({ kind }: { kind: string }) => (
  <svg viewBox="0 0 16 16" width="15" height="15" aria-hidden="true"><path d={ALERT_ICON_PATHS[kind] ?? ALERT_ICON_PATHS.note} fill="none" stroke="currentColor" strokeWidth="1.3" strokeLinecap="round" strokeLinejoin="round" /></svg>
);
