// Froth room — core components (Tailwind edition)

const { useState, useEffect, useRef, useMemo } = React;

// Color class for each person — avoids class-name collisions
const PEOPLE = {
  mira:  { name: "mira",  color: "text-amber",   kind: "human"  },
  jonas: { name: "jonas", color: "text-pink",    kind: "human"  },
  vale:  { name: "vale",  color: "text-violet",  kind: "agent"  },
  orr:   { name: "orr",   color: "text-cyan",    kind: "agent"  },
  sys:   { name: "froth", color: "text-fg-mute", kind: "system" },
};

/* A Turn = one chat contribution.
   Inline by default (name in gutter, one-line body).
   `block` flag enables multi-line body content (artifacts, quotes).
*/
function Turn({ who, when, block = false, threaded = false, isChild = false, hot = false, children }) {
  const p = PEOPLE[who] || {};
  const threadCls = hot
    ? "bg-cyan shadow-[0_0_6px_-1px_rgba(75,212,227,0.7)]"
    : "bg-line";
  const nodeCls = hot
    ? "bg-cyan shadow-[0_0_6px_-1px_rgba(75,212,227,0.7)]"
    : "bg-cyan/40";
  return (
    <div
      className={[
        "grid gap-x-4 px-7 relative",
        "grid-cols-[56px_1fr_56px]",
        block ? "py-1.5" : "py-0.5",
      ].join(" ")}
      data-screen-label="turn"
    >
      {/* gutter — name + optional thread/node */}
      <div className="relative text-right">
        <span className={"font-sans font-medium tracking-tight " + (p.color || "")}>{p.name}</span>
        {threaded && (
          <span className={"absolute left-[calc(100%+8px)] top-5 bottom-0 w-px " + threadCls} />
        )}
        {isChild && (
          <span className={"absolute left-[calc(100%+6px)] top-2.5 w-2 h-2 -translate-x-1/2 " + nodeCls} />
        )}
      </div>
      {/* body */}
      <div className="min-w-0">{children}</div>
      {/* when */}
      <div className="font-mono text-2xs text-fg-ghost tabular-nums text-right pt-[2px]">{when}</div>
    </div>
  );
}

function Msg({ children }) {
  return <span className="text-fg-dim">{children}</span>;
}

function QuotePrior({ src, onOpen, children }) {
  return (
    <div className="mt-1 border-l-2 border-cyan/40 pl-3 py-1 flex flex-col gap-1">
      <span
        className="text-cyan font-sans text-2xs cursor-pointer hover:underline"
        onClick={onOpen}
      >↳ {src}</span>
      {children}
    </div>
  );
}

/* Artifact wrapper — minimal, un-framed.
   Renders children inline; caption/lineage shown as micro-footer.
*/
function Artifact({ kind, caption, lineage, onOpen, children }) {
  return (
    <div className="my-1.5">
      <div
        className={onOpen ? "cursor-pointer" : ""}
        onClick={(e) => {
          if (e.target.closest("button, a, .no-open")) return;
          onOpen && onOpen();
        }}
      >
        {children}
      </div>
      {(caption || (lineage && lineage.length > 0)) && (
        <div className="mt-1.5 flex flex-wrap items-baseline gap-x-3 gap-y-0.5 font-sans text-2xs text-fg-mute">
          {caption && <span>{caption}</span>}
          {lineage && lineage.map((l, i) => (
            <span
              key={i}
              className={"inline-flex items-baseline gap-1 " + (l.onClick ? "cursor-pointer hover:text-cyan" : "")}
              onClick={(e) => { e.stopPropagation(); l.onClick && l.onClick(); }}
            >
              <span className="text-fg-ghost">↳</span>{l.label}
            </span>
          ))}
        </div>
      )}
    </div>
  );
}

Object.assign(window, {
  PEOPLE, Turn, Msg, QuotePrior, Artifact,
  useState, useEffect, useRef, useMemo,
});
