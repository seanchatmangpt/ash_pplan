/**
 * ScrubberHook: Bridges Phoenix LiveView to the Visx / SVG Forensic Timeline Scrubber.
 * Allows scrubbing through millisecond-level checkpoint tapes.
 */

export const ScrubberHook = {
  mounted() {
    this.tape = this.el.dataset.tape ? JSON.parse(this.el.dataset.tape) : [];
    this.renderScrubber();

    this.handleEvent("tape_append", (checkpoint) => {
      this.tape = [...this.tape, checkpoint];
      this.renderScrubber();
    });
  },

  updated() {
    if (this.el.dataset.tape) {
      this.tape = JSON.parse(this.el.dataset.tape);
      this.renderScrubber();
    }
  },

  renderScrubber() {
    this.el.innerHTML = `
      <div class="w-full flex items-center justify-between font-mono text-[10px] text-zinc-400">
        <div class="flex items-center gap-2">
          <span class="text-emerald-400 font-bold">PLAYHEAD ▶</span>
          <span>COMMITTED CHECKPOINTS: <strong>${this.tape.length}</strong></span>
        </div>
        <div class="flex items-center gap-1">
          ${this.tape
            .map(
              (cp, i) => `
            <span class="px-1.5 py-0.5 rounded bg-zinc-800 text-zinc-300 border border-zinc-700 cursor-pointer hover:border-emerald-500" title="${cp.label || cp.id}">
              #${cp.seq || i + 1}
            </span>
          `
            )
            .join("")}
        </div>
      </div>
    `;
  },
};
