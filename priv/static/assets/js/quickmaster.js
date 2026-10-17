// Quickmaster boot + rotary knob hook. Plain JS, no build step.
// `app.js` is the pristine Phoenix LiveView client copied from
// deps/phoenix_live_view/priv/static/phoenix_live_view.js.

const Knob = {
  mounted() {
    this.dragging = false;
    this.min = parseFloat(this.el.dataset.min);
    this.max = parseFloat(this.el.dataset.max);
    this.step = parseFloat(this.el.dataset.step || "0.01");
    this.decimals = parseInt(this.el.dataset.decimals || "2", 10);
    this.value = parseFloat(this.el.dataset.value);
    this.line = this.el.querySelector(".qm-knob-indicator");
    this.readout = this.el.querySelector(".qm-knob-value");
    this.render();

    this.el.addEventListener("pointerdown", (e) => this.start(e));
    this.el.addEventListener("keydown", (e) => this.key(e));
  },

  updated() {
    if (!this.dragging) {
      this.value = parseFloat(this.el.dataset.value);
      this.render();
    }
  },

  render() {
    const t = (this.value - this.min) / (this.max - this.min || 1);
    const angle = (-135 + t * 270 - 90) * (Math.PI / 180);
    const cx = 50;
    const cy = 50;
    const r1 = 24;
    const r2 = 40;
    const c = Math.cos(angle);
    const s = Math.sin(angle);
    this.line.setAttribute("x1", (cx + r1 * c).toFixed(2));
    this.line.setAttribute("y1", (cy + r1 * s).toFixed(2));
    this.line.setAttribute("x2", (cx + r2 * c).toFixed(2));
    this.line.setAttribute("y2", (cy + r2 * s).toFixed(2));
    this.el.setAttribute("aria-valuenow", String(this.value));
    if (this.readout) this.readout.textContent = this.value.toFixed(this.decimals);
  },

  start(e) {
    e.preventDefault();
    this.el.setPointerCapture(e.pointerId);
    this.dragging = true;
    this.startY = e.clientY;
    this.startT = (this.value - this.min) / (this.max - this.min || 1);
    this.el.classList.add("dragging");

    const move = (ev) => {
      const fine = ev.shiftKey ? 0.2 : 1;
      let t = this.startT + ((this.startY - ev.clientY) / 160) * fine;
      t = Math.min(1, Math.max(0, t));
      const raw = this.min + t * (this.max - this.min);
      let v = Math.round(raw / this.step) * this.step;
      v = Math.min(this.max, Math.max(this.min, v));
      this.value = v;
      this.render();
    };

    const up = () => {
      this.dragging = false;
      this.el.classList.remove("dragging");
      this.el.removeEventListener("pointermove", move);
      this.el.removeEventListener("pointerup", up);
      this.push();
    };

    this.el.addEventListener("pointermove", move);
    this.el.addEventListener("pointerup", up);
  },

  key(e) {
    const dir = { ArrowUp: 1, ArrowRight: 1, ArrowDown: -1, ArrowLeft: -1 }[e.key];
    if (!dir) return;
    e.preventDefault();
    const mult = e.shiftKey ? 0.1 : 1;
    let v = this.value + dir * this.step * 10 * mult;
    v = Math.min(this.max, Math.max(this.min, v));
    this.value = v;
    this.render();
    this.push();
  },

  push() {
    this.pushEvent("param", {
      name: this.el.dataset.name,
      value: String(this.value)
    });
  }
};

window.addEventListener("DOMContentLoaded", () => {
  const csrf = document.querySelector("meta[name='csrf-token']").getAttribute("content");
  // LiveSocket requires a Phoenix Socket class as its second argument;
  // passing an options object throws and leaves the page unconnected.
  new window.LiveView.LiveSocket("/live", window.Phoenix.Socket, {
    hooks: { Knob: Knob },
    params: { _csrf_token: csrf }
  }).connect();
});