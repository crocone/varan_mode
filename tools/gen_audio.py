#!/usr/bin/env python3
"""
Procedural sound-effect generator for VaranMod.

Every sound is synthesised from scratch with numpy (filtered noise, modal
resonators, additive/formant voices, granular bubbles, FM, envelopes).
No external assets, no scipy.

Usage (from the project root):
    python tools/gen_audio.py

Output: 16-bit PCM mono WAV @ 22050 Hz in game/assets/audio/.
Output is deterministic (fixed seed; each sound has its own derived RNG).

Loop strategy: loops are built *circularly* -- noise is filtered in the FFT
domain over exactly one loop period, all modulators have an integer number of
cycles per loop, grains wrap around the loop boundary and reverb/delay are
circular convolutions.  Where a layer cannot be built circularly (a
time-varying recursive filter) it is rendered longer and the tail is
cross-faded into the head (make_loop_seamless).
"""
from __future__ import annotations

import time
import wave
import zlib
from pathlib import Path

import numpy as np

SR = 22050
SEED = 7331
TAU = 2.0 * np.pi
ROOT = Path(__file__).resolve().parent.parent
OUT_DIR = ROOT / "game" / "assets" / "audio"


# =============================================================================
# Basic helpers
# =============================================================================
def ns(sec: float) -> int:
    """Seconds -> samples."""
    return max(1, int(round(sec * SR)))


def tax(n: int) -> np.ndarray:
    """Time axis in seconds for n samples."""
    return np.arange(n) / SR


def nrm(x: np.ndarray, peak: float = 1.0) -> np.ndarray:
    m = float(np.max(np.abs(x))) if len(x) else 0.0
    return x * (peak / m) if m > 0 else x


def rmsn(x: np.ndarray, rms: float = 1.0) -> np.ndarray:
    s = float(np.sqrt(np.mean(x * x)))
    return x * (rms / s) if s > 0 else x


def loguni(r, a, b, size=None):
    return np.exp(r.uniform(np.log(a), np.log(b), size))


def loopfreq(f: float, loop_len: float) -> float:
    """Nearest frequency with an integer number of cycles per loop."""
    return max(1, round(f * loop_len)) / loop_len


def db(x: float) -> float:
    return 20.0 * np.log10(max(x, 1e-12))


# =============================================================================
# Noise
# =============================================================================
def white(r, n: int) -> np.ndarray:
    return r.standard_normal(n)


def colored(r, n: int, alpha: float) -> np.ndarray:
    """1/f^alpha noise (0.5 = pink, 1 = brown). Periodic over n samples."""
    X = np.fft.rfft(r.standard_normal(n))
    f = np.maximum(np.fft.rfftfreq(n, 1.0 / SR), 20.0)
    X *= (f / 100.0) ** (-alpha)
    X[0] = 0.0
    y = np.fft.irfft(X, n)
    return y / (np.std(y) + 1e-12)


def smooth_noise(r, n: int, rate: float) -> np.ndarray:
    """Slow random control signal, roughly in [-1, 1]; periodic over n."""
    y = filt(r.standard_normal(n), r_lp(rate, 2), circular=True)
    s = np.std(y)
    return y / (3.0 * s) if s > 0 else y


# =============================================================================
# Filters
#   * FFT-domain magnitude responses (zero-phase).  circular=True filters over
#     exactly the buffer length -> the result is perfectly periodic (loops).
#   * Time-varying TPT state-variable filter (python loop, short sounds only).
# =============================================================================
def r_lp(fc, order=2):
    return lambda f: 1.0 / np.sqrt(1.0 + (f / fc) ** (2 * order))


def r_hp(fc, order=2):
    return lambda f: 1.0 / np.sqrt(1.0 + (fc / np.maximum(f, 1e-3)) ** (2 * order))


def r_bp(fc, q=1.0):
    """2nd-order band-pass magnitude, unity gain at fc."""
    def h(f):
        f = np.maximum(f, 1e-3)
        x = q * (f / fc - fc / f)
        return 1.0 / np.sqrt(1.0 + x * x)
    return h


def r_peak(fc, q, gain_db):
    g = 10.0 ** (gain_db / 20.0)
    b = r_bp(fc, q)
    return lambda f: 1.0 + (g - 1.0) * b(f)


def _fft_size(n: int) -> int:
    p = 1
    while p < n:
        p *= 2
    return p


def filt(x: np.ndarray, *resp, circular: bool = False) -> np.ndarray:
    n = len(x)
    N = n if circular else _fft_size(n + max(4096, min(n, SR)))
    X = np.fft.rfft(x, N)
    f = np.fft.rfftfreq(N, 1.0 / SR)
    H = np.ones_like(f)
    for h in resp:
        H = H * h(f)
    return np.fft.irfft(X * H, N)[:n]


def svf(x: np.ndarray, fc, q=0.707, mode: str = "bp") -> np.ndarray:
    """Time-varying TPT (Zavalishin/Cytomic) state-variable filter.
    fc and q may be scalars or per-sample arrays.  'bp' has unity peak gain."""
    n = len(x)
    fc = np.clip(np.broadcast_to(np.asarray(fc, float), (n,)), 10.0, SR * 0.45)
    q = np.broadcast_to(np.asarray(q, float), (n,))
    g = np.tan(np.pi * fc / SR)
    k = 1.0 / q
    a1 = 1.0 / (1.0 + g * (g + k))
    a2 = g * a1
    a3 = g * a2
    xs, A1, A2, A3, K = x.tolist(), a1.tolist(), a2.tolist(), a3.tolist(), k.tolist()
    out = [0.0] * n
    s1 = s2 = 0.0
    m = {"lp": 0, "bp": 1, "hp": 2}[mode]
    for i in range(n):
        v0 = xs[i]
        v3 = v0 - s2
        v1 = A1[i] * s1 + A2[i] * v3
        v2 = s2 + A2[i] * s1 + A3[i] * v3
        s1 = 2.0 * v1 - s1
        s2 = 2.0 * v2 - s2
        if m == 0:
            out[i] = v2
        elif m == 1:
            out[i] = v1 * K[i]
        else:
            out[i] = v0 - K[i] * v1 - v2
    return np.asarray(out)


# =============================================================================
# Envelopes & placement
# =============================================================================
def smooth(x: np.ndarray, win_s: float) -> np.ndarray:
    w = ns(win_s)
    w = max(3, w + (1 - w % 2))
    k = np.hanning(w)
    k /= k.sum()
    p = w // 2
    return np.convolve(np.pad(x, p, mode="edge"), k, mode="valid")


def curve(n: int, pts, smooth_s: float = 0.0) -> np.ndarray:
    """Piecewise-linear curve through (time_s, value) points."""
    ts, vs = zip(*pts)
    y = np.interp(tax(n), ts, vs)
    return smooth(y, smooth_s) if smooth_s > 0 else y


def env_ad(n: int, attack: float, decay: float, start: float = 0.0) -> np.ndarray:
    """Smooth (sin^2) attack then exponential decay."""
    t = tax(n) - start
    if attack > 0:
        a = np.sin(0.5 * np.pi * np.clip(t / attack, 0.0, 1.0)) ** 2
    else:
        a = (t >= 0).astype(float)
    e = a * np.exp(-np.clip(t - attack, 0.0, None) / decay)
    e[t < 0] = 0.0
    return e


def fades(x: np.ndarray, fin: float = 0.0015, fout: float = 0.02) -> np.ndarray:
    y = x.copy()
    a, b = ns(fin), ns(fout)
    if a > 1:
        y[:a] *= 0.5 - 0.5 * np.cos(np.linspace(0.0, np.pi, a))
    if b > 1:
        y[-b:] *= 0.5 + 0.5 * np.cos(np.linspace(0.0, np.pi, b))
    return y


def place(buf: np.ndarray, sig: np.ndarray, t0: float, circular: bool = False) -> None:
    """Add sig into buf starting at time t0 (seconds). Circular wraps around."""
    n = len(buf)
    i0 = int(round(t0 * SR))
    if circular:
        i0 %= n
        rest = sig
        pos = i0
        while len(rest):
            take = min(len(rest), n - pos)
            buf[pos:pos + take] += rest[:take]
            rest = rest[take:]
            pos = 0
        return
    if i0 >= n:
        return
    if i0 < 0:
        sig = sig[-i0:]
        i0 = 0
    L = min(len(sig), n - i0)
    if L > 0:
        buf[i0:i0 + L] += sig[:L]


def crackle_env(n: int, times, amps, decays, attack: float = 0.0003) -> np.ndarray:
    """Sum of tiny exponential grains -> modulator for crackles/rustles."""
    e = np.zeros(n)
    for ti, a, d in zip(times, amps, decays):
        i0 = int(round(ti * SR))
        if i0 >= n or i0 < 0:
            continue
        L = min(n - i0, ns(d * 7) + 1)
        tg = tax(L)
        e[i0:i0 + L] += a * (1.0 - np.exp(-tg / attack)) * np.exp(-tg / d)
    return e


def make_loop_seamless(x: np.ndarray, n_loop: int, xfade_s: float) -> np.ndarray:
    """x must be at least n_loop + xfade long.  Cross-fades the material that
    follows the loop end into the loop head (equal-power), so that sample
    n_loop-1 -> 0 is continuous."""
    xf = ns(xfade_s)
    assert len(x) >= n_loop + xf
    y = x[:n_loop].copy()
    u = np.linspace(0.0, 1.0, xf)
    y[:xf] = x[:xf] * np.sin(0.5 * np.pi * u) + x[n_loop:n_loop + xf] * np.cos(0.5 * np.pi * u)
    return y


# =============================================================================
# Synthesis building blocks
# =============================================================================
def tail_fade(y: np.ndarray, frac: float = 0.12) -> np.ndarray:
    """Raised-cosine fade over the last `frac` of a grain so that truncated
    resonances never end in a step (click)."""
    b = max(2, int(len(y) * frac))
    y = y.copy()
    y[-b:] *= 0.5 + 0.5 * np.cos(np.linspace(0.0, np.pi, b))
    return y


def thump(n: int, f_start: float, f_end: float, decay: float, attack: float = 0.002) -> np.ndarray:
    """Sine with falling pitch and exponential decay (body impact)."""
    t = tax(n)
    f = f_end + (f_start - f_end) * np.exp(-t / (decay * 0.6))
    ph = TAU * np.cumsum(f) / SR
    return tail_fade(env_ad(n, attack, decay) * np.sin(ph))


def modal(dur: float, modes, attack: float = 0.0004) -> np.ndarray:
    """Struck resonator: modes = [(freq, decay_s, amp), ...]."""
    n = ns(dur)
    t = tax(n)
    y = np.zeros(n)
    for f, d, a in modes:
        if f < SR * 0.45:
            y += a * np.exp(-t / d) * np.sin(TAU * f * t)
    if attack > 0:
        y *= np.clip(t / attack, 0.0, 1.0)
    return tail_fade(y)


def click(r, f_lo, f_hi, decay, n_modes=3, noise=0.4) -> np.ndarray:
    """Tiny brittle click: a few random high modes + noise transient."""
    f_hi = min(f_hi, 9500.0)
    m = ns(decay * 7) + 16
    t = tax(m)
    y = np.zeros(m)
    for _ in range(n_modes):
        f = loguni(r, f_lo, f_hi)
        d = decay * r.uniform(0.5, 1.4)
        y += r.uniform(0.4, 1.0) * np.exp(-t / d) * np.sin(TAU * f * t + r.uniform(0, 0.5))
    if noise > 0:
        y += noise * r.standard_normal(m) * np.exp(-t / (decay * 0.35))
    return y * np.clip(t / 0.00025, 0.0, 1.0)


def bubble(r, f0: float, amp: float = 1.0, tau: float | None = None, rise: float | None = None) -> np.ndarray:
    """Van den Doel-style bubble: damped sine with rising pitch."""
    if tau is None:
        tau = 0.012 * (600.0 / f0) ** 0.6 * r.uniform(0.7, 1.4)
    if rise is None:
        rise = r.uniform(0.08, 0.3)
    m = ns(tau * 6.5)
    t = tax(m)
    f = f0 * (1.0 + rise * t / tau)
    ph = TAU * np.cumsum(f) / SR
    env = (1.0 - np.exp(-t / 0.0006)) * np.exp(-t / tau)
    return amp * env * np.sin(ph)


def pulse_am(r, n: int, rate, sharp: float = 2.0, jitter: float = 0.1, jitter_rate: float = 8.0) -> np.ndarray:
    """Irregular pulse-train amplitude modulator in [0, 1] (roughness/rasp)."""
    rate = np.broadcast_to(np.asarray(rate, float), (n,)) * (1.0 + jitter * smooth_noise(r, n, jitter_rate))
    ph = np.cumsum(rate) / SR
    return (0.5 + 0.5 * np.cos(TAU * ph)) ** sharp


def loop_fix(f: np.ndarray) -> np.ndarray:
    """Scale a frequency trajectory so it completes an integer number of cycles."""
    c = f.sum() / SR
    return f * (max(1, round(c)) / c)


def voice(f0: np.ndarray, formants, tilt: float = 1.0, fmax: float = 5000.0, r=None,
          floor: float = 0.02, loop: bool = False) -> np.ndarray:
    """Additive formant voice.  f0: per-sample pitch.  formants: [(F, BW, gain)]
    where each may be a scalar or per-sample array.  Each harmonic gets the
    spectral-envelope value at its instantaneous frequency."""
    rr = r if r is not None else np.random.default_rng(1)
    f0 = np.asarray(f0, float)
    if loop:
        f0 = loop_fix(f0)
        ph = TAU * (np.cumsum(f0) - f0[0]) / SR
    else:
        ph = TAU * np.cumsum(f0) / SR
    lim = min(fmax, SR * 0.45)
    K = int(max(1, min(160, lim / max(float(np.min(f0)), 15.0))))
    out = np.zeros(len(f0))
    for k in range(1, K + 1):
        fk = k * f0
        g = np.full(len(f0), floor)
        for F, B, A in formants:
            g = g + A / np.sqrt(1.0 + ((fk - F) / (0.5 * B)) ** 2)
        g *= np.clip((lim - fk) / 300.0, 0.0, 1.0) / k ** tilt
        out += g * np.sin(k * ph + rr.uniform(0, TAU))
    return out


# ---- reverb / delay ---------------------------------------------------------
def reverb_ir(r, t60: float, dur: float | None = None, bright: float = 7000.0,
              dark: float = 1500.0, predelay: float = 0.008) -> np.ndarray:
    dur = dur or t60 * 1.1
    n = ns(dur)
    t = tax(n)
    nz = r.standard_normal(n)
    b = filt(nz, r_lp(bright, 1))
    d = filt(nz, r_lp(dark, 1))
    w = np.exp(-t / (0.18 * t60))
    ir = (b * w + d * (1.0 - w)) * 10.0 ** (-3.0 * t / t60)
    ir *= np.clip(t / 0.003, 0.0, 1.0)
    ir = np.concatenate([np.zeros(ns(predelay)), ir])
    return ir / np.sqrt(np.sum(ir * ir))


def convolve(x: np.ndarray, ir: np.ndarray, circular: bool = False) -> np.ndarray:
    if circular:
        N = len(x)
        irp = np.zeros(N)
        irp[:min(len(ir), N)] = ir[:N]
        return np.fft.irfft(np.fft.rfft(x) * np.fft.rfft(irp), N)
    N = _fft_size(len(x) + len(ir))
    return np.fft.irfft(np.fft.rfft(x, N) * np.fft.rfft(ir, N), N)[:len(x)]


def reverb(x: np.ndarray, r, t60: float, mix: float, circular: bool = False, **kw) -> np.ndarray:
    wet = convolve(x, reverb_ir(r, t60, **kw), circular)
    wet = wet * (np.max(np.abs(x)) / (np.max(np.abs(wet)) + 1e-12))
    return x + mix * wet


def delay_circ(x: np.ndarray, delay_s: float, fb: float, taps: int = 6, damp: float = 3000.0) -> np.ndarray:
    """Circular feedback-delay echoes (wet only) computed in the FFT domain."""
    n = len(x)
    X = np.fft.rfft(x)
    f = np.fft.rfftfreq(n, 1.0 / SR)
    lp = r_lp(damp, 1)(f)
    H = np.zeros_like(X)
    for i in range(1, taps + 1):
        H += (fb ** i) * np.exp(-1j * TAU * f * i * delay_s) * lp ** i
    return np.fft.irfft(X * H, n)


# =============================================================================
# Birds (shared by one-shots and ambience)
# =============================================================================
def render_notes(n: int, notes, harm=(1.0, 0.1, 0.03)) -> np.ndarray:
    """notes: (t0, dur, [freq points], trill_rate, trill_depth, amp)."""
    out = np.zeros(n)
    for t0, dur, fpts, tr_rate, tr_depth, amp in notes:
        m = ns(dur)
        u = np.linspace(0.0, 1.0, m)
        tn = tax(m)
        f = np.interp(u, np.linspace(0.0, 1.0, len(fpts)), fpts)
        env = np.sin(0.5 * np.pi * np.clip(u / 0.15, 0, 1)) ** 2 * np.sin(0.5 * np.pi * np.clip((1 - u) / 0.4, 0, 1))
        if tr_rate > 0:
            f = f * (1.0 + tr_depth * np.sin(TAU * tr_rate * tn))
            env = env * (0.55 + 0.45 * np.cos(TAU * tr_rate * tn))
        ph = TAU * np.cumsum(f) / SR
        sig = np.zeros(m)
        for i, h in enumerate(harm):
            if (i + 1) * f.max() < SR * 0.45:
                sig += h * np.sin((i + 1) * ph)
        place(out, amp * env * sig, t0)
    return out


def bird_notes(r, style: str, base: float = 1.0):
    """Return (notes, duration) for a bird phrase of a given style."""
    notes = []
    t = 0.0
    if style == "warble":          # honeyeater-like warble
        for _ in range(int(r.integers(5, 8))):
            d = r.uniform(0.05, 0.13)
            f1, f2 = base * loguni(r, 2200, 4200), base * loguni(r, 2200, 4200)
            fm = 0.5 * (f1 + f2) * r.uniform(0.9, 1.2)
            tr = float(r.choice([0, 0, 28, 36]))
            notes.append((t, d, [f1, fm, f2], tr, 0.05, r.uniform(0.5, 1.0)))
            t += d + r.uniform(0.012, 0.05)
    elif style == "whistle":       # whistler-like rising series + whip
        f = base * r.uniform(1700, 2000)
        for i in range(int(r.integers(2, 4))):
            d = r.uniform(0.14, 0.2)
            notes.append((t, d, [f, f * 1.03], 6.0, 0.008, 0.55 + 0.12 * i))
            t += d + r.uniform(0.04, 0.07)
            f *= r.uniform(1.08, 1.14)
        notes.append((t, 0.24, [f, f * 1.35, f * 0.62], 0, 0, 1.0))
        t += 0.24
    elif style == "chips":         # chips + descending trill
        for _ in range(int(r.integers(2, 4))):
            fa = base * r.uniform(3300, 3800)
            notes.append((t, 0.03, [fa, fa * 1.45], 0, 0, 0.8))
            t += r.uniform(0.07, 0.1)
        t += 0.03
        k = int(r.integers(8, 13))
        for i in range(k):
            fa = base * (4800 - 1000 * i / k)
            notes.append((t, 0.022, [fa, fa * 0.82], 0, 0, 0.9 - 0.4 * i / k))
            t += 0.03
    else:                          # "bell": bellbird-like pure pings
        for _ in range(int(r.integers(2, 5))):
            fa = base * r.uniform(2500, 3100)
            notes.append((t, 0.07, [fa * 1.02, fa], 0, 0, r.uniform(0.6, 1.0)))
            t += r.uniform(0.12, 0.3)
    return notes, t


def bird_oneshot(r, style: str, base: float) -> np.ndarray:
    notes, d = bird_notes(r, style, base)
    notes = [nt for nt in notes if nt[0] + nt[1] <= 0.8] or notes[:1]
    d = max(nt[0] + nt[1] for nt in notes)
    y = render_notes(ns(d + 0.2), notes)
    y = filt(y, r_lp(7000, 2), r_hp(1000, 2))
    return reverb(y, r, 0.6, 0.18)


# =============================================================================
# Frogs (shared)
# =============================================================================
def frog_croak_sig(r, dur=0.36, carrier=600.0, rate=(72.0, 52.0)) -> np.ndarray:
    n = ns(dur + 0.05)
    y = np.zeros(n)
    env_pts = [(0, 0.0), (0.05, 1.0), (dur * 0.5, 0.85), (dur * 0.8, 0.6), (dur, 0.0)]
    t = 0.01
    while t < dur:
        u = t / dur
        rt = rate[0] + (rate[1] - rate[0]) * u
        a = np.interp(t, *zip(*env_pts)) * r.uniform(0.8, 1.0)
        fc = carrier * (1.0 + 0.08 * u) * r.uniform(0.98, 1.02)
        g = modal(0.03, [(fc, 0.005, 1.0), (fc * 2.2, 0.003, 0.45), (fc * 3.7, 0.002, 0.15)], attack=0.0008)
        place(y, a * g, t)
        t += 1.0 / rt
    return filt(y, r_hp(200, 2))


def bonk_sig(r, f=None) -> np.ndarray:
    """Pobblebonk-like 'bonk'."""
    f = f or r.uniform(420, 520)
    n = ns(0.2)
    t = tax(n)
    fr = f * (1.0 + 0.12 * np.exp(-t / 0.01))
    ph = TAU * np.cumsum(fr) / SR
    s = np.sin(ph) + 0.3 * np.sin(2 * ph) + 0.1 * np.sin(3 * ph)
    return s * env_ad(n, 0.003, 0.045)


# =============================================================================
# AMBIENCE LOOPS
# =============================================================================
def amb_day(r):
    L = 24.0
    n = ns(L)
    t = tax(n)
    # --- cicada chorus
    cic = np.zeros(n)
    for fc, q, buzz, k_slow, amp in [(4400, 3.5, 118, 3, 1.0), (5300, 4.0, 131, 4, 0.8), (5900, 3.0, 97, 5, 0.55)]:
        band = filt(white(r, n), r_bp(fc, q), r_bp(fc, q * 0.5), circular=True)
        band /= np.std(band)
        fb = loopfreq(buzz, L)
        am_buzz = 0.62 + 0.38 * (0.5 + 0.5 * np.cos(TAU * fb * t)) ** 2
        pulse = 0.8 + 0.2 * np.cos(TAU * loopfreq(r.uniform(2.5, 3.5), L) * t + r.uniform(0, TAU))
        slow = (0.55 + 0.45 * np.sin(TAU * k_slow * t / L + r.uniform(0, TAU))) ** 1.6
        wob = 1.0 + 0.25 * smooth_noise(r, n, 0.4)
        cic += amp * band * am_buzz * pulse * slow * wob
    cic = filt(cic, r_lp(7000, 2), r_hp(3000, 2), circular=True)
    # --- soft air + leaves
    air = filt(colored(r, n, 0.5), r_lp(700, 1), r_hp(60, 2), circular=True)
    air *= 0.75 + 0.25 * smooth_noise(r, n, 0.15)
    leaves = filt(white(r, n), r_hp(1500, 1), r_lp(6000, 2), circular=True)
    leaves *= np.clip(smooth_noise(r, n, 0.2), 0, None) ** 2
    # --- distant birds
    birds = np.zeros(n)
    slots = np.linspace(0, L, 11)[:-1]
    for tb in slots + r.uniform(0.2, 1.8, len(slots)):
        style = str(r.choice(["warble", "whistle", "chips", "bell"]))
        notes, d = bird_notes(r, style, base=r.uniform(0.85, 1.2))
        sig = render_notes(ns(d + 0.05), notes)
        sig = filt(sig, r_lp(r.uniform(3500, 6000), 1))
        place(birds, nrm(sig) * loguni(r, 0.3, 1.0), tb, circular=True)
    birds = birds + 0.6 * nrm(convolve(birds, reverb_ir(r, 1.4), circular=True))
    mix = rmsn(cic, 0.10) + rmsn(air, 0.07) + rmsn(leaves, 0.015) + nrm(birds, 0.22)
    return mix


def cricket_layer(r, n, L, fc, period, pulses, pulse_int, pulse_len):
    m = max(1, round(L / period))
    P = L / m
    y = np.zeros(n)
    pl = ns(pulse_len)
    u = np.linspace(0.0, 1.0, pl)
    w = np.sin(np.pi * u) ** 2
    for i in range(m):
        t0 = i * P + r.normal(0, 0.004)
        a = r.uniform(0.8, 1.0)
        for j in range(pulses):
            f = fc * (1.0 + r.normal(0, 0.003)) * (1.0 - 0.03 * u)
            ph = TAU * np.cumsum(f) / SR + r.uniform(0, TAU)
            sig = w * (np.sin(ph) + 0.08 * np.sin(2 * ph))
            aj = a * (0.75 if j == 0 else 1.0) * r.uniform(0.9, 1.0)
            place(y, aj * sig, t0 + j * pulse_int, circular=True)
    return y


def amb_night(r):
    L = 24.0
    n = ns(L)
    t = tax(n)
    c1 = cricket_layer(r, n, L, 4150, 0.55, 4, 0.034, 0.016)
    c2 = cricket_layer(r, n, L, 4480, 0.83, 3, 0.038, 0.014)
    c1 *= 0.8 + 0.2 * np.sin(TAU * 2 * t / L)
    c2 *= 0.7 + 0.3 * np.sin(TAU * 3 * t / L + 1.0)
    # trilling ground cricket: bouts of fast pulses
    c3 = np.zeros(n)
    pl = ns(0.009)
    w = np.sin(np.pi * np.linspace(0, 1, pl)) ** 2
    tp = tax(pl)
    for b in range(5):
        tb = b * L / 5 + r.uniform(0, 1.5)
        blen = r.uniform(1.5, 2.6)
        k = int(blen * 48)
        for j in range(k):
            a = np.sin(np.pi * j / k) ** 0.5
            place(c3, a * w * np.sin(TAU * 3800 * tp + r.uniform(0, TAU)), tb + j / 48.0, circular=True)
    crickets = rmsn(c1, 1.0) * 0.55 + rmsn(c2, 1.0) * 0.35 + rmsn(c3, 1.0) * 0.18
    crickets = crickets + 0.35 * convolve(crickets, reverb_ir(r, 0.9), circular=True)
    # faint insect bed
    bed = filt(white(r, n), r_bp(6200, 1.5), circular=True)
    # distant frogs
    frogs = np.zeros(n)
    for i, tf in enumerate(np.linspace(0, L, 8)[:-1] + r.uniform(0, 2.5, 7)):
        sig = frog_croak_sig(r, dur=r.uniform(0.28, 0.4), carrier=r.uniform(450, 750)) if i % 2 == 0 else bonk_sig(r)
        place(frogs, nrm(sig) * r.uniform(0.5, 1.0), tf, circular=True)
    frogs = filt(frogs, r_lp(2200, 2), circular=True)
    frogs = frogs + 0.8 * nrm(convolve(frogs, reverb_ir(r, 1.3, dark=900), circular=True), np.max(np.abs(frogs)))
    # very soft low wind: time-varying SVF (not circular) -> crossfaded loop
    xf = 2.0
    nn = n + ns(xf)
    wn = colored(r, nn, 1.0)
    fc = 180 + 120 * (0.5 + 0.5 * smooth_noise(r, nn, 0.1))
    wind_l = svf(wn, fc, 0.6, "lp")
    wind_l *= 0.7 + 0.3 * smooth_noise(r, nn, 0.08)
    wind_l = make_loop_seamless(wind_l, n, xf)
    mix = crickets * (0.06 / np.sqrt(np.mean(crickets ** 2))) + rmsn(bed, 0.006) + nrm(frogs, 0.18) + rmsn(wind_l, 0.035)
    return mix


def wind(r):
    L = 16.0
    n = ns(L)
    base = colored(r, n, 0.5)
    cuts = [110, 180, 300, 480, 760, 1200, 1900]
    bank = np.stack([filt(base, r_lp(c, 2), r_hp(35, 2), circular=True) for c in cuts])
    g = 0.55 + 0.7 * smooth_noise(r, n, 0.12) + 0.3 * smooth_noise(r, n, 0.5)
    g = np.clip(filt(np.clip(g, 0.18, 1.0), r_lp(3.0, 2), circular=True), 0.0, 1.0)
    pos = g * (len(cuts) - 1)
    i0 = np.minimum(np.floor(pos).astype(int), len(cuts) - 2)
    fr = pos - i0
    idx = np.arange(n)
    y = bank[i0, idx] * (1 - fr) + bank[i0 + 1, idx] * fr
    y *= 0.3 + 0.7 * g ** 1.3
    # faint whistle in strong gusts
    wh = filt(white(r, n), r_bp(640, 14), circular=True) + 0.6 * filt(white(r, n), r_bp(980, 16), circular=True)
    wh *= np.clip(g - 0.55, 0, None) ** 1.5
    # dry leaf rustle on gusts
    lv = filt(white(r, n), r_hp(2000, 2), r_lp(6500, 2), circular=True) * g ** 3
    return rmsn(y, 0.12) + rmsn(wh, 0.008) + rmsn(lv, 0.012)


def river(r):
    L = 16.0
    n = ns(L)
    rush = filt(colored(r, n, 0.5), r_hp(150, 2), r_lp(1800, 2), r_peak(600, 1.0, 4), circular=True)
    rush *= 0.8 + 0.2 * smooth_noise(r, n, 0.3)
    low = filt(colored(r, n, 1.0), r_lp(180, 2), r_hp(40, 2), circular=True)
    bub = np.zeros(n)
    for _ in range(int(L * 15)):
        tc = r.uniform(0, L)
        for _ in range(int(r.integers(1, 6))):
            tb = tc + r.exponential(0.025)
            f0 = loguni(r, 300, 1400)
            a = loguni(r, 0.08, 1.0) * (f0 / 600.0) ** -0.3
            place(bub, bubble(r, f0, a), tb, circular=True)
    for _ in range(int(L * 9)):
        place(bub, bubble(r, loguni(r, 1400, 2800), loguni(r, 0.03, 0.25), rise=0.2), r.uniform(0, L), circular=True)
    bub = filt(bub, r_lp(6000, 2), circular=True)
    return rmsn(rush, 0.08) + rmsn(low, 0.04) + nrm(bub, 0.45)


def pluck(r, f, dur=3.5) -> np.ndarray:
    m = ns(dur)
    t = tax(m)
    y = np.zeros(m)
    for k in range(1, 8):
        fk = f * k * np.sqrt(1.0 + 0.0003 * k * k)
        if fk > 8000:
            break
        y += (1.0 / k ** 1.4) * np.exp(-t / (1.8 / k ** 0.9)) * np.sin(TAU * fk * t + r.uniform(0, 0.3))
    return tail_fade(y * (1.0 - np.exp(-t / 0.003)), 0.3)


def music_menu(r):
    L = 40.0
    n = ns(L)
    t = tax(n)
    # --- didgeridoo-like drone (integer cycles per loop, periodic formants)
    f0 = loopfreq(65.41, L)
    f = f0 * (1 + 0.0025 * np.sin(TAU * 15 * t / L) + 0.0015 * np.sin(TAU * 7 * t / L + 1.3))
    F1 = 560 + 220 * np.sin(TAU * 2 * t / L) + 110 * np.sin(TAU * 5 * t / L + 1.0)
    F2 = 1350 + 280 * np.sin(TAU * 3 * t / L + 2.0)
    drone = voice(f, [(F1, 180, 1.0), (F2, 320, 0.45), (230, 150, 0.6)], tilt=0.75,
                  fmax=2400, r=r, floor=0.05, loop=True)
    breath = 1.0 - 0.14 * (0.5 + 0.5 * np.cos(TAU * 20 * t / L)) ** 6
    dnoise = filt(white(r, n), r_bp(600, 1.2), r_lp(1500, 2), circular=True)
    drone = rmsn(drone * breath, 0.11) + rmsn(dnoise * breath * (0.6 + 0.4 * np.sin(TAU * 2 * t / L)), 0.008)
    # --- pads (C minor pentatonic colours), circular windows
    chords = [[196.00, 261.63, 311.13], [174.61, 233.08, 311.13],
              [196.00, 233.08, 349.23], [155.56, 196.00, 261.63]]
    pad = np.zeros(n)
    W = 13.5
    m = ns(W)
    tw = tax(m)
    win = np.sin(0.5 * np.pi * np.clip(tw / 4.5, 0, 1)) ** 2 * np.sin(0.5 * np.pi * np.clip((W - tw) / 4.5, 0, 1)) ** 2
    for i, ch in enumerate(chords):
        sig = np.zeros(m)
        for fq in ch:
            for det in (-0.0023, 0.0, 0.0021):
                ff = fq * (1 + det)
                p0 = r.uniform(0, TAU)
                for h, a in enumerate([1.0, 0.38, 0.16, 0.07, 0.03], 1):
                    sig += a * np.sin(TAU * ff * h * tw + p0 * h)
        sig *= 1.0 + 0.15 * np.sin(TAU * 0.13 * tw + r.uniform(0, TAU))
        place(pad, sig * win, (i * 10.0 + 5.0 - W / 2) % L, circular=True)
    pad = filt(pad, r_lp(1400, 2), circular=True)
    # --- sparse plucks
    scale = [261.63, 311.13, 349.23, 392.00, 466.16, 523.25, 622.25, 698.46, 783.99]
    events = [(1.5, 5), (4.0, 3), (5.2, 4), (9.8, 6), (13.5, 4), (17.2, 2), (18.4, 3),
              (22.9, 5), (26.8, 7), (28.0, 5), (31.5, 3), (35.6, 4), (37.0, 2)]
    pk = np.zeros(n)
    for tn, idx in events:
        place(pk, pluck(r, scale[idx]) * r.uniform(0.6, 1.0), tn + r.uniform(-0.05, 0.05), circular=True)
    pk = filt(pk, r_lp(2600, 1), circular=True)
    pk = pk + 0.8 * delay_circ(pk, 0.75, 0.45, taps=6, damp=2200)
    pk = nrm(pk, 0.28)
    # --- circular reverb
    ir = reverb_ir(r, 3.5, dark=1200, bright=4500, predelay=0.02)
    wet = convolve(rmsn(pad, 0.05) + pk, ir, circular=True)
    wet_d = convolve(drone, ir, circular=True)
    mix = drone + 0.25 * wet_d + rmsn(pad, 0.05) + pk + 0.9 * wet
    return filt(mix, r_lp(6000, 2), circular=True)


def carcass_flies(r):
    L = 4.0
    n = ns(L)
    t = tax(n)
    y = np.zeros(n)
    for i in range(5):
        f0 = loopfreq(r.uniform(165, 235), L)
        k = int(r.integers(1, 3))
        th = TAU * k * t / L + r.uniform(0, TAU)
        # Doppler-ish: pitch leads proximity by 90 degrees
        dev = 0.035 * np.cos(th) + 0.02 * np.sin(TAU * int(r.integers(3, 8)) * t / L + r.uniform(0, TAU)) \
            + 0.008 * np.sin(TAU * int(r.integers(30, 50)) * t / L + r.uniform(0, TAU))
        f = f0 * (1.0 + dev)
        forms = [(r.uniform(500, 800), 700, 1.0), (r.uniform(1600, 2400), 1400, 0.6)]
        v = voice(f, forms, tilt=0.7, fmax=4500, r=r, floor=0.1, loop=True)
        prox = (0.5 + 0.5 * np.sin(th)) ** r.uniform(1.5, 3.0)
        y += nrm(v) * (0.12 + 0.88 * prox) * r.uniform(0.5, 1.0)
    return filt(y, r_hp(120, 2), r_lp(5000, 2), circular=True)


# =============================================================================
# ONE-SHOTS
# =============================================================================
def step_earth(r, var):
    dur = (0.12, 0.14, 0.11)[var]
    n = ns(dur)
    y = 0.75 * nrm(thump(n, r.uniform(105, 140), r.uniform(50, 65), r.uniform(0.022, 0.035)))
    body = filt(white(r, n), r_lp(r.uniform(450, 750), 2), r_hp(70, 2)) * env_ad(n, 0.0015, r.uniform(0.012, 0.02))
    y += 0.55 * nrm(body)
    k = int(r.integers(8, 15))
    times = np.sort(r.exponential(0.012, k)) + 0.001
    env = crackle_env(n, times, loguni(r, 0.2, 1.0, k) * np.exp(-times / 0.03), loguni(r, 0.0015, 0.005, k))
    grit = filt(white(r, n), r_hp(1200, 2), r_lp(r.uniform(4000, 6000), 2)) * env
    y += 0.4 * nrm(grit)
    for tc in (r.uniform(0.0, 0.006), r.uniform(0.018, 0.035)):
        place(y, 0.22 * nrm(click(r, 2500, 7000, 0.0012, 2, 0.5)), tc)
    return filt(y, r_lp(7000, 2))


def step_grass(r, var):
    dur = 0.22
    n = ns(dur)
    k1, k2 = (45, 30) if var == 0 else (35, 40)
    c1 = np.sort(r.uniform(0.0, 0.08, k1))
    c2 = np.sort(r.uniform(0.09, 0.2, k2))
    times = np.concatenate([c1, c2])
    amps = np.concatenate([loguni(r, 0.2, 1.0, k1) * (1 - 0.5 * c1 / 0.08),
                           0.55 * loguni(r, 0.2, 1.0, k2) * (1 - 0.7 * (c2 - 0.09) / 0.11)])
    env = crackle_env(n, times, amps, loguni(r, 0.0008, 0.004, k1 + k2))
    crack = filt(white(r, n), r_hp(1800, 2), r_lp(7500, 2), r_peak(4000, 1.0, 4)) * env
    swish = filt(white(r, n), r_bp(3000, 0.7)) * curve(n, [(0, 0), (0.02, 1), (0.08, 0.6), (0.13, 0.45), (0.22, 0)], 0.01)
    y = 0.8 * nrm(crack) + 0.35 * nrm(swish) + 0.15 * nrm(thump(n, 90, 60, 0.02))
    return y


def splash(r, big: bool):
    dur = 1.0 if big else 0.4
    n = ns(dur)
    t = tax(n)
    if big:
        fc = 350 + 5200 * np.exp(-t / 0.18)
        wenv = curve(n, [(0, 0), (0.008, 1), (0.12, 0.7), (0.45, 0.2), (dur, 0)], 0.01)
    else:
        fc = 500 + 5500 * np.exp(-t / 0.07)
        wenv = env_ad(n, 0.003, 0.06)
    y = 0.8 * nrm(svf(white(r, n), fc, 0.6, "lp") * wenv)
    spray = filt(white(r, n), r_hp(2500, 2), r_lp(8000, 2)) * env_ad(n, 0.002, 0.15 if big else 0.05)
    y += 0.3 * nrm(spray)
    if big:
        y += 0.7 * nrm(thump(n, 85, 38, 0.14))
        y += 0.4 * nrm(filt(white(r, n), r_lp(200, 2)) * env_ad(n, 0.004, 0.2))
    bub = np.zeros(n)
    for _ in range(140 if big else 35):
        tb = 0.01 + r.exponential(0.22 if big else 0.07)
        if tb > dur * 0.85:
            continue
        f0 = loguni(r, 180, 1400) if big else loguni(r, 350, 1800)
        place(bub, bubble(r, f0, loguni(r, 0.15, 1.0) * np.exp(-tb / (0.4 if big else 0.15))), tb)
    y += 0.55 * nrm(bub)
    drops = np.zeros(n)
    for _ in range(18 if big else 5):
        tb = r.uniform(0.12, dur * 0.8)
        place(drops, bubble(r, loguni(r, 1500, 3200), loguni(r, 0.3, 1.0), rise=0.4), tb)
    y += 0.3 * nrm(drops)
    return y


def swim(r, var):
    dur = 0.42
    n = ns(dur)
    pk = r.uniform(0.11, 0.15)
    fc = curve(n, [(0, 350), (pk, r.uniform(900, 1300)), (dur, 450)], 0.02)
    shape = curve(n, [(0, 0), (pk, 1), (dur, 0)], 0.04) ** 1.5
    stroke = svf(white(r, n), fc, 1.1, "bp") * shape
    push = filt(white(r, n), r_lp(450, 2), r_hp(60, 2)) * shape
    bub = np.zeros(n)
    for _ in range(int(r.integers(6, 11))):
        place(bub, bubble(r, loguni(r, 400, 1200), loguni(r, 0.2, 0.6)), r.uniform(pk, 0.34))
    spray = filt(white(r, n), r_hp(2500, 2)) * env_ad(n, 0.01, 0.03, start=pk - 0.02)
    return 0.7 * nrm(stroke) + 0.45 * nrm(push) + 0.35 * nrm(bub) + 0.12 * nrm(spray)


def jaw_snap(r, damp=1.0):
    b = r.uniform(0.95, 1.05)
    s = modal(0.06, [(2100 * b, 0.006 * damp, 1.0), (3300 * b, 0.004 * damp, 0.7),
                     (4700 * b, 0.003 * damp, 0.5), (1250 * b, 0.009 * damp, 0.6)])
    m = len(s)
    tr = filt(white(r, m), r_hp(2000, 2)) * env_ad(m, 0.0002, 0.0015)
    return nrm(s) + 0.8 * nrm(tr)


def bite_snap(r):
    dur = 0.24
    n = ns(dur)
    y = 0.12 * nrm(filt(white(r, n), r_bp(1400, 0.8)) * curve(n, [(0, 0), (0.034, 1), (0.037, 0), (dur, 0)]) ** 2)
    place(y, jaw_snap(r), 0.035)
    place(y, 0.6 * nrm(modal(0.12, [(520, 0.03, 1.0), (830, 0.02, 0.6), (1400, 0.012, 0.4)])), 0.038)
    place(y, 0.3 * thump(ns(0.1), 180, 120, 0.02), 0.036)
    return y


def bite_hit(r):
    dur = 0.4
    n = ns(dur)
    y = np.zeros(n)
    place(y, 0.75 * jaw_snap(r, damp=0.7), 0.02)
    place(y, 0.9 * nrm(thump(ns(0.3), 110, 55, 0.07)), 0.022)
    m = ns(0.3)
    place(y, 0.5 * nrm(filt(white(r, m), r_lp(350, 2)) * env_ad(m, 0.002, 0.06)), 0.022)
    m = ns(0.12)
    sq = svf(white(r, m), curve(m, [(0, 500), (0.08, 1500), (0.12, 1200)]), 2.0, "bp") * env_ad(m, 0.004, 0.04)
    place(y, 0.35 * nrm(sq), 0.03)
    m = ns(0.25)
    k = 25
    times = np.sort(r.uniform(0, 0.2, k))
    env = crackle_env(m, times, loguni(r, 0.3, 1.0, k) * np.exp(-times / 0.1), loguni(r, 0.002, 0.006, k))
    tear = filt(white(r, m), r_hp(900, 2), r_lp(4500, 2)) * env
    rip = filt(white(r, m), r_bp(1500, 1.2)) * env_ad(m, 0.01, 0.06) * (0.6 + 0.4 * pulse_am(r, m, 60, 1.0, 0.4))
    place(y, 0.4 * nrm(tear) + 0.25 * nrm(rip), 0.07)
    return y


def crunch(r, var):
    dur = 0.36
    n = ns(dur)
    events = [(0.0, 1.0), (0.13, 0.8), (0.25, 0.6)] if var == 0 else [(0.0, 0.9), (0.09, 1.0), (0.21, 0.55), (0.3, 0.35)]
    cr = np.zeros(n)
    body = np.zeros(n)
    for te, a in events:
        te += r.uniform(0.002, 0.012)
        for _ in range(int(r.integers(6, 14))):
            place(cr, a * loguni(r, 0.3, 1.0) * click(r, 1200, 6000, loguni(r, 0.0015, 0.005), 3, 0.6),
                  te + r.exponential(0.012))
        place(body, a * thump(ns(0.08), 260, 170, 0.018), te)
        m = ns(0.1)
        place(body, a * 0.4 * nrm(filt(white(r, m), r_lp(900, 2)) * env_ad(m, 0.002, 0.03)), te)
    wet = filt(white(r, n), r_bp(1200, 1.0)) * curve(n, [(0, 0), (0.03, 1), (0.3, 0.5), (dur, 0)])
    return 0.8 * nrm(cr) + 0.5 * nrm(body) + 0.08 * nrm(wet)


def gulp(r):
    dur = 0.3
    n = ns(dur)
    y = np.zeros(n)

    def gloop(fa, fb, sweep_t, tau, amp, t0):
        m = ns(0.2)
        tt_ = tax(m)
        f = fa + (fb - fa) * np.clip(tt_ / sweep_t, 0, 1) ** 0.7
        ph = TAU * np.cumsum(f) / SR
        env = (1 - np.exp(-tt_ / 0.006)) * np.exp(-tt_ / tau)
        place(y, amp * env * (np.sin(ph) + 0.35 * np.sin(2 * ph + 0.5) + 0.12 * np.sin(3 * ph)), t0)

    gloop(105, 230, 0.1, 0.06, 1.0, 0.03)
    gloop(170, 310, 0.06, 0.035, 0.55, 0.15)
    m = ns(0.03)
    place(y, 0.25 * nrm(filt(white(r, m), r_bp(1600, 1.5)) * env_ad(m, 0.0005, 0.004)), 0.025)
    throat = filt(white(r, n), r_lp(350, 2)) * curve(n, [(0, 0), (0.04, 1), (0.18, 0.5), (0.26, 0)], 0.01)
    y = nrm(y) + 0.2 * nrm(throat)
    return filt(y, r_lp(1500, 2))


def drink(r):
    dur = 0.85
    n = ns(dur)
    y = np.zeros(n)
    for tl in [0.05, 0.25, 0.46, 0.66]:
        tl += r.uniform(-0.02, 0.02)
        place(y, bubble(r, r.uniform(700, 1000), 0.7, tau=0.015, rise=0.8), tl)
        m = ns(0.06)
        place(y, 0.4 * nrm(filt(white(r, m), r_bp(2000, 0.8)) * env_ad(m, 0.001, 0.015)), tl)
        for _ in range(int(r.integers(1, 3))):
            place(y, bubble(r, r.uniform(1800, 2600), 0.25, tau=0.006), tl + r.uniform(0.03, 0.06))
        place(y, bubble(r, r.uniform(300, 400), 0.3, tau=0.02, rise=0.3), tl + 0.02)
    return y


def hiss(r, big: bool):
    dur = 1.3 if big else 0.9
    n = ns(dur)
    t = tax(n)
    if big:
        base = filt(white(r, n), r_hp(350, 2), r_lp(6500, 2), r_peak(1300, 1.5, 6), r_peak(2800, 2, 5), r_peak(5200, 2.5, 3))
        fc = 1400 + 700 * np.sin(np.pi * t / dur)
    else:
        base = filt(white(r, n), r_hp(900, 2), r_lp(8500, 2), r_peak(2600, 1.6, 6), r_peak(4800, 2, 5), r_peak(7000, 2, 2))
        fc = 2200 + 1200 * np.sin(np.pi * t / dur)
    mov = svf(white(r, n), fc, 2.5, "bp")
    ta = 0.3 * dur
    env = np.where(t < ta, (t / ta) ** 1.5, np.clip((dur - t) / (dur - ta), 0, 1) ** 1.3)
    env = smooth(env, 0.02) * (1 + 0.12 * smooth_noise(r, n, 30))
    y = (0.7 * nrm(base) + 0.45 * nrm(mov)) * env
    if big:
        rumble = filt(white(r, n), r_lp(300, 2), r_hp(50, 2)) * pulse_am(r, n, 22, 1.5, 0.2)
        y += 0.35 * nrm(rumble * env)
    return y


def tongue(r):
    n = ns(0.1)
    y = np.zeros(n)
    for tf, a in [(0.005, 1.0), (0.045, 0.7)]:
        m = ns(0.04)
        place(y, a * nrm(filt(white(r, m), r_bp(4000, 1.5)) * env_ad(m, 0.001, 0.006)), tf)
        place(y, 0.4 * a * bubble(r, 2500, 1.0, tau=0.003, rise=0.3), tf + 0.004)
    return y


def hurt(r):
    dur = 0.38
    n = ns(dur)
    y = np.zeros(n)
    imp = 0.8 * nrm(thump(n, 130, 60, 0.05)) + 0.5 * nrm(filt(white(r, n), r_lp(1500, 2)) * env_ad(n, 0.0005, 0.015))
    m = ns(0.3)
    f0 = curve(m, [(0, 200), (0.2, 130), (0.3, 120)]) * (1 + 0.03 * smooth_noise(r, m, 20))
    g = voice(f0, [(500, 300, 1.0), (1200, 400, 0.6), (2500, 600, 0.3)], tilt=1.2, fmax=4000, r=r)
    g *= env_ad(m, 0.008, 0.08) * (0.5 + 0.5 * pulse_am(r, m, 45, 1.0, 0.2))
    br = filt(white(r, m), r_bp(2000, 0.8)) * env_ad(m, 0.005, 0.1)
    y += imp
    place(y, 0.7 * nrm(g) + 0.5 * nrm(br), 0.015)
    return y


def tail_whip(r):
    dur = 0.42
    n = ns(dur)
    fc = curve(n, [(0, 300), (0.2, 1800), (0.27, 2600), (0.33, 900), (dur, 500)], 0.01)
    amp = curve(n, [(0, 0), (0.18, 0.6), (0.26, 1.0), (0.29, 0.3), (dur, 0)], 0.015)
    y = 0.7 * nrm(svf(white(r, n), fc, 1.0, "bp") * amp)
    m = ns(0.15)
    slap = filt(white(r, m), r_hp(400, 2), r_lp(6000, 2)) * env_ad(m, 0.0005, 0.012)
    place(y, nrm(slap), 0.27)
    place(y, 0.6 * nrm(thump(m, 160, 90, 0.03)), 0.27)
    place(y, 0.4 * nrm(modal(0.1, [(350, 0.02, 1.0), (700, 0.012, 0.5)])), 0.271)
    return y


# ---- dingo ------------------------------------------------------------------
def dingo_growl(r):
    dur = 1.25
    n = ns(dur)
    f0 = curve(n, [(0, 95), (0.3, 112), (0.7, 118), (1.0, 104), (dur, 92)], 0.05) * (1 + 0.04 * smooth_noise(r, n, 6))
    F1 = 480 + 60 * smooth_noise(r, n, 2)
    v = voice(f0, [(F1, 250, 1.0), (1150, 350, 0.6), (2400, 600, 0.3)], tilt=0.8, fmax=4000, r=r)
    sub = voice(f0 * 0.5, [(F1 * 0.7, 300, 1.0), (900, 400, 0.4)], tilt=1.2, fmax=1500, r=r)
    am = 0.35 + 0.65 * pulse_am(r, n, 26 + 5 * smooth_noise(r, n, 3), 1.3, 0.2)
    nz = filt(white(r, n), r_bp(500, 1.5), r_peak(1150, 2, 4), r_lp(3000, 2))
    env = curve(n, [(0, 0), (0.07, 0.75), (0.35, 1), (0.6, 0.8), (0.85, 0.95), (1.1, 0.5), (dur, 0)], 0.03)
    y = (0.8 * nrm(v) + 0.3 * nrm(sub) + 0.35 * nrm(nz)) * am * env
    return filt(y, r_lp(3500, 2))


def dingo_bark(r):
    dur = 0.32
    n = ns(dur)
    f0 = curve(n, [(0, 420), (0.03, 480), (0.2, 300), (dur, 280)], 0.01) * (1 + 0.02 * smooth_noise(r, n, 30))
    v = voice(f0, [(800, 300, 1.0), (1600, 400, 0.7), (2800, 600, 0.35)], tilt=1.0, fmax=5000, r=r)
    v *= 0.75 + 0.25 * pulse_am(r, n, 70, 1.0, 0.2)
    env = curve(n, [(0, 0), (0.006, 1), (0.06, 0.8), (0.16, 0.35), (0.3, 0), (dur, 0)], 0.004)
    burst = filt(white(r, n), r_bp(1200, 0.9)) * env_ad(n, 0.002, 0.03)
    return nrm(v * env) + 0.5 * nrm(burst) + 0.3 * nrm(thump(n, 150, 100, 0.04))


def dingo_howl(r):
    dur = 2.6
    n = ns(dur)
    t = tax(n)
    f0 = curve(n, [(0, 330), (0.25, 470), (0.6, 560), (1.4, 580), (1.9, 520), (2.2, 420), (dur, 380)], 0.08)
    vib = 1 + 0.008 * np.clip(t / 1.0, 0, 1) * np.sin(TAU * 5.5 * t) + 0.006 * smooth_noise(r, n, 4)
    f0 = f0 * vib
    F1 = curve(n, [(0, 500), (0.6, 800), (1.6, 780), (2.3, 500)], 0.1)
    F2 = curve(n, [(0, 1100), (0.6, 1300), (2.3, 1050)], 0.1)
    v = voice(f0, [(F1, 300, 1.0), (F2, 400, 0.4), (2600, 700, 0.1)], tilt=1.6, fmax=4500, r=r)
    env = curve(n, [(0, 0), (0.25, 0.8), (0.6, 1), (1.8, 0.9), (2.1, 0.5), (2.3, 0), (dur, 0)], 0.06)
    br = filt(white(r, n), r_bp(1000, 1.0)) * env
    y = nrm(v * env) + 0.06 * nrm(br)
    y = filt(y, r_lp(4000, 2))
    return reverb(y, r, 1.2, 0.3, dark=1200)


def dingo_yelp(r):
    dur = 0.3
    n = ns(dur)
    f0 = curve(n, [(0, 700), (0.03, 1150), (0.09, 1050), (0.2, 650), (dur, 550)], 0.006)
    v = voice(f0, [(1100, 500, 1.0), (2200, 600, 0.5)], tilt=1.3, fmax=6000, r=r)
    env = curve(n, [(0, 0), (0.01, 1), (0.08, 0.85), (0.2, 0.3), (0.28, 0), (dur, 0)], 0.004)
    nz = filt(white(r, n), r_bp(1500, 1.0)) * env
    return nrm(v * env) + 0.08 * nrm(nz)


# ---- small critters ---------------------------------------------------------
def mouse_squeak(r):
    dur = 0.15
    n = ns(dur)
    y = np.zeros(n)
    for t0, d, fa, fb, fc, a in [(0.0, 0.06, 3300, 4300, 3700, 1.0), (0.075, 0.07, 3500, 4500, 3100, 0.8)]:
        m = ns(d)
        tt_ = tax(m)
        f = curve(m, [(0, fa), (d * 0.35, fb), (d, fc)]) * (1 + 0.015 * np.sin(TAU * 40 * tt_))
        ph = TAU * np.cumsum(f) / SR
        env = np.sin(np.pi * np.linspace(0, 1, m)) ** 0.8
        place(y, a * env * (np.sin(ph) + 0.15 * np.sin(2 * ph)), t0)
    return y


def skink_rustle(r):
    dur = 0.2
    n = ns(dur)
    y = np.zeros(n)
    t = 0.005
    while t < 0.17:
        place(y, loguni(r, 0.4, 1.0) * click(r, 2500, 6000, loguni(r, 0.001, 0.002), 2, 0.6), t)
        t += 1.0 / 45.0 * r.uniform(0.7, 1.3)
    k = 30
    times = np.sort(r.uniform(0, 0.18, k))
    env = crackle_env(n, times, loguni(r, 0.2, 1.0, k), loguni(r, 0.0008, 0.003, k))
    lv = filt(white(r, n), r_hp(2500, 2), r_lp(8000, 2)) * env
    return (0.7 * nrm(y) + 0.45 * nrm(lv)) * curve(n, [(0, 1), (0.14, 1), (dur, 0.2)])


def insect_hop(r):
    dur = 0.15
    n = ns(dur)
    y = np.zeros(n)
    place(y, click(r, 3000, 7000, 0.0015, 3, 0.5), 0.005)
    m = ns(0.08)
    tt_ = tax(m)
    bz = voice(np.full(m, 140.0) * (1 + 0.05 * np.sin(TAU * 25 * tt_)), [(3500, 1500, 1.0)], tilt=0.3, fmax=7000, r=r)
    cr = pulse_am(r, m, 45, 3.0, 0.2)
    place(y, 0.5 * nrm(bz * (0.5 + 0.5 * cr) * env_ad(m, 0.004, 0.025)), 0.01)
    place(y, 0.45 * click(r, 2500, 6000, 0.0012, 2, 0.4), 0.11)
    return y


# ---- birds ------------------------------------------------------------------
def turkey_call(r):
    dur = 0.65
    n = ns(dur)
    y = np.zeros(n)
    for t0, d, a in [(0.02, 0.09, 1.0), (0.17, 0.08, 0.85), (0.31, 0.1, 0.95), (0.48, 0.08, 0.7)]:
        m = ns(d + 0.03)
        f0 = curve(m, [(0, 160 * r.uniform(0.95, 1.05)), (d, 112)]) * (1 + 0.03 * smooth_noise(r, m, 20))
        v = voice(f0, [(380, 200, 1.0), (850, 300, 0.5), (1900, 500, 0.15)], tilt=1.0, fmax=3000, r=r)
        am = 0.5 + 0.5 * pulse_am(r, m, 38, 1.5, 0.15)
        env = curve(m, [(0, 0), (0.008, 1), (d * 0.6, 0.7), (d, 0), (d + 0.03, 0)], 0.004)
        place(y, a * nrm(v * am * env), t0)
        mc = ns(0.02)
        place(y, 0.25 * a * nrm(filt(white(r, mc), r_bp(900, 1.2)) * env_ad(mc, 0.0005, 0.003)), t0)
    return filt(y, r_lp(3000, 2))


def caw_syll(r, d, fa, fb, gargle=0.0):
    m = ns(d + 0.02)
    f0 = curve(m, [(0, fa * 0.92), (0.03, fa), (d, fb), (d + 0.02, fb)], 0.01) * (1 + 0.015 * smooth_noise(r, m, 15))
    F1 = curve(m, [(0, 700), (0.04, 1050), (d, 950)], 0.01)
    v = voice(f0, [(F1, 350, 1.0), (1650, 400, 0.8), (2700, 600, 0.45)], tilt=0.6, fmax=6000, r=r, floor=0.05)
    rate = curve(m, [(0, 70), (d, 70 - 40 * gargle)])
    depth = curve(m, [(0, 0.45), (d, 0.45 + 0.4 * gargle)])
    am = 1 - depth + depth * pulse_am(r, m, rate, 1.2, 0.3)
    nz = filt(white(r, m), r_bp(1100, 1.2), r_peak(1700, 2, 4), r_peak(2700, 2, 3))
    env = curve(m, [(0, 0), (0.025, 1), (d * 0.55, 0.9), (d, 0), (d + 0.02, 0)], 0.01)
    if gargle > 0:
        env = curve(m, [(0, 0), (0.025, 1), (d * 0.3, 0.85), (d * 0.8, 0.45), (d, 0), (d + 0.02, 0)], 0.02)
    return (nrm(v) * 0.75 + nrm(nz) * 0.3) * am * env


def crow_caw(r, short=False):
    sylls = [(0.0, 0.22, 540, 470, 0.9, 0.0), (0.28, 0.36, 510, 390, 1.0, 0.7)] if short else \
            [(0.0, 0.26, 560, 470, 0.9, 0.0), (0.33, 0.22, 520, 440, 0.85, 0.0), (0.61, 0.56, 500, 360, 1.0, 1.0)]
    dur = 0.72 if short else 1.25
    y = np.zeros(ns(dur))
    for t0, d, fa, fb, a, g in sylls:
        place(y, a * nrm(caw_syll(r, d, fa, fb, g)), t0)
    return reverb(filt(y, r_lp(6000, 2)), r, 0.8, 0.15)


def eagle_screech(r):
    dur = 1.05
    n = ns(dur)
    t = tax(n)
    f0 = curve(n, [(0, 1500), (0.06, 2300), (0.25, 2150), (0.7, 1600), (0.9, 1350), (dur, 1300)], 0.02)
    f0 = f0 * (1 + 0.01 * np.sin(TAU * 30 * t) + 0.01 * smooth_noise(r, n, 10))
    v = voice(f0, [(3000, 2500, 1.0)], tilt=1.5, fmax=8000, r=r, floor=0.2)
    rasp = 0.55 + 0.45 * pulse_am(r, n, 55, 1.2, 0.3)
    nz = svf(white(r, n), 2 * f0, 3.0, "bp")
    env = curve(n, [(0, 0), (0.04, 1), (0.3, 0.9), (0.75, 0.6), (0.95, 0), (dur, 0)], 0.02)
    y = (nrm(v) + 0.3 * nrm(nz)) * rasp * env
    y = filt(y, r_lp(5000, 2), r_hp(600, 2))
    return reverb(y, r, 1.5, 0.35, dark=1500)


def wings(r):
    dur = 0.62
    n = ns(dur)
    y = np.zeros(n)
    for tf, a in [(0.0, 1.0), (0.14, 0.9), (0.28, 0.8), (0.43, 0.6)]:
        tf += r.uniform(0, 0.015)
        m = ns(0.18)
        tt_ = tax(m)
        env = np.where(tt_ < 0.035, (tt_ / 0.035) ** 2, np.exp(-(tt_ - 0.035) / 0.05))
        wh = filt(white(r, m), r_hp(250, 2), r_lp(1800, 2)) * (1 + 0.3 * np.sin(TAU * 75 * tt_))
        fe = filt(white(r, m), r_hp(3000, 2)) * crackle_env(m, np.sort(r.uniform(0.01, 0.08, 12)),
                                                            loguni(r, 0.3, 1, 12), loguni(r, 0.001, 0.003, 12))
        th = thump(m, 90, 60, 0.03, attack=0.02)
        place(y, a * (0.9 * nrm(wh * env) + 0.15 * nrm(fe) + 0.2 * nrm(th)), tf)
    return y


def frog_croak(r):
    y = np.zeros(ns(0.42))
    place(y, frog_croak_sig(r, 0.34, 620), 0.01)
    return y


def frog_plop(r):
    dur = 0.26
    n = ns(dur)
    y = np.zeros(n)
    place(y, bubble(r, 450, 1.0, tau=0.035, rise=0.35), 0.01)
    place(y, bubble(r, 700, 0.4, tau=0.015, rise=0.3), 0.04)
    m = ns(0.06)
    place(y, 0.5 * nrm(filt(white(r, m), r_bp(1800, 0.7)) * env_ad(m, 0.0008, 0.012)), 0.008)
    for _ in range(2):
        place(y, bubble(r, r.uniform(1600, 2400), 0.3, tau=0.006, rise=0.4), r.uniform(0.08, 0.18))
    return y


def hop(r):
    dur = 0.2
    n = ns(dur)
    y = nrm(thump(n, 85, 45, 0.06)) + 0.6 * nrm(filt(white(r, n), r_lp(250, 2)) * env_ad(n, 0.003, 0.04))
    k = 8
    times = np.sort(r.uniform(0.0, 0.05, k))
    grit = filt(white(r, n), r_hp(1500, 2), r_lp(5000, 2)) * crackle_env(n, times, loguni(r, 0.2, 1, k), loguni(r, 0.001, 0.004, k))
    return y + 0.2 * nrm(grit)


# ---- crocodile --------------------------------------------------------------
def croc_growl(r):
    dur = 1.55
    n = ns(dur)
    f0 = curve(n, [(0, 38), (0.5, 46), (1.1, 43), (dur, 36)], 0.1) * (1 + 0.06 * smooth_noise(r, n, 3))
    v = voice(f0, [(180, 120, 1.0), (420, 200, 0.7), (900, 400, 0.3)], tilt=0.5, fmax=3000, r=r, floor=0.03)
    am = 1 - 0.7 + 0.7 * pulse_am(r, n, 14, 1.2, 0.3)
    subb = np.sin(TAU * np.cumsum(f0) / SR)
    env = curve(n, [(0, 0), (0.15, 0.7), (0.5, 1), (1.0, 0.85), (1.35, 0.4), (dur, 0)], 0.04)
    hs = filt(white(r, n), r_hp(700, 2), r_lp(4000, 2), r_peak(1500, 1.5, 5)) * curve(n, [(0, 0), (0.7, 0.1), (1.1, 1), (dur, 0)], 0.05)
    rum = filt(white(r, n), r_lp(200, 2), r_hp(30, 2)) * am * env
    return (nrm(v) * am + 0.35 * subb) * env + 0.45 * nrm(hs) + 0.4 * nrm(rum)


def croc_lunge(r):
    dur = 0.85
    n = ns(dur)
    t = tax(n)
    fc = curve(n, [(0, 800), (0.12, 4500), (0.4, 1200), (dur, 600)], 0.02)
    wenv = curve(n, [(0, 0), (0.1, 1), (0.25, 0.6), (0.55, 0.15), (dur, 0)], 0.02)
    y = 0.8 * nrm(svf(white(r, n), fc, 0.6, "lp") * wenv)
    boom = np.zeros(n)
    place(boom, thump(ns(0.6), 70, 35, 0.2), 0.05)
    y += 0.8 * nrm(boom)
    bub = np.zeros(n)
    for _ in range(120):
        tb = 0.05 + r.exponential(0.18)
        if tb < dur * 0.85:
            place(bub, bubble(r, loguni(r, 200, 1500), loguni(r, 0.2, 1.0) * np.exp(-tb / 0.35)), tb)
    y += 0.45 * nrm(bub)
    drops = np.zeros(n)
    for _ in range(20):
        place(drops, bubble(r, loguni(r, 1500, 3200), loguni(r, 0.3, 1.0), rise=0.4), r.uniform(0.2, 0.78))
    y += 0.25 * nrm(drops)
    clap = modal(0.3, [(260, 0.05, 1.0), (470, 0.035, 0.7), (820, 0.02, 0.5), (1500, 0.01, 0.4), (3100, 0.004, 0.5)])
    m = len(clap)
    crack = filt(white(r, m), r_hp(1000, 2)) * env_ad(m, 0.0002, 0.005)
    place(y, 1.0 * nrm(nrm(clap) + 0.8 * nrm(crack)), 0.3)
    return y


# ---- eggs -------------------------------------------------------------------
def crack_event(r, amp=1.0, n_clicks=None, spread=0.02):
    m = ns(spread + 0.03)
    y = np.zeros(m)
    for _ in range(n_clicks or int(r.integers(3, 9))):
        place(y, loguni(r, 0.3, 1.0) * click(r, 2000, 7500, loguni(r, 0.0008, 0.003), 3, 0.5), r.uniform(0, spread))
    y += 0.25 * nrm(modal(len(y) / SR, [(r.uniform(1100, 1800), 0.008, 1.0)]))
    return amp * y


def egg_crack(r):
    dur = 0.62
    y = np.zeros(ns(dur))
    for tc in np.sort(r.uniform(0.02, 0.5, 7)):
        place(y, crack_event(r, loguni(r, 0.4, 1.0), spread=r.uniform(0.008, 0.025)), tc)
    return y


def hatch(r):
    dur = 2.05
    n = ns(dur)
    y = np.zeros(n)
    for tc in np.sort(1.55 * np.sqrt(r.uniform(0, 1, 18))):
        place(y, crack_event(r, 0.3 + 0.5 * tc / 1.55, spread=r.uniform(0.005, 0.02)), tc)
    for _ in range(5):
        m = ns(0.05)
        k = 12
        env = crackle_env(m, np.sort(r.uniform(0, 0.04, k)), loguni(r, 0.3, 1, k), loguni(r, 0.0006, 0.002, k))
        place(y, 0.25 * nrm(filt(white(r, m), r_bp(3000, 1.0)) * env), r.uniform(0.2, 1.5))
    place(y, crack_event(r, 1.4, n_clicks=25, spread=0.06), 1.62)
    place(y, 0.6 * nrm(modal(0.1, [(900, 0.02, 1.0), (1400, 0.015, 0.7), (2300, 0.01, 0.5)])), 1.625)
    place(y, 0.3 * nrm(thump(ns(0.1), 200, 120, 0.03)), 1.66)
    for tb, a in [(1.72, 0.5), (1.80, 0.35), (1.86, 0.25), (1.90, 0.15), (1.93, 0.1)]:
        place(y, a * click(r, 3000, 6000, 0.0015, 2, 0.3), tb)
    return y


# ---- misc ---------------------------------------------------------------------
def heartbeat(r):
    dur = 0.8
    n = ns(dur)
    y = np.zeros(n)
    for t0, fa, fb, d, a in [(0.02, 60, 42, 0.07, 1.0), (0.3, 70, 48, 0.05, 0.75)]:
        m = ns(0.35)
        s = nrm(thump(m, fa, fb, d, attack=0.008)) + 0.3 * nrm(filt(white(r, m), r_lp(150, 2)) * env_ad(m, 0.006, d * 0.7))
        place(y, a * s, t0)
    return filt(y, r_lp(400, 2))


def stage_up(r):
    dur = 2.6
    n = ns(dur)
    t = tax(n)
    notes = [146.83, 220.00, 293.66, 369.99, 440.00]          # D major (add 9 on top)
    pad = np.zeros(n)
    for fq in notes:
        for det in (-0.0035, 0.0, 0.003):
            ff = fq * (1 + det)
            p0 = r.uniform(0, TAU)
            for h, a in enumerate([1.0, 0.35, 0.12, 0.05], 1):
                pad += a * np.sin(TAU * ff * h * t + p0 * h)
    penv = curve(n, [(0, 0), (0.9, 1), (1.5, 0.85), (2.4, 0), (dur, 0)], 0.1) ** 1.5
    pad = filt(pad * penv, r_lp(2500, 2))
    mal = np.zeros(n)
    for tn, fq, a in [(0.05, 293.66, 0.8), (0.1, 440.0, 0.7), (0.155, 659.25, 0.6), (0.85, 1318.5, 0.3)]:
        mt = modal(2.0, [(fq, 0.9, 1.0), (fq * 3.93, 0.25, 0.3), (fq * 9.2, 0.08, 0.08)], attack=0.002)
        place(mal, a * mt, tn)
    bell = modal(1.6, [(1760 * f, d, a) for f, d, a in [(1, 1.0, 1.0), (2.76, 0.5, 0.4), (5.4, 0.25, 0.2), (8.93, 0.12, 0.1)]], attack=0.003)
    place(mal, 0.12 * nrm(bell), 0.9)
    air = svf(white(r, n), curve(n, [(0, 400), (0.9, 2000), (dur, 2000)]), 1.2, "bp") * curve(n, [(0, 0), (0.7, 1), (1.3, 0), (dur, 0)], 0.1)
    y = 0.55 * nrm(pad) + 0.6 * nrm(mal) + 0.06 * nrm(air)
    y = reverb(y, r, 1.8, 0.35, dark=2000, bright=6000)
    return y * curve(n, [(0, 1), (2.2, 1), (dur, 0)])


def death(r):
    dur = 3.1
    n = ns(dur)
    f0 = curve(n, [(0, 110), (0.4, 108), (2.5, 82), (dur, 80)], 0.1) * (1 + 0.004 * smooth_noise(r, n, 3))
    F1 = curve(n, [(0, 650), (2.5, 300)], 0.1)
    fr = [(F1, 250, 1.0), (F1 * 2.1, 400, 0.4)]
    y = nrm(voice(f0, fr, tilt=1.3, fmax=3000, r=r)) + 0.45 * nrm(voice(f0 * 1.189, fr, tilt=1.4, fmax=3000, r=r)) \
        + 0.35 * nrm(voice(f0 * 1.5, fr, tilt=1.5, fmax=3000, r=r)) + 0.3 * nrm(voice(f0 * 0.5, fr, tilt=1.2, fmax=1500, r=r))
    env = curve(n, [(0, 0), (0.15, 1), (1.5, 0.8), (2.7, 0.15), (dur, 0)], 0.1)
    y = nrm(y * env)
    y += 0.6 * nrm(thump(n, 55, 35, 0.8, attack=0.01)) + 0.3 * nrm(filt(white(r, n), r_lp(120, 2)) * env_ad(n, 0.01, 0.5))
    y = reverb(y, r, 2.5, 0.4, dark=900, bright=3000)
    return y * curve(n, [(0, 1), (2.6, 1), (dur, 0)], 0.05)


def ui_click(r):
    y = modal(0.06, [(1150, 0.012, 1.0), (2480, 0.006, 0.45), (3900, 0.004, 0.25)], attack=0.0003)
    m = len(y)
    return nrm(y) + 0.3 * nrm(filt(white(r, m), r_lp(5000, 2)) * env_ad(m, 0.0002, 0.0008))


def ui_hover(r):
    return modal(0.045, [(1900, 0.006, 1.0), (3500, 0.003, 0.3)], attack=0.0005)


def ui_confirm(r):
    dur = 0.32
    n = ns(dur)
    y = np.zeros(n)
    for t0, f, a in [(0.0, 392.0, 0.85), (0.085, 523.25, 1.0)]:
        tone = modal(0.3, [(f, 0.22, 1.0), (f * 2, 0.12, 0.25), (f * 3, 0.06, 0.08), (f * 4.1, 0.03, 0.04), (f * 0.5, 0.15, 0.2)], attack=0.003)
        place(y, a * tone, t0)
    return y


# =============================================================================
# Registry, finalisation, output
# =============================================================================
LOOP_BED, LOOP_MUSIC = -9.0, -6.0
SOUNDS = [
    # name, fn, kind, peak dBFS
    ("amb_day", amb_day, "loop", LOOP_BED),
    ("amb_night", amb_night, "loop", LOOP_BED),
    ("wind", wind, "loop", -8.0),
    ("river", river, "loop", -8.0),
    ("music_menu", music_menu, "loop", LOOP_MUSIC),
    ("carcass_flies", carcass_flies, "loop", LOOP_MUSIC),
    ("step_1", lambda r: step_earth(r, 0), "oneshot", -3.0),
    ("step_2", lambda r: step_earth(r, 1), "oneshot", -3.0),
    ("step_3", lambda r: step_earth(r, 2), "oneshot", -3.0),
    ("step_grass_1", lambda r: step_grass(r, 0), "oneshot", -3.0),
    ("step_grass_2", lambda r: step_grass(r, 1), "oneshot", -3.0),
    ("splash_small", lambda r: splash(r, False), "oneshot", -3.0),
    ("splash_big", lambda r: splash(r, True), "oneshot", -3.0),
    ("swim_1", lambda r: swim(r, 0), "oneshot", -3.0),
    ("swim_2", lambda r: swim(r, 1), "oneshot", -3.0),
    ("bite_snap", bite_snap, "oneshot", -3.0),
    ("bite_hit", bite_hit, "oneshot", -3.0),
    ("crunch_1", lambda r: crunch(r, 0), "oneshot", -3.0),
    ("crunch_2", lambda r: crunch(r, 1), "oneshot", -3.0),
    ("gulp", gulp, "oneshot", -3.0),
    ("drink", drink, "oneshot", -3.0),
    ("hiss", lambda r: hiss(r, False), "oneshot", -3.0),
    ("hiss_big", lambda r: hiss(r, True), "oneshot", -3.0),
    ("tongue", tongue, "oneshot", -14.0),
    ("hurt", hurt, "oneshot", -3.0),
    ("tail_whip", tail_whip, "oneshot", -3.0),
    ("dingo_growl", dingo_growl, "oneshot", -3.0),
    ("dingo_bark", dingo_bark, "oneshot", -3.0),
    ("dingo_howl", dingo_howl, "oneshot", -3.0),
    ("dingo_yelp", dingo_yelp, "oneshot", -3.0),
    ("mouse_squeak", mouse_squeak, "oneshot", -3.0),
    ("skink_rustle", skink_rustle, "oneshot", -3.0),
    ("bird_1", lambda r: bird_oneshot(r, "warble", 1.0), "oneshot", -3.0),
    ("bird_2", lambda r: bird_oneshot(r, "whistle", 1.0), "oneshot", -3.0),
    ("bird_3", lambda r: bird_oneshot(r, "chips", 0.95), "oneshot", -3.0),
    ("turkey_call", turkey_call, "oneshot", -3.0),
    ("crow_caw", lambda r: crow_caw(r, False), "oneshot", -3.0),
    ("crow_caw_2", lambda r: crow_caw(r, True), "oneshot", -3.0),
    ("eagle_screech", eagle_screech, "oneshot", -3.0),
    ("wings", wings, "oneshot", -3.0),
    ("frog_croak", frog_croak, "oneshot", -3.0),
    ("frog_plop", frog_plop, "oneshot", -3.0),
    ("hop", hop, "oneshot", -3.0),
    ("croc_growl", croc_growl, "oneshot", -3.0),
    ("croc_lunge", croc_lunge, "oneshot", -3.0),
    ("insect_hop", insect_hop, "oneshot", -3.0),
    ("egg_crack", egg_crack, "oneshot", -3.0),
    ("hatch", hatch, "oneshot", -3.0),
    ("heartbeat", heartbeat, "oneshot", -3.0),
    ("stage_up", stage_up, "oneshot", -3.0),
    ("death", death, "oneshot", -3.0),
    ("ui_click", ui_click, "oneshot", -4.0),
    ("ui_hover", ui_hover, "oneshot", -12.0),
    ("ui_confirm", ui_confirm, "oneshot", -3.0),
]


def finalize(x: np.ndarray, kind: str, peak_db: float) -> np.ndarray:
    x = np.nan_to_num(np.asarray(x, float))
    if kind == "loop":
        n = len(x)
        X = np.fft.rfft(x) * r_hp(18, 2)(np.fft.rfftfreq(n, 1.0 / SR))
        X[0] = 0.0                       # exact zero DC, still periodic
        x = np.fft.irfft(X, n)
    else:
        x = filt(x, r_hp(20, 2))
        x = fades(x, 0.0015, min(0.03, max(0.005, 0.12 * len(x) / SR)))
    return nrm(x, 10.0 ** (peak_db / 20.0))


def write_wav(path: Path, x: np.ndarray) -> np.ndarray:
    pcm = np.clip(np.round(x * 32767.0), -32767, 32767).astype("<i2")
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(pcm.tobytes())
    return pcm


def stats(name: str, pcm: np.ndarray, kind: str):
    x = pcm.astype(float) / 32768.0
    peak = db(np.max(np.abs(x)))
    rms = db(np.sqrt(np.mean(x * x)))
    dc = float(np.mean(x))
    clipped = int(np.sum(np.abs(pcm) >= 32767))
    if kind == "loop":
        d = np.abs(np.diff(x))
        edge = f"seam {abs(x[0] - x[-1]) / (np.percentile(d, 99) + 1e-12):.2f}x"
    else:
        edge = f"edge {db(max(abs(x[0]), abs(x[-1]))):.0f} dB"
    return name, len(x) / SR, peak, rms, dc, clipped, edge


def main() -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    t_start = time.time()
    rows = []
    for name, fn, kind, peak in SOUNDS:
        r = np.random.default_rng([SEED, zlib.crc32(name.encode())])
        t0 = time.time()
        y = finalize(fn(r), kind, peak)
        pcm = write_wav(OUT_DIR / f"{name}.wav", y)
        rows.append(stats(name, pcm, kind) + (time.time() - t0,))
    total = sum((OUT_DIR / f"{r_[0]}.wav").stat().st_size for r_ in rows)
    print(f"{'file':<20}{'dur s':>7}{'peak dBFS':>11}{'rms dBFS':>10}{'DC':>10}{'clip':>6}  {'edge/seam':<14}{'t s':>6}")
    print("-" * 86)
    for name, dur, pk, rms, dc, clip, edge, el in rows:
        print(f"{name + '.wav':<20}{dur:7.2f}{pk:11.2f}{rms:10.1f}{dc:10.1e}{clip:6d}  {edge:<14}{el:6.2f}")
    print("-" * 86)
    print(f"{len(rows)} files, {total / 1024:.0f} KiB, {time.time() - t_start:.1f} s -> {OUT_DIR}")


if __name__ == "__main__":
    main()
