"""Anatomical dingo (Canis dingo) sculpt in the MammalRig rest pose (legs straight)."""
import math
import numpy as np
from kit import Mesh, paw, keel_section, nrm, R_EYE, R_NOSE, R_CLAW, R_PAD


def build(A):
    body = Mesh("u_body")
    # ---- torso (rump -> chest): deep narrow chest, tucked waist, level topline
    st = [
        (-0.395, 0.505, 0.035, 0.035, 0.035),
        (-0.37, 0.512, 0.068, 0.064, 0.068),
        (-0.33, 0.516, 0.086, 0.074, 0.088),
        (-0.27, 0.518, 0.09, 0.078, 0.098),
        (-0.19, 0.522, 0.084, 0.077, 0.08),
        (-0.11, 0.526, 0.08, 0.076, 0.068),
        (-0.03, 0.522, 0.086, 0.081, 0.088),
        (0.05, 0.518, 0.093, 0.086, 0.122),
        (0.12, 0.518, 0.096, 0.09, 0.145),
        (0.19, 0.523, 0.092, 0.093, 0.142),
        (0.25, 0.532, 0.08, 0.088, 0.12),
        (0.3, 0.546, 0.06, 0.068, 0.084),
        (0.33, 0.56, 0.034, 0.04, 0.044),
    ]
    body.loft([((0, y, z), hw, t, b) for (z, y, hw, t, b) in st], ring=40, section=keel_section(0.2))
    for s in (-1, 1):
        body.ellipsoid((0.052 * s, 0.49, 0.19), (0.04, 0.075, 0.062), None, 18, 12)    # shoulder
        body.ellipsoid((0.052 * s, 0.465, -0.255), (0.046, 0.095, 0.078), None, 18, 12)  # haunch
    # ---- neck
    body.loft([((0, 0.56, 0.2), 0.07, 0.07, 0.085), ((0, 0.585, 0.27), 0.064, 0.064, 0.072),
               ((0, 0.603, 0.33), 0.058, 0.058, 0.058), ((0, 0.61, 0.38), 0.053, 0.052, 0.05)], ring=32)
    # ---- head: cranium, cheeks, muzzle (roughly as long as the skull)
    body.ellipsoid((0, 0.607, 0.402), (0.055, 0.048, 0.062), None, 26, 16)
    for s in (-1, 1):
        body.ellipsoid((0.038 * s, 0.574, 0.425), (0.024, 0.022, 0.034), None, 16, 10)   # cheek
        body.ellipsoid((0.034 * s, 0.609, 0.455), (0.012, 0.007, 0.013), None, 10, 6)   # soft brow
    muzzle = [
        ((0, 0.592, 0.44), 0.05, 0.036, 0.036),
        ((0, 0.585, 0.47), 0.044, 0.031, 0.033),
        ((0, 0.578, 0.505), 0.036, 0.027, 0.03),
        ((0, 0.573, 0.54), 0.03, 0.024, 0.026),
        ((0, 0.57, 0.565), 0.025, 0.021, 0.022),
        ((0, 0.568, 0.582), 0.017, 0.015, 0.015),
    ]
    body.loft(muzzle, ring=28)
    # ---- bushy tail
    tail = [((0, 0.505, -0.36), 0.028, 0.03, 0.03), ((0, 0.505, -0.43), 0.036, 0.04, 0.04),
            ((0, 0.505, -0.52), 0.046, 0.048, 0.048), ((0, 0.505, -0.62), 0.05, 0.052, 0.052),
            ((0, 0.505, -0.7), 0.042, 0.044, 0.044), ((0, 0.505, -0.76), 0.022, 0.024, 0.024),
            ((0, 0.505, -0.785), 0.006, 0.006, 0.006)]
    body.loft(tail, ring=24)
    # ---- legs: smooth single tubes with an anatomical radius profile
    claws = Mesh("r_claws")
    pads = Mesh("r_pads")
    for s in (-1, 1):
        x = 0.066 * s
        fl = [(x * 0.85, 0.48, 0.175), (x, 0.43, 0.166), (x, 0.37, 0.158), (x, 0.3, 0.157), (x, 0.26, 0.161),
              (x, 0.2, 0.166), (x, 0.14, 0.168), (x, 0.1, 0.171), (x * 0.99, 0.06, 0.177), (x * 0.98, 0.035, 0.185)]
        fr = [0.046, 0.042, 0.035, 0.027, 0.023, 0.02, 0.017, 0.015, 0.0145, 0.015]
        body.tube(fl, fr, 20)
        paw(body, claws, pads, (x * 0.98, 0.016, 0.195), (0.0, 0.0, 1.0), 0.0175)
        hx = 0.064 * s
        hl = [(hx * 0.8, 0.52, -0.245), (hx, 0.45, -0.247), (hx, 0.38, -0.243), (hx, 0.31, -0.228), (hx, 0.27, -0.228),
              (hx, 0.2, -0.244), (hx, 0.13, -0.257), (hx, 0.088, -0.262), (hx, 0.03, -0.25), (hx, -0.022, -0.238)]
        hr = [0.058, 0.054, 0.046, 0.032, 0.027, 0.023, 0.018, 0.016, 0.0135, 0.014]
        body.tube(hl, hr, 20)
        paw(body, claws, pads, (hx * 0.98, -0.05, -0.215), (0.0, 0.0, 1.0), 0.0165, dew=False)
    # ---- separate rigid pieces
    jaw = Mesh("r_jaw")
    jaw.loft([((0, 0.548, 0.43), 0.038, 0.016, 0.019), ((0, 0.548, 0.47), 0.033, 0.016, 0.017),
              ((0, 0.55, 0.51), 0.027, 0.015, 0.014), ((0, 0.553, 0.545), 0.02, 0.013, 0.011),
              ((0, 0.556, 0.568), 0.012, 0.009, 0.007)], ring=24)
    nose = Mesh("r_nose")
    nose.ellipsoid((0, 0.572, 0.582), (0.017, 0.0125, 0.011), None, 20, 12)
    eyes = Mesh("r_eyes")
    eye_spec = []
    for s in (-1, 1):
        ax = nrm([0.62 * s, 0.12, 0.78])
        c = np.array([0.041 * s, 0.6, 0.458]) - ax * 0.002
        eyes.ellipsoid(tuple(c), (0.0095, 0.0095, 0.0095), None, 20, 14)
        eye_spec.append(dict(center=c, axis=ax, radius=0.0095, iris=(0.58, 0.38, 0.13)))
    ears = []
    for s, key in ((1, "earL"), (-1, "earR")):
        e = Mesh("r_" + key)
        base = np.array([0.042 * s, 0.622, 0.405])
        tip = base + np.array([0.012 * s, 0.1, -0.008])
        pts = [tuple(base - np.array([0, 0.012, 0])), tuple(base + (tip - base) * 0.35), tuple(base + (tip - base) * 0.7), tuple(tip)]
        e.tube(pts, [0.024, 0.021, 0.013, 0.002], 18, flat=0.36, up=(0, 0, 1))
        ears.append((e, key))
    return dict(
        union=[body.build()],
        rigid=[(jaw.build(), "jaw", 0), (nose.build(), "head", R_NOSE), (eyes.build(), "head", R_EYE),
               (claws.build(), None, R_CLAW), (pads.build(), None, R_PAD)]
              + [(e.build(), key, 0) for e, key in ears],
        eyes=eye_spec,
    )
