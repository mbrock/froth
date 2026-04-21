// Sidebar · composer · tweaks · scenario data (Tailwind edition)

// ═════════════════════ PODCAST WAVEFORM ═════════════════════
const PODCAST_WAVE = [
  0.3,0.5,0.7,0.4,0.8,0.6,0.9,0.5,0.3,0.7,0.8,0.5,0.4,0.6,0.9,0.7,
  0.8,0.5,0.6,0.4,0.3,0.7,0.9,0.8,0.5,0.6,0.4,0.7,0.3,0.5,0.8,0.6,
  0.9,0.7,0.4,0.5,0.3,0.8,0.6,0.7,0.4,0.9,0.5,0.6,0.3,0.8,0.7,0.5,
  0.4,0.6,0.9,0.7,0.3,0.5,0.8,0.6,0.4,0.7,0.9,0.5,0.3,0.6,0.8,0.4,
];

// ═════════════════════ ARTIFACT DATA ═════════════════════
const ARTIFACT_META = {
  "photo-invoice": {
    id: "img.20260421.135234",
    kind: "image",
    kindLabel: "photograph",
    name: "invoice — Latvian tax authority",
    version: "v1",
    by: "mira",
    created: "2026-04-21 · 13:52",
    ancestors: [],
    descendants: [
      { kind: "parsed", name: "invoice · LV-2026-00412", by: "vale" },
      { kind: "cite",   name: "tuesday dispatch", by: "vale" },
    ],
    history: [
      { when: "13:52:34", op: "create", what: "uploaded from phone", by: "mira" },
      { when: "13:54:12", op: "cite",   what: "referenced by vale/parsed-invoice", by: "vale" },
      { when: "17:00:42", op: "cite",   what: "cited in podcast (0:14)", by: "vale" },
    ],
  },
  "parsed-invoice": {
    id: "inv.LV-2026-00412",
    kind: "ledger",
    kindLabel: "parsed invoice",
    name: "State Revenue Service · LV — €875.40",
    version: "v2",
    by: "vale",
    created: "2026-04-21 · 13:54",
    ancestors: [
      { kind: "photograph", name: "invoice — Latvian tax authority", by: "mira" },
    ],
    descendants: [
      { kind: "shell", name: "SEPA signing", by: "orr" },
      { kind: "bug-quote", name: "tabular figures bug", by: "jonas" },
      { kind: "patch", name: "invoice.tsx · +3/-2", by: "orr" },
      { kind: "cite", name: "tuesday dispatch", by: "vale" },
    ],
    history: [
      { when: "13:54:12", op: "create", what: "OCR parsed (9 fields)", by: "vale" },
      { when: "14:04:58", op: "sign",   what: "authorized by mira (touch-id)", by: "mira" },
      { when: "14:07:21", op: "settle", what: "SEPA confirmed · block 21,417,308", by: "orr" },
      { when: "14:33:02", op: "cite",   what: "quoted as bug reference", by: "jonas" },
      { when: "14:35:17", op: "revise", what: "rendered via patched invoice.tsx", by: "orr" },
    ],
    body: "parsed fields: payer, amount, ref, due date, IBAN, issue date, fee code, interest, VAT id.",
  },
  "payment-shell": {
    id: "run.sepa.tx7a1c4f09",
    kind: "shell",
    kindLabel: "shell trace",
    name: "SEPA signing · 4 commands · 2.2s",
    version: "v1",
    by: "orr",
    created: "2026-04-21 · 14:05",
    ancestors: [
      { kind: "ledger", name: "invoice · LV-2026-00412", by: "vale" },
    ],
    descendants: [
      { kind: "cite", name: "tuesday dispatch", by: "vale" },
    ],
    history: [
      { when: "14:05:01", op: "create", what: "signing flow invoked", by: "orr" },
      { when: "14:05:04", op: "sign",   what: "private key on phone accepted", by: "mira" },
      { when: "14:05:16", op: "emit",   what: "broadcast to SEPA clearer", by: "orr" },
      { when: "14:07:21", op: "settle", what: "confirmed · block 21,417,308", by: "orr" },
    ],
  },
  "code-fix": {
    id: "patch.be44e1a",
    kind: "patch",
    kindLabel: "code patch",
    name: "invoice.tsx · tabular-nums on .amt",
    version: "v1",
    by: "orr",
    created: "2026-04-21 · 14:35",
    ancestors: [
      { kind: "quote",  name: "jonas flags baseline shift", by: "jonas" },
      { kind: "ledger", name: "invoice · LV-2026-00412", by: "vale" },
    ],
    descendants: [
      { kind: "cite", name: "tuesday dispatch", by: "vale" },
    ],
    history: [
      { when: "14:35:02", op: "create", what: "patch composed from jonas' trace", by: "orr" },
      { when: "14:35:14", op: "test",   what: "42/42 passing · visual-regression clean", by: "orr" },
      { when: "14:35:17", op: "merge",  what: "fast-forward to main · commit be44e1a", by: "orr" },
    ],
  },
  "podcast": {
    id: "audio.dispatch.2026-04-21",
    kind: "audio",
    kindLabel: "audio · podcast",
    name: "tuesday dispatch — tax, tabular figures, the Luna Press ratio",
    version: "v1",
    by: "vale",
    created: "2026-04-21 · 17:00",
    ancestors: [
      { kind: "image",  name: "invoice photo", by: "mira" },
      { kind: "ledger", name: "invoice · LV-2026-00412", by: "vale" },
      { kind: "patch",  name: "invoice.tsx · +3/-2", by: "orr" },
    ],
    descendants: [],
    history: [
      { when: "17:00:42", op: "create", what: "rendered · 6:12 · 34 source citations", by: "vale" },
    ],
  },
};

// ═════════════════════ TWEAK DEFAULTS ═════════════════════
const TWEAK_DEFAULTS = /*EDITMODE-BEGIN*/{
  "density": "comfortable",
  "provenance": "visible",
  "accent": "amber"
}/*EDITMODE-END*/;

// ═════════════════════ COMPOSER ═════════════════════
function Composer() {
  const [val, setVal] = useState("");
  return (
    <div className="border-t border-line bg-bg px-7 py-3">
      <input
        value={val}
        onChange={(e) => setVal(e.target.value)}
        placeholder="say something, or / to call an agent"
        className="w-full max-w-[860px] mx-auto block bg-raised border border-line px-4 h-9 text-fg placeholder:text-fg-ghost focus:border-amber focus:outline-0 transition-colors text-sm"
      />
    </div>
  );
}

// ═════════════════════ SIDEBAR ═════════════════════
function SideRow({ glyph, name, meta, active, onClick, onHover }) {
  return (
    <div
      className={[
        "flex items-baseline gap-2 px-4 py-1.5 cursor-pointer transition-colors",
        active ? "bg-amber/10 text-fg" : "hover:bg-glow text-fg-dim",
      ].join(" ")}
      onClick={onClick}
      onMouseEnter={onHover && (() => onHover(true))}
      onMouseLeave={onHover && (() => onHover(false))}
    >
      <span className="w-4 text-center text-fg-mute">{glyph}</span>
      <span className="flex-1 min-w-0 truncate">{name}</span>
      {meta && <span className="text-2xs text-fg-ghost">{meta}</span>}
    </div>
  );
}

function Sidebar({ activeKey, onOpen, onHover }) {
  return (
    <aside className="w-[260px] border-r border-line bg-bg flex flex-col h-screen">
      <div className="px-4 py-4 flex items-baseline gap-2 border-b border-line">
        <span className="text-amber">❡</span>
        <span className="text-fg font-medium tracking-tight">froth</span>
        <span className="ml-auto text-2xs text-fg-mute">mira</span>
      </div>

      <div className="px-4 py-3 border-b border-line">
        <div className="text-2xs text-fg-mute mb-0.5">room</div>
        <div className="text-fg">
          <span className="text-amber">#</span>luna-dd
        </div>
        <div className="text-2xs text-fg-mute mt-1">mira, jonas + vale, orr</div>
      </div>

      <div className="py-2 overflow-y-auto flex-1">
        <div className="text-2xs text-fg-mute px-4 py-1.5">artifacts · today</div>
        <SideRow
          glyph="▣" name="invoice · LV-2026-00412" meta="v2"
          active={activeKey === "parsed-invoice"}
          onClick={() => onOpen("parsed-invoice")}
          onHover={(h) => onHover(h ? "parsed-invoice" : null)}
        />
        <SideRow
          glyph="▢" name="invoice photo" meta="heic"
          active={activeKey === "photo-invoice"}
          onClick={() => onOpen("photo-invoice")}
          onHover={(h) => onHover(h ? "photo-invoice" : null)}
        />
        <SideRow
          glyph="$" name="SEPA signing · 2.2s" meta="4 cmd"
          active={activeKey === "payment-shell"}
          onClick={() => onOpen("payment-shell")}
          onHover={(h) => onHover(h ? "payment-shell" : null)}
        />
        <SideRow
          glyph="▼" name="invoice.tsx · patch" meta="+3/-2"
          active={activeKey === "code-fix"}
          onClick={() => onOpen("code-fix")}
          onHover={(h) => onHover(h ? "code-fix" : null)}
        />
        <SideRow
          glyph="♪" name="tuesday dispatch" meta="6:12"
          active={activeKey === "podcast"}
          onClick={() => onOpen("podcast")}
          onHover={(h) => onHover(h ? "podcast" : null)}
        />
      </div>

      <div className="px-4 py-3 border-t border-line text-2xs">
        <div className="grid grid-cols-[64px_1fr] gap-2 gap-y-0.5">
          <span className="text-fg-ghost">status</span>
          <span className="text-green">● live</span>
          <span className="text-fg-ghost">agents</span>
          <span className="text-fg-dim"><span className="font-mono">2</span> online</span>
          <span className="text-fg-ghost">room age</span>
          <span className="text-fg-dim"><span className="font-mono">3d 4h</span></span>
        </div>
      </div>
    </aside>
  );
}

// ═════════════════════ TWEAKS PANEL ═════════════════════
function TweaksRow({ label, value, options, onChange }) {
  return (
    <div className="flex flex-col gap-1">
      <label className="text-2xs text-fg-mute">{label}</label>
      <div className="flex gap-1">
        {options.map((o) => (
          <button
            key={o}
            onClick={() => onChange(o)}
            className={[
              "px-2 py-1 text-2xs border transition-colors",
              value === o
                ? "border-amber text-amber bg-amber/10"
                : "border-line text-fg-mute hover:text-fg hover:border-line-strong",
            ].join(" ")}
          >{o}</button>
        ))}
      </div>
    </div>
  );
}

function TweaksPanel({ open, onClose, state, setState }) {
  if (!open) return null;
  return (
    <div className="fixed bottom-4 right-4 w-[280px] bg-raised border border-line z-30">
      <div className="flex items-baseline gap-2 px-4 py-2 border-b border-line">
        <span className="text-amber">❡</span>
        <b className="text-amber font-medium">Tweaks</b>
        <span
          className="ml-auto cursor-pointer text-fg-ghost hover:text-fg-dim"
          onClick={onClose}
        >✕</span>
      </div>
      <div className="p-4 flex flex-col gap-4">
        <TweaksRow
          label="density"
          value={state.density}
          options={["compact", "comfortable", "loose"]}
          onChange={(v) => setState({ ...state, density: v })}
        />
        <TweaksRow
          label="provenance"
          value={state.provenance}
          options={["visible", "subtle", "off"]}
          onChange={(v) => setState({ ...state, provenance: v })}
        />
        <TweaksRow
          label="accent"
          value={state.accent}
          options={["amber", "cyan", "violet", "green"]}
          onChange={(v) => setState({ ...state, accent: v })}
        />
      </div>
    </div>
  );
}

Object.assign(window, {
  PODCAST_WAVE, ARTIFACT_META, TWEAK_DEFAULTS,
  Composer, Sidebar, TweaksPanel,
});
