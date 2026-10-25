"""Procedurally synthesise the squeeze SFX into audio/*.wav.

Design notes (from research):
- A squish is slow *pressure*, not an impact: energy should build through the clip.
- Sticky/stretchy texture = trapped-air pops + strands pulling apart; the tail sells weight.
- Pitched-down wet sounds read as monstrous; boost lows/mids so it feels physical.
- Layer it: the loop (pressure + squelch grains + concrete groan) is played under
  randomly triggered pops/cracks from the game, and the burst caps the action.
"""
import os
import wave

import numpy as np

SR = 44100
OUT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "audio")
rng = np.random.default_rng(7)


def t_of(sec):
    return np.arange(int(SR * sec)) / SR


def onepole_lp(x, fc):
    """One-pole low-pass; fc may be scalar or per-sample array."""
    fc = np.broadcast_to(np.asarray(fc, dtype=np.float64), x.shape)
    a = np.exp(-2 * np.pi * fc / SR)
    y = np.empty_like(x)
    s = 0.0
    for i in range(len(x)):
        s = (1 - a[i]) * x[i] + a[i] * s
        y[i] = s
    return y


def svf_bp(x, fc, q):
    """State-variable band-pass with per-sample cutoff (resonant 'wet' formant)."""
    fc = np.broadcast_to(np.asarray(fc, dtype=np.float64), x.shape)
    f = 2 * np.sin(np.pi * np.clip(fc, 20, SR / 6) / SR)
    d = 1.0 / q
    low = band = 0.0
    y = np.empty_like(x)
    for i in range(len(x)):
        high = x[i] - low - d * band
        band += f[i] * high
        low += f[i] * band
        y[i] = band
    return y


def smooth_noise(n, rate):
    """Random control signal at `rate` Hz, cosine-interpolated."""
    k = int(n * rate / SR) + 3
    pts = rng.uniform(-1, 1, k)
    pos = np.arange(n) * rate / SR
    i = pos.astype(int)
    fr = pos - i
    w = (1 - np.cos(np.pi * fr)) * 0.5
    return pts[i] * (1 - w) + pts[i + 1] * w


def env_ad(n, attack, decay_pow=1.0):
    t = np.linspace(0, 1, n)
    a = np.clip(t / max(attack, 1e-4), 0, 1)
    return a * (1 - t) ** decay_pow


def pop(sec=0.045, f0=260.0, f1=1100.0):
    """Trapped-air bubble: sine with fast upward chirp and exponential decay."""
    t = t_of(sec)
    f = f0 * (f1 / f0) ** (t / sec)
    ph = 2 * np.pi * np.cumsum(f) / SR
    return np.sin(ph) * np.exp(-t * 70) * np.clip(t * 2000, 0, 1)


def squelch_grain(sec, fc0, fc1):
    """Short wet strand: band-passed noise with a downward formant sweep."""
    n = int(SR * sec)
    fc = np.geomspace(fc0, fc1, n)
    g = svf_bp(rng.normal(0, 1, n), fc, 6.0)
    return g * env_ad(n, 0.15, 1.6)


def normalize(x, peak=0.89):
    return x / (np.max(np.abs(x)) + 1e-9) * peak


def soft_clip(x, drive=1.6):
    return np.tanh(x * drive) / np.tanh(drive)


def save(name, x):
    os.makedirs(OUT, exist_ok=True)
    x = np.clip(x, -1, 1)
    pcm = (x * 32767).astype("<i2")
    with wave.open(os.path.join(OUT, name + ".wav"), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(pcm.tobytes())
    print("wrote", name, f"{len(x) / SR:.2f}s")


def make_loop(sec=3.0):
    """'グジュウ〜' sustain: wet formant noise + squelch grains + low concrete groan. Seamless loop."""
    n = int(SR * sec)
    xf = int(SR * 0.25)
    total = n + xf
    noise = rng.normal(0, 1, total)
    # Two moving formants make it sound like a mouth/slime rather than wind.
    f1 = 650 + 300 * smooth_noise(total, 3.5)
    f2 = 1700 + 600 * smooth_noise(total, 5.0)
    wet = svf_bp(noise, f1, 8.0) * 0.8 + svf_bp(noise, f2, 10.0) * 0.6
    wet *= 0.6 + 0.4 * np.abs(smooth_noise(total, 6.0))
    # Grains: sticky strands pulling apart.
    grains = np.zeros(total)
    pos = 0
    while pos < total - SR // 5:
        g = squelch_grain(rng.uniform(0.04, 0.12), rng.uniform(1800, 3500), rng.uniform(400, 900))
        grains[pos:pos + len(g)] += g * rng.uniform(0.4, 1.0)
        if rng.uniform() < 0.35:  # juicy droplet
            pp = pop(rng.uniform(0.02, 0.04), rng.uniform(500, 900), rng.uniform(1500, 2800))
            grains[pos:pos + len(pp)] += pp * 0.3
        pos += int(rng.uniform(0.025, 0.08) * SR)
    # Concrete groan: jittery low saw, heavily low-passed.
    t = np.arange(total) / SR
    fg = 48 + 10 * smooth_noise(total, 1.3) + 4 * smooth_noise(total, 17)
    saw = 2 * ((np.cumsum(fg) / SR) % 1.0) - 1
    groan = onepole_lp(saw, 220) * (0.6 + 0.4 * smooth_noise(total, 2.0))
    sub = np.sin(2 * np.pi * np.cumsum(32 + 3 * smooth_noise(total, 0.7)) / SR)
    x = wet * 0.55 + grains * 1.0 + groan * 0.2 + sub * 0.15
    x = soft_clip(normalize(x, 1.0), 1.8)
    # Crossfade tail into head for a seamless loop.
    fade = np.linspace(0, 1, xf)
    head = x[:xf] * fade + x[n:n + xf] * (1 - fade)
    loop = np.concatenate([head, x[xf:n]])
    return normalize(loop, 0.8)


def make_crack(sec=0.35):
    """Glass/concrete crunch: a cluster of tiny filtered clicks."""
    n = int(SR * sec)
    x = np.zeros(n)
    pos = 0
    while pos < n - 800:
        m = int(rng.uniform(0.002, 0.008) * SR)
        click = rng.normal(0, 1, m) * np.exp(-np.linspace(0, 6, m))
        x[pos:pos + m] += click * rng.uniform(0.3, 1.0)
        pos += int(rng.exponential(0.012) * SR) + 1
    hp = x - onepole_lp(x, 1500)
    body = onepole_lp(x, 400) * 2.5
    return normalize((hp + body) * env_ad(n, 0.02, 1.2), 0.85)


def make_burst(sec=2.2):
    """Final splat: low thump + wet gush + bubbling tail + debris."""
    n = int(SR * sec)
    t = np.arange(n) / SR
    thump = np.sin(2 * np.pi * np.cumsum(90 * np.exp(-t * 6) + 38) / SR) * np.exp(-t * 4.5)
    gush_n = rng.normal(0, 1, n)
    gush = svf_bp(gush_n, 1400 * np.exp(-t * 2.2) + 220, 3.0) * np.exp(-t * 2.4) * np.clip(t * 60, 0, 1)
    tail = np.zeros(n)
    pos = int(0.05 * SR)
    while pos < n - SR // 10:
        p = pop(rng.uniform(0.03, 0.07), rng.uniform(150, 350), rng.uniform(600, 1500))
        dens = np.exp(-pos / SR * 1.4)
        tail[pos:pos + len(p)] += p * rng.uniform(0.3, 1.0) * dens
        pos += int(rng.exponential(0.035 / dens) * SR) + 200
    crack = make_crack(0.6)
    debris = np.zeros(n)
    debris[:len(crack)] += crack
    x = thump * 1.2 + gush * 0.9 + tail * 0.55 + debris * 0.5
    return normalize(soft_clip(normalize(x, 1.0), 2.0), 0.95)


def make_snap(sec=0.32):
    """'サクッ' fresh crunch: dense fibrous crackle (like biting an apple) + short juicy spray."""
    n = int(SR * sec)
    t = np.arange(n) / SR
    x = np.zeros(n)
    pos = 0
    while pos < n - 400:
        m = int(rng.uniform(0.0008, 0.003) * SR)
        click = rng.normal(0, 1, m) * np.exp(-np.linspace(0, 8, m))
        x[pos:pos + m] += click * rng.uniform(0.4, 1.0) * np.exp(-pos / SR * 14)
        pos += int(rng.exponential(0.0035) * SR) + 1
    crisp = x - onepole_lp(x, 2500)
    body = svf_bp(x, 900.0, 3.0) * 1.5
    spray = svf_bp(rng.normal(0, 1, n), 5200 * np.exp(-t * 5) + 1500, 2.0) * np.exp(-t * 11) * 0.5
    return normalize(soft_clip(crisp + body + spray, 1.4), 0.9)


def make_squirt(sec=0.5):
    """Juice spraying out: band-passed hiss sweeping down plus bright droplets."""
    n = int(SR * sec)
    t = np.arange(n) / SR
    hiss = svf_bp(rng.normal(0, 1, n), 4500 * np.exp(-t * 3.5) + 1100, 3.0)
    hiss *= np.clip(t * 120, 0, 1) * np.exp(-t * 6)
    drops = np.zeros(n)
    pos = int(0.02 * SR)
    while pos < n - SR // 20:
        pp = pop(rng.uniform(0.015, 0.035), rng.uniform(600, 1200), rng.uniform(1800, 3200))
        drops[pos:pos + len(pp)] += pp * rng.uniform(0.2, 0.6) * np.exp(-pos / SR * 4)
        pos += int(rng.exponential(0.03) * SR) + 100
    return normalize(hiss + drops * 0.7, 0.85)


def make_beads(sec=0.5):
    """'ざらざら': a handful of little metal beads rolling and clicking against each other."""
    n = int(SR * sec)
    t = np.arange(n) / SR
    x = np.zeros(n)
    density = np.sin(np.pi * np.clip(t / sec, 0, 1)) ** 0.7  # swell up and die away
    pos = 0
    while pos < n - 600:
        m = int(rng.uniform(0.003, 0.008) * SR)
        f = rng.uniform(3200, 8500)
        tt = np.arange(m) / SR
        click = np.sin(2 * np.pi * f * tt) * np.exp(-tt * rng.uniform(600, 1400))
        x[pos:pos + m] += click * rng.uniform(0.2, 1.0) * density[pos]
        pos += int(rng.exponential(0.0045) * SR / (0.2 + density[pos])) + 20
    roll = rng.normal(0, 1, n)
    roll = (roll - onepole_lp(roll, 3000)) * density * 0.08
    return normalize(x + roll, 0.75)


def bell(f, sec, decay):
    t = t_of(sec)
    return (np.sin(2 * np.pi * f * t) + 0.4 * np.sin(2 * np.pi * f * 2.76 * t)) * np.exp(-t * decay)


def make_beam_loop(sec=1.6):
    """Cute power beam: detuned saw chord with a fast shimmer and an airy hiss. Loopable."""
    n = int(SR * sec)
    t = np.arange(n) / SR
    x = np.zeros(n)
    for f in (220.0, 277.2, 329.6, 440.0):  # A major, whole number of cycles per loop
        f = round(f * sec) / sec
        for det in (-0.4, 0.4):
            ff = f + det / sec
            x += 2 * ((ff * t) % 1.0) - 1
    x = onepole_lp(x, 2500) * (0.75 + 0.25 * np.sin(2 * np.pi * (24 / sec) * t))
    hiss = rng.normal(0, 1, n)
    hiss = (hiss - onepole_lp(hiss, 4000)) * 0.15
    y = normalize(x, 1.0) + hiss
    fade = int(SR * 0.05)  # tiny seam smoothing
    y[:fade] *= np.linspace(0.5, 1, fade)
    y[-fade:] *= np.linspace(1, 0.5, fade)
    return normalize(y, 0.7)


def make_star_pop(sec=0.5):
    """A building turning into stars: bright upward sparkle of bells."""
    n = int(SR * sec)
    x = np.zeros(n)
    base = rng.uniform(900, 1300)
    for i, ratio in enumerate((1.0, 1.25, 1.5, 2.0, 2.5, 3.0)):
        start = int(i * 0.035 * SR)
        b = bell(base * ratio, sec, rng.uniform(9, 14))
        x[start:] += b[: n - start] * (1.0 - i * 0.1)
    thump = np.sin(2 * np.pi * 120 * t_of(sec)) * np.exp(-t_of(sec) * 25)
    return normalize(x + thump * 0.6, 0.85)


def make_shari_loop(sec=2.0):
    """'きらきらしゃりしゃり': crushed ice crunching with glassy glints. Loopable."""
    n = int(SR * sec)
    xf = int(SR * 0.2)
    total = n + xf
    x = np.zeros(total)
    pos = 0
    while pos < total - 400:
        m = int(rng.uniform(0.001, 0.004) * SR)
        g = rng.normal(0, 1, m) * np.exp(-np.linspace(0, 7, m))
        x[pos:pos + m] += g * rng.uniform(0.2, 1.0)
        if rng.uniform() < 0.06:  # a glint of a crystal
            b = bell(rng.uniform(2500, 6000), 0.12, 40)
            x[pos:pos + len(b)] += b[: total - pos] * 0.25
        pos += int(rng.exponential(0.006) * SR) + 1
    x = x - onepole_lp(x, 1800)
    fade = np.linspace(0, 1, xf)
    head = x[:xf] * fade + x[n:n + xf] * (1 - fade)
    return normalize(np.concatenate([head, x[xf:n]]), 0.75)


def make_ice_burst(sec=1.2):
    """Frozen building shattering: crunch, then a shower of glassy pings."""
    n = int(SR * sec)
    t = np.arange(n) / SR
    x = np.zeros(n)
    crunch = make_crack(0.3)
    x[:len(crunch)] += crunch
    pos = int(0.03 * SR)
    while pos < n - SR // 10:
        b = bell(rng.uniform(2000, 7000), 0.25, rng.uniform(15, 30))
        dens = np.exp(-pos / SR * 2.5)
        x[pos:pos + len(b)] += b[: n - pos] * rng.uniform(0.2, 0.6) * dens
        pos += int(rng.exponential(0.02 / dens) * SR) + 50
    return normalize(x, 0.9)


def make_freeze(sec=0.7):
    """'カチーン': a cold high chime."""
    x = bell(1760, sec, 6) + bell(2637, sec, 8) * 0.6 + bell(3520, sec, 10) * 0.3
    return normalize(x, 0.7)


def make_thud(sec=0.6):
    """Giant palm slapping the ground while crawling."""
    t = t_of(sec)
    body = np.sin(2 * np.pi * np.cumsum(70 * np.exp(-t * 9) + 34) / SR) * np.exp(-t * 7)
    dust = onepole_lp(rng.normal(0, 1, len(t)), 900) * np.exp(-t * 10) * 2
    return normalize(soft_clip(body + dust * 0.4, 1.5), 0.9)


def make_select():
    t = t_of(0.12)
    s = np.sin(2 * np.pi * (520 + 600 * t / 0.12) * t) * np.exp(-t * 30)
    return normalize(s, 0.5)


def make_ambience(sec=8.0):
    """Distant city rumble bed, loopable."""
    n = int(SR * sec)
    xf = int(SR * 1.0)
    total = n + xf
    x = onepole_lp(onepole_lp(rng.normal(0, 1, total), 180), 300)
    x *= 0.7 + 0.3 * smooth_noise(total, 0.4)
    hiss = onepole_lp(rng.normal(0, 1, total), 2500) - onepole_lp(rng.normal(0, 1, total), 600)
    x = normalize(x, 1.0) + normalize(hiss, 0.05)
    fade = np.linspace(0, 1, xf)
    head = x[:xf] * fade + x[n:n + xf] * (1 - fade)
    return normalize(np.concatenate([head, x[xf:n]]), 0.5)


def main():
    save("squeeze_loop", make_loop())
    for i in range(4):
        f0 = rng.uniform(200, 340)
        save(f"pop{i}", normalize(pop(rng.uniform(0.035, 0.06), f0, f0 * rng.uniform(3, 5)), 0.8))
    for i in range(3):
        save(f"crack{i}", make_crack(rng.uniform(0.25, 0.45)))
    save("burst", make_burst())
    save("thud", make_thud())
    for i in range(3):
        save(f"snap{i}", make_snap(rng.uniform(0.25, 0.4)))
    for i in range(2):
        save(f"squirt{i}", make_squirt(rng.uniform(0.4, 0.6)))
    for i in range(3):
        save(f"beads{i}", make_beads(rng.uniform(0.4, 0.65)))
    save("beam_loop", make_beam_loop())
    for i in range(3):
        save(f"star_pop{i}", make_star_pop())
    save("shari_loop", make_shari_loop())
    save("ice_burst", make_ice_burst())
    save("freeze", make_freeze())
    save("select", make_select())
    save("ambience", make_ambience())


if __name__ == "__main__":
    main()
