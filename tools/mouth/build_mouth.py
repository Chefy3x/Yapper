# The Loud Mouth: Yapper's 3D cartoon mouth for the Voice In pill, built and rigged in Blender.
# Closed lens-shaped lips on a fixed (s, t) grid, crooked cream teeth with one gold tooth, a tongue
# and a dark inside; an anatomy rig (upper teeth fixed to the head, a jaw hinged far back that
# carries the lower teeth and tongue, two rings of lip bones); matte cel shading and an ink outline.
#
# This script is the art source. The app does not run Blender: `--export` writes the rest meshes,
# bone weights, materials and rig constants to Yapper/Resources/mouth.rig, which Yapper/Mouth/
# skins and draws with Metal. Re-export after changing anything here.
#
#   Blender -b --factory-startup -P tools/mouth/build_mouth.py -- <out>              stills + mouth.blend
#   ... -- <out> --stills=rest,ee,ah,oo [--res=320x200 --ortho=4.0 --camz=-0.25]     just these stills
#   ... -- <out> track.json [--spring=0.5]                                           a voice track (reader_offline.py)
#   ... -- <out> --export=Yapper/Resources/mouth.rig --fixtures=YapperTests/Fixtures/Mouth
import bpy, bmesh, math, sys, os
from mathutils import Vector

ARGS = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else ["mouth-out"]
POS = [a for a in ARGS if not a.startswith("--") or a == "--board"]   # positional: out [track]
out = POS[0]
TRACK = POS[1] if len(POS) > 1 else None
os.makedirs(out, exist_ok=True)

# ---------- looks ----------
# ref is the app's look (picked 2026-10-19); export with no --look to get it.
# v1: the first version in the app. ref: closer to the reference art
# (big crooked outlined teeth with gaps, long pointed corners, a deep cupid's bow, bolder ink, a
# franker view, a wider jaw). gloss adds painted white highlights; deep adds a third
# cel band and darker shadows for more form.
LOOKS = {
    "v1": {},
    "ref": dict(corner_ext=0.20, bow=0.25, ends=0.8, lip_ink=0.058, teeth="big", tooth_ink=0.03, jaw_deg=13.0,
                # the lower lip drops broadly, so a wide open stays a crescent rather than a V
                follow_lo=0.70, follow_reach=0.95, follow_od=(0.30, 0.30),
                oval_drop=0.03, upper_lift=0.10, pitch=4.0, yaw=-5.0, roll=0.0, lips="flat",
                # clean teeth (picked over the crooked set): straight, even, rounded, small gaps
                teeth_tilt=0.1, teeth_fill=0.97, teeth_h=0.97, teeth_round=0.3, teeth_push=0.0, teeth_even=True),
}
LOOKS["gloss"] = {**LOOKS["ref"], "lips": "gloss"}
LOOKS["deep"] = {**LOOKS["ref"], "lips": "deep"}
LOOKS["pop"] = {**LOOKS["ref"], "lips": "pop"}
# teeth variants on ref: crooked = the big crooked set first tried; tidy = rounder, less crooked
LOOKS["crooked"] = {**LOOKS["ref"], "teeth_tilt": 1.0, "teeth_fill": 0.9, "teeth_h": 1.0, "teeth_round": 0.2, "teeth_push": 1.0,
                    "teeth_even": False}
LOOKS["tidy"] = {**LOOKS["crooked"], "teeth_tilt": 0.45, "teeth_fill": 0.95, "teeth_round": 0.34, "teeth_push": 0.4}
LOOK_NAME = next((a.split("=", 1)[1] for a in ARGS if a.startswith("--look=")), "ref")
LOOK = {"corner_ext": 0.08, "bow": 0.19, "ends": 0.45, "lip_ink": 0.045, "teeth": "v1", "tooth_ink": 0.022,
        "teeth_tilt": 1.0, "teeth_fill": 0.9, "teeth_h": 1.0, "teeth_round": 0.2, "teeth_push": 1.0, "teeth_even": False,
        "jaw_deg": 11.0, "follow_lo": 0.62, "follow_reach": 0.74, "follow_od": (0.24, 0.38), "oval_drop": 0.10, "upper_lift": 0.03, "pitch": 6.0, "yaw": -12.0, "roll": 4.0, "lips": "v1", **LOOKS[LOOK_NAME]}

POSES = [
    dict(name="rest",   open=0.0,  width=1.0,  round=0.0, clench=False),
    dict(name="open",   open=1.0,  width=1.0,  round=0.1, clench=False),
    dict(name="wide",   open=0.3,  width=1.12, round=0.0, clench=False),
    dict(name="round",  open=0.75, width=0.78, round=0.9, clench=False),
    dict(name="pucker", open=0.25, width=0.6,  round=1.0, clench=False),
    dict(name="teeth",  open=0.32, width=1.05, round=0.1, clench=True),
]
NS, NT = 72, 14          # grid along the lip, across the lip
WRAP = 0.30              # how far the corners curve back around the face

# ---------- 2D mouth curves (x right, z up), ported from the flat mock ----------
def cubic(p0, p1, p2, p3, n=120):
    pts = []
    for i in range(n + 1):
        t = i / n; u = 1 - t
        pts.append((u*u*u*p0[0] + 3*u*u*t*p1[0] + 3*u*t*t*p2[0] + t*t*t*p3[0],
                    u*u*u*p0[1] + 3*u*u*t*p1[1] + 3*u*t*t*p2[1] + t*t*t*p3[1]))
    return pts

def y_at(pts, x):
    pts = sorted(pts)
    if x <= pts[0][0]: return pts[0][1]
    for (x0, y0), (x1, y1) in zip(pts, pts[1:]):
        if x0 <= x <= x1:
            return y0 if x1 == x0 else y0 + (y1 - y0) * (x - x0) / (x1 - x0)
    return pts[-1][1]

class Curves:
    def __init__(self, p):
        self.p = p
        w = p["width"]; self.w = w; self.corner = w + LOOK["corner_ext"]
        self.top = 0.02 + 0.13 * p["open"] + 0.05 * p["round"]
        self.bot = 0.03 + 0.52 * p["open"] + 0.06 * p["round"]
        reach = 0.42 + 0.4 * p["round"]
        k = self.top * 1.33
        self.up_in = cubic((-w, 0), (-w*reach, k), (w*reach, k), (w, 0))
        kb = self.bot * 1.33
        self.lo_in = cubic((-w, 0), (-w*reach, -kb), (w*reach, -kb), (w, 0))
        lift = self.top
        peak = lift + 0.30 + 0.03 * p["round"]; bow = lift + LOOK["bow"]; c = self.corner
        pxL, pxR = 0.38 * w, 0.34 * w            # left peak sits wider and higher than the right
        pkL, pkR = peak + 0.025, peak - 0.012
        bx = 0.03 * w                           # the dip is a touch off centre
        self.up_out = (cubic((-c, -0.02), (-c*0.82, 0.12 + lift), (-pxL - 0.3*w, pkL), (-pxL, pkL)) +
                       cubic((-pxL, pkL), (-pxL + 0.17*w, pkL), (bx - 0.03*w, bow + 0.05), (bx, bow)) +
                       cubic((bx, bow), (bx + 0.03*w, bow + 0.05), (pxR - 0.15*w, pkR), (pxR, pkR)) +
                       cubic((pxR, pkR), (pxR + 0.3*w, pkR), (c*0.82, 0.12 + lift), (c, -0.02)))
        bottom = self.bot + 0.41 + 0.04 * p["round"]
        self.lo_out = cubic((-c, -0.02), (-c*0.72, -bottom*1.40), (c*0.52, -bottom*1.24), (c, -0.02))

SMIRK = 0.07
def style(x, z, edge):
    """Hand-made character: the right corner lifts into a smirk, and the outer edge wobbles a little."""
    z += SMIRK * max(0.0, x) ** 2
    z += edge * (0.016 * math.sin(4.3 * x + 0.6) + 0.008 * math.sin(9.7 * x + 2.2))
    return z

def wrap(x): return WRAP * x * x

# ---------- lip and cavity geometry on a fixed grid ----------
def lip_points(cv, upper):
    """Closed lens volume: a front sheet and a thin back sheet sharing the rim."""
    inner = cv.up_in if upper else cv.lo_in
    outer = cv.up_out if upper else cv.lo_out
    front, back = [], []
    for i in range(NS + 1):
        s = i / NS
        xi = -cv.w + 2 * cv.w * s
        xo = -cv.corner + 2 * cv.corner * s
        pin = (xi, y_at(inner, xi)); pout = (xo, y_at(outer, xo))
        ends = math.sin(math.pi * s) ** LOOK["ends"]
        fr, bk = [], []
        for j in range(NT + 1):
            t = j / NT
            x = pin[0] + (pout[0] - pin[0]) * t
            z = style(x, pin[1] + (pout[1] - pin[1]) * t, t)
            prof = math.sin(math.pi * t ** 0.85) ** 0.7 * ends
            r = 1 + 0.15 * cv.p["round"]
            if upper:
                full = 0.20 * r * (1 + 0.28 * math.exp(-((x - 0.03) / 0.22) ** 2))
            else:
                lobes = math.exp(-((x - 0.32) / 0.28) ** 2) + math.exp(-((x + 0.30) / 0.28) ** 2)
                full = 0.25 * r * (1 + 0.14 * lobes) * (1 - 0.06 * x)
            fr.append((x, wrap(x) - full * prof, z))
            bk.append((x, wrap(x) + 0.05 * prof, z))
        front.append(fr); back.append(bk)
    return front, back

def cavity_points(cv):
    """The dark inside of the mouth: a wide backdrop behind the teeth; the skin mask trims it."""
    rows = []
    for i in range(NS + 1):
        x = -1.6 + 3.2 * i / NS
        rows.append([(x, 0.62 + wrap(min(abs(x), 1.1)) * 0.8, 1.0 - 2.2 * j / NT) for j in range(NT + 1)])
    return rows

def skin_points(cv, upper):
    """Invisible skin around the opening (a holdout): hides teeth and the inside outside the lips.
    Across the opening its columns sit exactly on the lips' inner rim (same s spacing), so in any
    blend of shapes the hole and the lips move together and nothing peeks out at the corners."""
    inner = cv.up_in if upper else cv.lo_in
    NA = 10
    xs = ([-3.0 + (3.0 - cv.w) * i / NA for i in range(NA)] +
          [-cv.w + 2 * cv.w * i / NS for i in range(NS + 1)] +
          [cv.w + (3.0 - cv.w) * (i + 1) / NA for i in range(NA)])
    rows = []
    for x in xs:
        z0 = style(x, y_at(inner, x) if abs(x) < cv.w else 0.0, 0.0)
        z1 = 3.0 if upper else -3.0
        # bunch the rows near the opening edge, where the shape matters
        rows.append([(x, 0.13 + wrap(min(abs(x), 1.2)), z0 + (z1 - z0) * (j / NT) ** 2) for j in range(NT + 1)])
    return rows

def grid_faces(nu, nv, offset=0, flip=False):
    faces = []
    for i in range(nu):
        for j in range(nv):
            a = offset + i * (nv + 1) + j
            f = (a, a + nv + 1, a + nv + 2, a + 1)
            faces.append(f[::-1] if flip else f)
    return faces

def lens_coords(front, back):
    co = [v for row in front for v in row] + [v for row in back for v in row]
    return co

def build_lens(name, front, back):
    co = lens_coords(front, back)
    n = (NS + 1) * (NT + 1)
    faces = grid_faces(NS, NT, 0, flip=False) + grid_faces(NS, NT, n, flip=True)
    me = bpy.data.meshes.new(name); me.from_pydata(co, [], faces); me.update()
    ob = bpy.data.objects.new(name, me); bpy.context.collection.objects.link(ob)
    return ob

def build_sheet(name, rows):
    co = [v for row in rows for v in row]
    me = bpy.data.meshes.new(name); me.from_pydata(co, [], grid_faces(len(rows) - 1, NT)); me.update()
    ob = bpy.data.objects.new(name, me); bpy.context.collection.objects.link(ob)
    return ob

# ---------- materials: cartoon bands + an ink outline ----------
def toon(name, base, shade, spec=None, cut=0.42, spec_cut=0.55, rough=0.28):
    m = bpy.data.materials.new(name); m.use_nodes = True
    nt = m.node_tree; nt.nodes.clear(); N = nt.nodes.new; L = nt.links.new
    outp = N("ShaderNodeOutputMaterial"); em = N("ShaderNodeEmission")
    dif = N("ShaderNodeBsdfDiffuse"); s2r = N("ShaderNodeShaderToRGB"); ramp = N("ShaderNodeValToRGB")
    L(dif.outputs[0], s2r.inputs[0]); L(s2r.outputs[0], ramp.inputs[0])
    r = ramp.color_ramp; r.interpolation = "CONSTANT"
    r.elements[0].position = 0.0; r.elements[0].color = (*shade, 1)
    r.elements[1].position = cut; r.elements[1].color = (*base, 1)
    col = ramp.outputs[0]
    if spec:
        g = N("ShaderNodeBsdfGlossy"); g.inputs["Roughness"].default_value = rough
        s2 = N("ShaderNodeShaderToRGB"); r2 = N("ShaderNodeValToRGB")
        L(g.outputs[0], s2.inputs[0]); L(s2.outputs[0], r2.inputs[0])
        e = r2.color_ramp; e.interpolation = "CONSTANT"
        e.elements[0].position = 0.0; e.elements[0].color = (0, 0, 0, 1)
        e.elements[1].position = spec_cut; e.elements[1].color = (*spec, 1)
        mix = N("ShaderNodeMix"); mix.data_type = "RGBA"; mix.blend_type = "LIGHTEN"
        mix.inputs[0].default_value = 1.0
        L(col, mix.inputs[6]); L(r2.outputs[0], mix.inputs[7]); col = mix.outputs[2]
    L(col, em.inputs[0]); L(em.outputs[0], outp.inputs[0])
    return m

def stroke_mask(nt, uvsep, strokes, width):
    """Union of short curved strokes in (u, v): each is (u0, v0, v1, bend)."""
    N = nt.nodes.new; L = nt.links.new
    def math_node(op, a=None, b=None):
        m = N("ShaderNodeMath"); m.operation = op
        for k, x in enumerate((a, b)):
            if x is None: continue
            if isinstance(x, (int, float)): m.inputs[k].default_value = x
            else: L(x, m.inputs[k])
        return m.outputs[0]
    u, v = uvsep.outputs[0], uvsep.outputs[1]
    acc = None
    for (u0, v0, v1, bend) in strokes:
        vm = math_node("SUBTRACT", v, (v0 + v1) / 2)
        curve = math_node("MULTIPLY", math_node("MULTIPLY", vm, vm), bend)
        du = math_node("ABSOLUTE", math_node("SUBTRACT", math_node("SUBTRACT", u, u0), curve))
        # taper: thinner toward both ends of the stroke
        half = (v1 - v0) / 2
        along = math_node("SUBTRACT", 1.0, math_node("DIVIDE", math_node("ABSOLUTE", vm), half))
        w = math_node("MULTIPLY", math_node("POWER", math_node("MAXIMUM", along, 0.0), 0.35), width)
        hit = math_node("LESS_THAN", du, w)
        acc = hit if acc is None else math_node("MAXIMUM", acc, hit)
    return acc

def gloss_mask(nt, uvsep, gloss):
    """Painted highlights running along the lip: each is (v0, u0, u1, bend, width) in (s, t)."""
    N = nt.nodes.new; L = nt.links.new
    def math_node(op, a=None, b=None):
        m = N("ShaderNodeMath"); m.operation = op
        for k, x in enumerate((a, b)):
            if x is None: continue
            if isinstance(x, (int, float)): m.inputs[k].default_value = x
            else: L(x, m.inputs[k])
        return m.outputs[0]
    u, v = uvsep.outputs[0], uvsep.outputs[1]
    acc = None
    for (v0, u0, u1, bend, width) in gloss:
        um = math_node("SUBTRACT", u, (u0 + u1) / 2)
        dv = math_node("ABSOLUTE", math_node("SUBTRACT", math_node("SUBTRACT", v, v0),
                                             math_node("MULTIPLY", math_node("MULTIPLY", um, um), bend)))
        along = math_node("SUBTRACT", 1.0, math_node("DIVIDE", math_node("ABSOLUTE", um), (u1 - u0) / 2))
        w = math_node("MULTIPLY", math_node("POWER", math_node("MAXIMUM", along, 0.0), 0.5), width)
        hit = math_node("LESS_THAN", dv, w)
        acc = hit if acc is None else math_node("MAXIMUM", acc, hit)
    return acc

def matte(name, shade, base, light, cut1, cut2, band=None, strokes=None, stroke_col=None, gloss=None, gloss_col=None):
    m = bpy.data.materials.new(name); m.use_nodes = True
    nt = m.node_tree; nt.nodes.clear(); N = nt.nodes.new; L = nt.links.new
    outp = N("ShaderNodeOutputMaterial"); em = N("ShaderNodeEmission")
    dif = N("ShaderNodeBsdfDiffuse"); s2r = N("ShaderNodeShaderToRGB"); ramp = N("ShaderNodeValToRGB")
    L(dif.outputs[0], s2r.inputs[0]); L(s2r.outputs[0], ramp.inputs[0])
    r = ramp.color_ramp; r.interpolation = "CONSTANT"
    r.elements[0].position = 0.0; r.elements[0].color = (*shade, 1)
    r.elements[1].position = cut1; r.elements[1].color = (*base, 1)
    e = r.elements.new(cut2); e.color = (*light, 1)
    col = ramp.outputs[0]
    if band:
        uv = N("ShaderNodeUVMap"); uv.uv_map = "st"
        sep = N("ShaderNodeSeparateXYZ"); lt = N("ShaderNodeMath"); lt.operation = "LESS_THAN"
        lt.inputs[1].default_value = band
        L(uv.outputs[0], sep.inputs[0]); L(sep.outputs[1], lt.inputs[0])
        mix = N("ShaderNodeMix"); mix.data_type = "RGBA"; mix.blend_type = "MULTIPLY"
        L(lt.outputs[0], mix.inputs[0]); L(col, mix.inputs[6]); mix.inputs[7].default_value = (0.58, 0.55, 0.55, 1)
        col = mix.outputs[2]
    if strokes:
        uv2 = N("ShaderNodeUVMap"); uv2.uv_map = "st"; sep2 = N("ShaderNodeSeparateXYZ"); L(uv2.outputs[0], sep2.inputs[0])
        mask = stroke_mask(nt, sep2, strokes, 0.0055)
        mx = N("ShaderNodeMix"); mx.data_type = "RGBA"; mx.blend_type = "MIX"
        L(mask, mx.inputs[0]); L(col, mx.inputs[6]); mx.inputs[7].default_value = (*stroke_col, 1)
        col = mx.outputs[2]
    if gloss:
        uv3 = N("ShaderNodeUVMap"); uv3.uv_map = "st"; sep3 = N("ShaderNodeSeparateXYZ"); L(uv3.outputs[0], sep3.inputs[0])
        gm = gloss_mask(nt, sep3, gloss)
        gx = N("ShaderNodeMix"); gx.data_type = "RGBA"; gx.blend_type = "MIX"
        L(gm, gx.inputs[0]); L(col, gx.inputs[6]); gx.inputs[7].default_value = (*gloss_col, 1)
        col = gx.outputs[2]
    L(col, em.inputs[0]); L(em.outputs[0], outp.inputs[0])
    return m

def flat(name, rgb, cull=False):
    m = bpy.data.materials.new(name); m.use_nodes = True
    nt = m.node_tree; nt.nodes.clear()
    em = nt.nodes.new("ShaderNodeEmission"); em.inputs[0].default_value = (*rgb, 1)
    o = nt.nodes.new("ShaderNodeOutputMaterial"); nt.links.new(em.outputs[0], o.inputs[0])
    m.use_backface_culling = cull
    return m

def srgb(h):
    def ch(c):
        c /= 255
        return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4
    return (ch((h >> 16) & 255), ch((h >> 8) & 255), ch(h & 255))

RED, RED_SH, GLOSS = srgb(0xE8302A), srgb(0xA81B17), srgb(0xFFE9E4)
CREAM, CREAM_SH = srgb(0xF7F1DC), srgb(0xD8CBA2)
INK, INSIDE = srgb(0x121110), srgb(0x2A0D0C)
TONGUE, TONGUE_SH = srgb(0xC9443F), srgb(0x8E2724)
CHROME, CHROME_SH = srgb(0xD8DCE0), srgb(0x6E747B)

UP_STROKES = [(0.27, 0.16, 0.66, 0.14), (0.71, 0.18, 0.62, -0.14)]
LO_STROKES = [(0.30, 0.16, 0.74, -0.16), (0.46, 0.22, 0.80, -0.05), (0.66, 0.18, 0.72, 0.12)]
# Lips per look. Brightness here runs from 0.04 (facing away) to 0.29 (facing the sun).
UP_GLOSS = [(0.66, 0.20, 0.36, -1.4, 0.07), (0.62, 0.60, 0.72, -1.6, 0.06)]
LO_GLOSS = [(0.52, 0.34, 0.58, 1.2, 0.075), (0.48, 0.64, 0.70, 1.0, 0.05)]
if LOOK["lips"] == "v1":
    LIP = dict(shade=srgb(0x9E1D18), base=srgb(0xD3302A), light=srgb(0xE24438), cut1=0.24, cut2=0.47)
elif LOOK["lips"] in ("deep", "pop"):   # three bands that all show: shadow under the forms, base, a lit top
    LIP = dict(shade=srgb(0x8A1611), base=srgb(0xD9302A), light=srgb(0xF0563F), cut1=0.17, cut2=0.27)
else:                          # flat / gloss: the reference's flat red, a soft shadow only where it turns away
    LIP = dict(shade=srgb(0xB8241C), base=srgb(0xE8392B), light=srgb(0xE8392B), cut1=0.15, cut2=0.9)
GL = dict(gloss=None) if LOOK["lips"] not in ("gloss", "pop") else dict(gloss_col=srgb(0xFFF4EC))
m_lip_up = matte("LipUpper", LIP["shade"], LIP["base"], LIP["light"], LIP["cut1"], LIP["cut2"], band=0.13,
                 strokes=UP_STROKES, stroke_col=srgb(0x7A130F), **({**GL, "gloss": UP_GLOSS} if "gloss_col" in GL else {}))
m_lip = matte("LipLower", LIP["shade"], LIP["base"], LIP["light"], LIP["cut1"], LIP["cut2"], band=0.13,
              strokes=LO_STROKES, stroke_col=srgb(0x7A130F), **({**GL, "gloss": LO_GLOSS} if "gloss_col" in GL else {}))
m_tooth = toon("Tooth", CREAM, CREAM_SH, cut=0.10)
m_metal = matte("Gold", srgb(0xB3801F), srgb(0xEDBC3E), srgb(0xFFE38C), 0.10, 0.30)  # gold tooth, cel-shaded like the rest
m_tongue = toon("Tongue", TONGUE, TONGUE_SH, cut=0.38)
m_inside = flat("Inside", INSIDE)
m_ink = flat("Ink", INK, cull=True)
m_hold = bpy.data.materials.new("Skin"); m_hold.use_nodes = True
_nt = m_hold.node_tree; _nt.nodes.clear()
_nt.links.new(_nt.nodes.new("ShaderNodeHoldout").outputs[0], _nt.nodes.new("ShaderNodeOutputMaterial").inputs[0])

def outline(ob, thick, mats):
    for m in mats: ob.data.materials.append(m)
    ob.data.materials.append(m_ink)
    mod = ob.modifiers.new("Outline", "SOLIDIFY")
    mod.thickness = thick; mod.offset = 1.0; mod.use_flip_normals = True
    mod.use_rim = False; mod.material_offset = len(mats)

def outward(ob):
    bm = bmesh.new(); bm.from_mesh(ob.data)
    bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=1e-5)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    bm.to_mesh(ob.data); bm.free()
    for p in ob.data.polygons: p.use_smooth = True

# ---------- scene ----------
from mathutils import Matrix
for o in list(bpy.data.objects): bpy.data.objects.remove(o)
rig = bpy.data.objects.new("Mouth", None); bpy.context.collection.objects.link(rig)
rest = Curves(POSES[0])

def lens_mesh(name, upper):
    """The lip as one closed lens mesh at rest; returns the object and each vertex's s (0..1 along the lip)."""
    f0, b0 = lip_points(rest, upper)
    raw0 = lens_coords(f0, b0)
    n = (NS + 1) * (NT + 1)
    remap, uniq = [], []
    for i in range(len(raw0)):
        if i >= n:
            ii = i - n; si, tj = divmod(ii, NT + 1)
            if tj in (0, NT) or si in (0, NS):
                remap.append(remap[ii]); continue
        remap.append(len(uniq)); uniq.append(i)
    faces = [tuple(remap[a] for a in f) for f in grid_faces(NS, NT, 0) + grid_faces(NS, NT, n, flip=True)]
    faces = [f for f in faces if len(set(f)) == 4] + [f for f in faces if len(set(f)) == 3]
    me = bpy.data.meshes.new(name); me.from_pydata([raw0[i] for i in uniq], [], faces); me.update()
    st = []
    for i in uniq:
        ii = i if i < n else i - n
        si, tj = divmod(ii, NT + 1)
        st.append((si / NS, tj / NT if i < n else 0.5))
    uvl = me.uv_layers.new(name="st")
    for loop in me.loops: uvl.data[loop.index].uv = st[loop.vertex_index]
    ob = bpy.data.objects.new(name, me); bpy.context.collection.objects.link(ob)
    me.update()
    if sum(p.normal.y for p in list(me.polygons)[:NS * NT]) > 0:
        bm = bmesh.new(); bm.from_mesh(me); bmesh.ops.reverse_faces(bm, faces=bm.faces); bm.to_mesh(me); bm.free()
    for p in me.polygons: p.use_smooth = True
    ob.parent = rig
    tt = []
    for i in uniq:
        ii = i if i < n else i - n
        tt.append((ii % (NT + 1)) / NT)
    return ob, [s_ for s_, _ in st], tt

upper_lip, up_s, up_t = lens_mesh("UpperLip", True)
lower_lip, lo_s, lo_t = lens_mesh("LowerLip", False)
outline(upper_lip, LOOK["lip_ink"], [m_lip_up])
outline(lower_lip, LOOK["lip_ink"], [m_lip])
def ink_weights(ob, upper):
    vg = ob.vertex_groups.new(name="ink")
    xs = [v.co.x for v in ob.data.vertices]; lo, hi = min(xs), max(xs)
    for v in ob.data.vertices:
        s_ = (v.co.x - lo) / (hi - lo)
        if upper:
            wgt = 0.4 + 0.6 * max(math.exp(-((s_ - 0.30) / 0.14) ** 2), math.exp(-((s_ - 0.66) / 0.14) ** 2))
        else:
            wgt = 0.4 + 0.6 * math.sin(math.pi * s_) ** 1.6
        edge = min(s_, 1 - s_)
        wgt *= 0.45 + 0.55 * min(1.0, max(0.0, (edge - 0.012) / 0.05))   # thinner at the tips, never gone
        vg.add([v.index], wgt, "REPLACE")
    md = ob.modifiers["Outline"]; md.vertex_group = "ink"; md.thickness_vertex_group = 0.0
ink_weights(upper_lip, True); ink_weights(lower_lip, False)

cav = build_sheet("Inside", cavity_points(rest)); cav.parent = rig; cav.data.materials.append(m_inside)
skin_rows_up, skin_rows_lo = skin_points(rest, True), skin_points(rest, False)
skin_up = build_sheet("SkinUpper", skin_rows_up); skin_up.parent = rig; skin_up.data.materials.append(m_hold)
skin_lo = build_sheet("SkinLower", skin_rows_lo); skin_lo.parent = rig; skin_lo.data.materials.append(m_hold)

# ---------- the anatomy rig ----------
# After a real mouth filmed talking: the opening is a small lens that grows from the centre,
# the corners stay sealed, only the upper front teeth peek, the lower teeth hide behind a thick lower
# lip, the upper teeth are fixed to the skull, and the jaw hinges far back at upper-teeth height with
# small opens (a few degrees in speech, ~11 on a big "ah") and a slight forward slide.
HINGE = Vector((0.0, 3.4, 0.30))
JAW_MAX = math.radians(LOOK["jaw_deg"])
NODES = 8                                     # ring bones every 1/8 of the lip, corners shared
def rim(upper, s):
    x = -rest.w + 2 * rest.w * s
    return Vector((x, wrap(x), style(x, y_at(rest.up_in if upper else rest.lo_in, x), 0.0)))
def sm(e0, e1, v):
    u = min(1.0, max(0.0, (v - e0) / (e1 - e0))); return u * u * (3 - 2 * u)
def edge(upper, s):
    c = rest.corner; x = -c + 2 * c * s
    return Vector((x, wrap(x), style(x, y_at(rest.up_out if upper else rest.lo_out, x), 1.0)))
RING, S_OF = {}, {}
def add(name, p, s_): RING[name] = p; S_OF[name] = s_
add("c.L", rim(True, 0.0), 0.0); add("c.R", rim(True, 1.0), 1.0)
add("oc.L", edge(True, 0.0), 0.0); add("oc.R", edge(True, 1.0), 1.0)
for i in range(1, NODES):
    add(f"u{i}", rim(True, i / NODES), i / NODES); add(f"d{i}", rim(False, i / NODES), i / NODES)
    add(f"ou{i}", edge(True, i / NODES), i / NODES); add(f"od{i}", edge(False, i / NODES), i / NODES)
UP_IN = ["c.L"] + [f"u{i}" for i in range(1, NODES)] + ["c.R"]
LO_IN = ["c.L"] + [f"d{i}" for i in range(1, NODES)] + ["c.R"]
UP_OUT = ["oc.L"] + [f"ou{i}" for i in range(1, NODES)] + ["oc.R"]
LO_OUT = ["oc.L"] + [f"od{i}" for i in range(1, NODES)] + ["oc.R"]
def centre(s):                                # 0 at the corners .. 1 in the middle of the lip
    return sm(0.17, 0.5, min(s, 1 - s))
def ell(s, reach):                            # elliptical falloff from the centre (Rigify skin_jaw)
    xr = abs(2 * s - 1) / reach
    return math.sqrt(max(0.0, 1 - xr * xr))
# share of the jaw's rotation. Mouth edge: the lower lip ~72% at the centre on an elliptical lens
# that closes ~20% in from each corner (corners sealed); the upper lip barely follows. Lip edge:
# the lower lip's outer edge drops as a broad U with the chin; the upper lip's stays put.
FOLLOW = {}
for n, s_ in S_OF.items():
    if n in ("c.L", "c.R"): FOLLOW[n] = 0.06
    elif n in ("oc.L", "oc.R"): FOLLOW[n] = 0.16
    elif n.startswith("d"): FOLLOW[n] = 0.06 + LOOK["follow_lo"] * ell(s_, LOOK["follow_reach"]) ** 0.45   # broad and flat-topped: drops as one piece
    elif n.startswith("od"): FOLLOW[n] = LOOK["follow_od"][0] + LOOK["follow_od"][1] * ell(s_, 1.35) ** 0.4      # a flatter drop: a gentle curve, not a U
    elif n.startswith("ou"): FOLLOW[n] = 0.04
    else: FOLLOW[n] = 0.06 * (1 - ell(s_, 0.52))

arm_data = bpy.data.armatures.new("MouthRig"); arm = bpy.data.objects.new("MouthRig", arm_data)
bpy.context.collection.objects.link(arm); arm.parent = rig
bpy.context.view_layer.objects.active = arm
bpy.ops.object.mode_set(mode="EDIT")
eb = arm_data.edit_bones
root = eb.new("root"); root.head = (0, 0, 0); root.tail = (0, 0, 0.3)
jb = eb.new("jaw"); jb.head = HINGE; jb.tail = (0, 0.3, -0.7); jb.parent = root
for name, p in RING.items():
    b = eb.new(name); b.head = p; b.tail = p + Vector((0, -0.12, 0)); b.parent = root
bpy.ops.object.mode_set(mode="OBJECT")

KNOTS = [0, 0, 0, 0] + [i / (NODES - 2) for i in range(1, NODES - 2)] + [1, 1, 1, 1]
def bspline(s):
    """Clamped cubic B-spline basis over the 9 ring nodes: smooth, non-negative, sums to 1, exact at
    the corners (s = 0, 1)."""
    s = min(1.0 - 1e-9, max(0.0, s)); n = NODES + 1; K = KNOTS
    N_ = [1.0 if K[i] <= s < K[i + 1] else 0.0 for i in range(len(K) - 1)]
    for d in range(1, 4):
        N_ = [((s - K[i]) / (K[i + d] - K[i]) * N_[i] if K[i + d] > K[i] else 0.0) +
              ((K[i + d + 1] - s) / (K[i + d + 1] - K[i + 1]) * N_[i + 1] if K[i + d + 1] > K[i + 1] else 0.0)
              for i in range(len(K) - 1 - d)]
    return N_[:n]
def ring_w(inner, outer, s_, t_):
    b_ = bspline(s_); out = {}
    for nm, wv in zip(inner, b_): out[nm] = out.get(nm, 0.0) + wv * (1 - t_)
    for nm, wv in zip(outer, b_): out[nm] = out.get(nm, 0.0) + wv * t_
    return out
def lip_weights(ob, s_list, t_list, inner, outer):
    groups = {}
    for vi, (s_, t_) in enumerate(zip(s_list, t_list)):
        for nm, wv in ring_w(inner, outer, s_, t_).items():
            if wv < 1e-5: continue
            if nm not in groups: groups[nm] = ob.vertex_groups.new(name=nm)
            groups[nm].add([vi], wv, "REPLACE")
def skin_weights(ob, rows, inner, outer, upper, reach=0.5):
    groups = {}
    def g(n):
        if n not in groups: groups[n] = ob.vertex_groups.new(name=n)
        return groups[n]
    vi = 0
    for col in rows:
        x = col[0][0]; z0 = col[0][2]
        if abs(x) <= rest.w:
            s_ = (x + rest.w) / (2 * rest.w); xo = -rest.corner + 2 * rest.corner * s_
            thick = abs(style(xo, y_at(rest.up_out if upper else rest.lo_out, xo), 1.0) - z0) + 1e-3; d = 0.0
        else:
            s_ = 0.0 if x < 0 else 1.0; thick = 0.05; d = abs(x) - rest.w
        for j in range(len(col)):
            dz = abs(col[j][2] - z0)
            tt = min(1.0, dz / thick)                       # inside the lip's height: follow the lip
            fall = (1.0 if dz <= thick else math.exp(-((dz - thick) / (0.5 * reach)) ** 2)) * math.exp(-(d / 0.55) ** 2)
            for nm, wv in ring_w(inner, outer, s_, tt).items():
                if wv * fall > 1e-5: g(nm).add([vi], wv * fall, "REPLACE")
            g("root").add([vi], 1 - fall, "REPLACE"); vi += 1
def rigid(ob, bone):
    vg = ob.vertex_groups.new(name=bone); vg.add([v.index for v in ob.data.vertices], 1.0, "REPLACE")
def armature_first(ob):
    md = ob.modifiers.new("Rig", "ARMATURE"); md.object = arm
    ob.modifiers.move(len(ob.modifiers) - 1, 0)
lip_weights(upper_lip, up_s, up_t, UP_IN, UP_OUT); lip_weights(lower_lip, lo_s, lo_t, LO_IN, LO_OUT)
skin_weights(skin_up, skin_rows_up, UP_IN, UP_OUT, True); skin_weights(skin_lo, skin_rows_lo, LO_IN, LO_OUT, False, reach=0.85)
rigid(cav, "root")
for ob in (upper_lip, lower_lip, skin_up, skin_lo, cav): armature_first(ob)

# teeth, tucked: the upper front teeth's edges sit just below the lip line (they peek only when the
# lips part), the lower teeth stand behind the upper ones (overbite) and hide behind the lower lip
def tooth(name, x, z_top, width, height, tilt, depth_y, mat, upper=True):
    bpy.ops.mesh.primitive_cube_add(size=1)
    ob = bpy.context.active_object; ob.name = name
    ob.scale = (width, 0.12, height); bpy.ops.object.transform_apply(scale=True)
    for v in ob.data.vertices: v.co.z -= height * 0.5 if upper else -height * 0.5
    ob.location = (x, depth_y, z_top)
    ob.rotation_euler = (0, math.radians(tilt), math.atan(2 * WRAP * x) * 0.9)
    bpy.ops.object.transform_apply(location=True, rotation=True)
    bev = ob.modifiers.new("Round", "BEVEL"); bev.width = width * LOOK["teeth_round"]; bev.segments = 4; bev.limit_method = "NONE"
    ob.data.materials.append(mat); ob.data.materials.append(m_ink)
    sol = ob.modifiers.new("Outline", "SOLIDIFY"); sol.thickness = LOOK["tooth_ink"]; sol.offset = 1; sol.use_flip_normals = True
    sol.use_rim = False; sol.material_offset = 1
    ob.parent = rig
    return ob
upper_teeth, lower_teeth = [], []
LOW_Y = 0.43        # the lower row's depth: wholly behind the upper row and its ink, so the rows never cut into each other
if LOOK["teeth"] == "big":
    # big teeth with gaps between them, each outlined; front ones longest; one gold. The look sets how
    # crooked, round and spaced they are.
    K = LOOK; even = K["teeth_even"]
    widths = [0.55, 0.78, 1.02, 1.25, 1.18, 0.96, 0.75, 0.55] if not even else [0.7, 0.85, 1.0, 1.15, 1.15, 1.0, 0.85, 0.7]
    span = 1.95; tot = sum(widths); x = -span / 2
    tilts = [-6, 4, -3, 5, -4, 6, -5, 3]; drops = [-0.03, 0.01, 0.05, 0.08, 0.03, 0.06, 0.0, -0.03]
    if even: drops = [-0.02, 0.0, 0.02, 0.03, 0.03, 0.02, 0.0, -0.02]
    for i, wv in enumerate(widths):
        tw = span * wv / tot; cx = x + tw / 2
        t = tooth(f"UpperTooth{i}", cx, 0.38, tw * K["teeth_fill"], (0.58 + drops[i] - 0.14 * abs(cx)) * K["teeth_h"],
                  tilts[i] * K["teeth_tilt"], 0.27 + wrap(cx) * 0.92, m_metal if i == 5 else m_tooth, True)
        upper_teeth.append(t); x += tw
    lw = [0.62, 0.88, 1.06, 0.92, 1.1, 0.82, 0.6] if not even else [0.75, 0.9, 1.0, 1.05, 1.0, 0.9, 0.75]
    lspan = 1.6; ltot = sum(lw); x = -lspan / 2
    ltilt = [8, -6, 5, -9, 6, -5, 7]; ldrop = [-0.02, 0.03, -0.03, 0.04, 0.0, 0.03, -0.02]
    if even: ldrop = [0.0] * 7
    lpush = [0.0, -0.025, 0.02, -0.03, 0.025, -0.02, 0.0]          # crowded: some stand forward
    for i, wv in enumerate(lw):
        tw = lspan * wv / ltot; cx = x + tw / 2
        t = tooth(f"LowerTooth{i}", cx, -0.10, tw * K["teeth_fill"], (0.40 + ldrop[i] - 0.08 * abs(cx)) * K["teeth_h"], ltilt[i] * K["teeth_tilt"],
                  LOW_Y + wrap(cx) * 0.92 + lpush[i] * K["teeth_push"], m_tooth, False)
        lower_teeth.append(t); x += tw
else:
    widths = [0.8, 1.0, 1.15, 1.2, 0.95, 0.85]; span = 1.62; tot = sum(widths); x = -span / 2
    tilts = [-5, 3, -2, 4, -6, 3]; drops = [-0.02, 0.0, 0.06, 0.07, 0.0, -0.02]
    for i, wv in enumerate(widths):
        tw = span * wv / tot; cx = x + tw / 2
        # front teeth longest; the edge at about -0.08, side teeth shorter
        t = tooth(f"UpperTooth{i}", cx, 0.36, tw * 1.01, 0.44 + drops[i] - 0.06 * abs(cx), tilts[i], 0.27 + wrap(cx) * 0.92,
                  m_metal if i == 4 else m_tooth, True)
        upper_teeth.append(t); x += tw
    lw = [0.9, 1.1, 1.0, 1.15, 0.85]; lspan = 1.2; ltot = sum(lw); x = -lspan / 2
    ltilt = [6, -4, 3, -5, 4]; ldrop = [0.0, 0.02, -0.02, 0.01, 0.0]
    for i, wv in enumerate(lw):
        tw = lspan * wv / ltot; cx = x + tw / 2
        t = tooth(f"LowerTooth{i}", cx, -0.29, tw * 1.01, 0.36 + ldrop[i], ltilt[i], 0.34 + wrap(cx) * 0.92, m_tooth, False)
        lower_teeth.append(t); x += tw
def ink_shell(ob, mat, thick=0.03):
    ob.data.materials.append(mat); ob.data.materials.append(m_ink)
    sol = ob.modifiers.new("Outline", "SOLIDIFY"); sol.thickness = thick; sol.offset = 1; sol.use_flip_normals = True
    sol.use_rim = False; sol.material_offset = 1

# gums: a pink band under the lower teeth (it rides the jaw) and one over the upper teeth (fixed to the
# head), so a lip pulled off the teeth shows gum, never the empty inside
m_gum = toon("Gum", srgb(0xE9848C), srgb(0xB9545F), cut=0.12)
def gum_band(name, z_top, z_bot, y_front, depth, half_w):
    """A box bent round the face like the teeth, sitting just behind their front faces."""
    NX = 48; co, faces = [], []
    for i in range(NX + 1):
        x = -half_w + 2 * half_w * i / NX
        for yy, zz in ((y_front, z_top), (y_front + depth, z_top), (y_front + depth, z_bot), (y_front, z_bot)):
            co.append((x, yy + wrap(x) * 0.92, zz))
    for i in range(NX):
        a, b = 4 * i, 4 * (i + 1)
        faces += [(a + k, b + k, b + (k + 1) % 4, a + (k + 1) % 4) for k in range(4)]
    faces += [(0, 1, 2, 3), (4 * NX + 3, 4 * NX + 2, 4 * NX + 1, 4 * NX)]
    me = bpy.data.meshes.new(name); me.from_pydata(co, [], faces); me.update()
    ob = bpy.data.objects.new(name, me); bpy.context.collection.objects.link(ob)
    outward(ob); ink_shell(ob, m_gum); ob.parent = rig
    return ob
# a dark plate just behind the upper row: the gaps between teeth read as dark lines, and the lower
# teeth hide behind it where the rows overlap
teeth_back = build_sheet("TeethBack", [[(x, 0.355 + wrap(x) * 0.92, 0.40 - 0.53 * j / NT + 0.13 * abs(x)) for j in range(NT + 1)]
                                       for x in (-1.05 + 2.1 * i / 40 for i in range(41))])
teeth_back.parent = rig; teeth_back.data.materials.append(m_inside)
rigid(teeth_back, "root"); armature_first(teeth_back)
low_y = LOW_Y
gum_lower = gum_band("GumLower", -0.07, -0.75, low_y - 0.01, 0.06, 0.92)
gum_upper = gum_band("GumUpper", 0.95, 0.35, 0.26, 0.05, 1.1)

# the tongue: a broad pink mound behind the lower teeth, its top near their tips, with a dip at the
# middle of its top edge; on a big open it fills the bottom of the hole. Read from the reference
# video: a groove runs down its middle (a pressed-in crease and a fine darker line), its rounded tip
# catches the light and it darkens towards the back and the sides.
TONGUE_STROKES = [(0.25, 0.60, 0.93, 0.0)]          # the centre line, in the sphere's (u, v): u 0.25 faces the camera
m_tongue2 = matte("Tongue2", srgb(0xA8303A), srgb(0xF06A66), srgb(0xFF9C90), 0.12, 0.25,
                  strokes=TONGUE_STROKES, stroke_col=srgb(0xB3343C))
bpy.ops.mesh.primitive_uv_sphere_add(segments=32, ring_count=16, radius=1)
tongue = bpy.context.active_object; tongue.name = "Tongue"
tongue.data.uv_layers[0].name = "st"                 # the materials read their strokes from "st"
tongue.scale = (0.72, 0.06, 0.36); tongue.location = (0, 0.555, 0.10)
bpy.ops.object.transform_apply(location=True, scale=True)
for v in tongue.data.vertices:
    x, y, z = v.co.x, v.co.y, v.co.z
    if y < 0.555:                                                    # the front face: the groove down the middle
        v.co.y += 0.02 * math.exp(-(x / 0.06) ** 2) * min(1.0, max(0.0, (z + 0.1) / 0.3))
    v.co.y += wrap(x) * 0.8                                          # follow the curve of the face
    v.co.z -= 0.07 * math.exp(-(x / 0.10) ** 2) * max(0.0, z - 0.1) / 0.4
ink_shell(tongue, m_tongue2); tongue.parent = rig
for p in tongue.data.polygons: p.use_smooth = True
for ob in lower_teeth + [tongue, gum_lower]: rigid(ob, "jaw"); armature_first(ob)
rigid(gum_upper, "root"); armature_first(gum_upper)
for ob in upper_teeth: rigid(ob, "root"); armature_first(ob)       # fixed to the skull

# ---------- posing: anatomy channels -> bone targets ----------
def about(p, M): return Matrix.Translation(p) @ M @ Matrix.Translation(-p)
def hole(s):                                  # a narrow bump at the centre: a round hole, not a slit
    return ell(s, 0.24)
def hole_o(s):                                # the round hole of an O: the sides stay sealed
    return ell(s, 0.34)
JAW_LIMIT = 1.7                               # the jaw's full range: past the reader's loudest syllable (1.2), wide-open vowels
O_PUSH = 0.08                                 # how far an O pushes the lips forward
# the top front teeth's tips, the bottom front teeth's tips at rest and their distance from the hinge
UPPER_TOOTH_TIP, LOWER_TOOTH_TOP, LOWER_TOOTH_ARM = -0.17, 0.29, 2.95
def o_ring(s, outer, top, bot, tooth_top):
    """Where a lip point sits in an O (x, z): the lip edge on a round hole whose top lip just covers
    the top teeth's tips and whose bottom lip just covers the bottom teeth's (tooth_top, where the jaw
    has swung them), the outer edge on a ring round it. s runs corner to corner."""
    rz = max(0.03, 0.65 * (UPPER_TOOTH_TIP - tooth_top)); rx = 0.04 + 0.9 * rz
    zc = 0.5 * (UPPER_TOOTH_TIP + tooth_top)
    ex, ez = (rx + 0.45, rz + 0.32) if outer else (rx, rz)
    th = math.pi * (1 - s)
    sign = 1.0 if top else (-1.0 if bot else 0.0)
    return ex * math.cos(th), zc + sign * ez * math.sin(th)
def anat_targets(J=0.0, wide=0.0, pucker=0.0, funnel=0.0, part=0.0, close=0.0, slide=0.0, roll_u=0.0, roll_l=0.0,
                 smile=(0.0, 0.0), upper_up=(0.0, 0.0), lower_down=(0.0, 0.0), fv=0.0, shift=0.0):
    """(The app also lifts the tongue's tip for L/TH, on top of the jaw: MouthRig.tongueMatrix. The
    tongue stays rigid on the jaw here; no still uses the lift.)
    fv: F/V. The jaw nearly shut; the lower lip's centre rolls up and back and tucks under the
    upper front teeth, which rest on it; the upper lip lifts a little so those teeth show. The teeth
    never move for it: only the lips do."""
    J = J + 0.07 * fv * (1 - J)
    """Per-bone targets [angle, ox, oy, oz, sy, sz] plus the jaw. J 0..1.2 (1 = a big 'ah', ~11 deg).
    part: lips part over closed teeth (s, t, ee); close: lips seal over an open jaw (m, b, p)."""
    J = max(0.0, min(JAW_LIMIT, J))
    # slide: the jaw comes forward and down as it opens; shift: it moves a little to one side
    u_ = sm(0.25, 1.0, J); slideV = Vector((shift, -0.09 * slide * u_, -0.015 * slide * u_))
    tg = {"_jaw": (J, slideV)}
    drop_at = lambda f: 3.4 * math.sin(JAW_MAX * J * f)                  # how far a lip point drops
    for name, p in RING.items():
        s_ = S_OF[name]; c_ = centre(s_); cw = 1 - sm(0.0, 0.3, min(s_, 1 - s_))
        side = -1.0 if p.x < -1e-6 else (1.0 if p.x > 1e-6 else 0.0)
        si = 0 if side < 0 else 1
        outer = name.startswith("o"); nm_ = name[1:] if outer else name
        top = nm_.startswith("u"); bot = nm_.startswith("d")
        k_edge = 0.5 if outer else 1.0               # mouth-edge moves reach the lip edge at half
        sml = smile[si] if side else 0.5 * sum(smile)
        off = Vector((side * cw * (0.12 * wide + 0.10 * sml - 0.30 * pucker - 0.18 * funnel),
                      cw * (0.03 * wide - 0.08 * pucker - 0.04 * funnel) + c_ * (-0.12 * pucker - 0.07 * funnel),
                      cw * (0.03 * wide + 0.07 * sml)))
        off.y += wrap(p.x + off.x) - wrap(p.x)                          # corners slide along the face
        sy = 1 + 0.30 * pucker + 0.12 * funnel - 0.08 * wide
        sz = 1 + 0.20 * pucker + 0.10 * funnel - 0.15 * wide
        if top:
            uu = upper_up[si] if side else 0.5 * sum(upper_up)
            h_ = hole(s_)
            off.z += k_edge * (c_ * (LOOK["upper_lift"] * J + 0.05 * part + 0.07 * uu + 0.02 * wide)
                               + h_ * 0.05 * sm(0.4, 1.0, J)
                               + hole_o(s_) * (0.20 * pucker + 0.10 * funnel) * sm(0.05, 0.4, J))   # the O opens with the jaw
            off.z -= k_edge * c_ * 0.5 * close * drop_at(FOLLOW["d4"])      # meet the lower lip halfway
            off.y += 0.06 * roll_u * c_; sy -= 0.25 * roll_u * c_; sz -= 0.3 * roll_u * c_
            off.z += k_edge * 0.11 * fv * c_                               # F/V: lift to show the front teeth
            seal = min(1.0, pucker + funnel) * (1 - hole_o(s_))             # O: the sides close, the middle opens
            off.z -= k_edge * seal * 0.5 * drop_at(FOLLOW["d" + nm_[1:]])
        if bot:
            ld = lower_down[si] if side else 0.5 * sum(lower_down)
            # big opens: the lower lip's centre drops further, so the gap becomes a tall oval
            off.z -= k_edge * (c_ * (0.06 * part + 0.07 * ld) + (0.5 * c_ + 0.5 * cw) * 0.05 * wide
                               + hole_o(s_) * 0.03 * (funnel + pucker) * sm(0.05, 0.4, J)
                               + ell(s_, 0.5) ** 0.7 * LOOK["oval_drop"] * sm(0.4, 1.1, J) + c_ * 0.05 * sm(0.15, 0.8, J))
            off.z += k_edge * c_ * 0.5 * close * drop_at(FOLLOW[name])      # press up to seal
            seal = min(1.0, pucker + funnel) * (1 - hole_o(s_))
            off.z += k_edge * seal * 0.5 * drop_at(FOLLOW["d" + nm_[1:]])
            # the lower lip rolls out and fills as the jaw drops (volume): its outer edge leads
            rnd_ = pucker + funnel
            off.y -= (0.08 if outer else 0.04) * J * c_ + (0.07 if outer else 0.03) * rnd_ * c_
            if not outer: sy *= 1 + 0.25 * J * c_ + 0.15 * rnd_ * c_; sz *= 1 + 0.12 * J * c_ + 0.15 * rnd_ * c_
            off.y += 0.06 * roll_l * c_; sy -= 0.25 * roll_l * c_; sz -= 0.3 * roll_l * c_
            # F/V: the lower lip's mouth edge rolls up and back behind the upper teeth's front, pressed
            # flat where they rest on it; its outer edge follows a little
            f_ = fv * c_
            off.z += (0.0 if outer else 0.01) * f_
            off.y += (0.10 if outer else 0.32) * f_
            if not outer: sz *= 1 - 0.25 * f_; sy *= 1 - 0.3 * f_
        off += slideV * FOLLOW[name] / 0.72
        # an O, as a real mouth makes it: the lip edge settles onto a round hole and the outer edge onto
        # a ring around it, so the top lip covers the top teeth, the bottom lip rides up over the
        # bottom ones and the jaw opens a dark hole between them
        o_ = sm(0.0, 1.0, pucker)
        if o_ > 0:
            a_ = JAW_MAX * J * FOLLOW[name]
            ry, rz_ = p.y - HINGE.y, p.z - HINGE.z
            swung_z = math.sin(a_) * ry + math.cos(a_) * rz_ + HINGE.z
            rx_t, rz_t = o_ring(s_, outer, top, bot, LOWER_TOOTH_TOP - LOWER_TOOTH_ARM * math.sin(JAW_MAX * J))
            off.x += (rx_t - p.x - off.x) * o_
            off.z += (rz_t - swung_z - off.z) * o_
            off.y -= O_PUSH * o_ * c_
        if outer: sy, sz = 1.0, 1.0
        tg[name] = [JAW_MAX * J * FOLLOW[name], off.x, off.y, off.z, sy, sz]
    return tg

def apply_targets(tg, smear=None):
    J, slideV = tg["_jaw"]; pbs = arm.pose.bones; bones = arm.data.bones
    pbs["jaw"].matrix = Matrix.Translation(slideV) @ about(HINGE, Matrix.Rotation(JAW_MAX * J, 4, "X")) @ bones["jaw"].matrix_local
    for name, p in RING.items():
        ang, ox, oy, oz, sy, sz = tg[name]
        if smear and name in smear: st, sh = smear[name]; sz *= 1 + st; oz += sh
        S = about(p, Matrix.Diagonal((1.0, sy, sz, 1.0)))
        R = about(HINGE, Matrix.Rotation(ang, 4, "X"))
        pbs[name].matrix = Matrix.Translation(Vector((ox, oy, oz))) @ R @ S @ bones[name].matrix_local
    bpy.context.view_layer.update()

ARKIT_JAW_FULL = 0.32
def from_arkit(ch):
    g = lambda k: float(ch.get(k, 0.0))
    return anat_targets(J=g("jawOpen") / ARKIT_JAW_FULL, wide=min(1.0, g("mouthStretchL") + g("mouthStretchR")),
                        pucker=1.3 * max(0.0, g("mouthPucker") - 0.3), funnel=1.3 * max(0.0, g("mouthFunnel") - 0.3), close=g("mouthClose"),
                        slide=min(1.0, g("jawForward") / 0.5), roll_u=g("mouthRollUpper"), roll_l=g("mouthRollLower"),
                        smile=(g("mouthSmileL"), g("mouthSmileR")), upper_up=(g("mouthUpperUpL"), g("mouthUpperUpR")),
                        lower_down=(g("mouthLowerDownL"), g("mouthLowerDownR")),
                        fv=min(1.0, 2.0 * g("mouthRollLower") * (0.5 + (g("mouthUpperUpL") + g("mouthUpperUpR")) / 2)) * (1 - min(1.0, g("jawOpen") / 0.2)))
class SplitMix:
    """A small seeded random source, the same as SplitMix in Yapper/Mouth/MouthRig.swift."""
    M = (1 << 64) - 1
    def __init__(self, seed): self.state = seed
    def next(self):
        self.state = (self.state + 0x9E3779B97F4A7C15) & self.M
        z = self.state
        z = ((z ^ (z >> 30)) * 0xBF58476D1CE4E5B9) & self.M
        z = ((z ^ (z >> 27)) * 0x94D049BB133111EB) & self.M
        return z ^ (z >> 31)
    def uniform(self, a, b): return a + (b - a) * ((self.next() >> 11) / 9007199254740992.0)

IDLE_ACTIONS = ["press", "smirk", "click", "part", "purse"]
IDLE_SECONDS = {"press": 0.55, "smirk": 1.4, "click": 0.3, "part": 1.0, "purse": 0.9}
def idle_apply(name, k, side, kw):
    if name == "press": kw["roll_u"] = kw.get("roll_u", 0.0) + 0.6 * k; kw["roll_l"] = kw.get("roll_l", 0.0) + 0.6 * k; kw["J"] += 0.03 * k
    elif name == "smirk":
        one = (1.0, 0.0) if side == 0 else (0.0, 1.0)
        kw["smile"] = (kw["smile"][0] + 0.8 * k * one[0], kw["smile"][1] + 0.8 * k * one[1])
        kw["upper_up"] = (kw["upper_up"][0] + 0.25 * k * one[0], kw["upper_up"][1] + 0.25 * k * one[1])
    elif name == "click": kw["J"] += 0.18 * k; kw["part"] += 0.4 * k
    elif name == "part": kw["J"] += 0.08 * k; kw["part"] += 0.6 * k
    elif name == "purse": kw["pucker"] += 0.5 * k; kw["J"] += 0.03 * k

class Performer:
    """Acting on top of the lip-sync, the way an animator would: the syllable that lands pops the
    mouth a little further and lifts the upper lip off the teeth (a snarl, one side leading), the
    corners drift into a smirk, the jaw shifts sideways, fast opens stretch the mouth tall and fast
    closes squash it, and the head nods on accents. Each phrase picks its own lean, the head glances
    now and then, and in a pause the mouth breathes and does one small thing every few seconds.
    Keep in step with MouthPerformance in Yapper/Mouth/MouthRig.swift."""
    def __init__(self):
        self.t = 0.0; self.prevJ = 0.0; self.pop = 0.0
        self.sq = [0.0, 0.0]; self.nod = [0.0, 0.0]; self.tilt = [0.0, 0.0]
        self.rng = SplitMix(7)
        self.silent_for = 9.0; self.quiet = [1.0, 0.0]; self.was_speaking = False
        self.next_action = 1.5; self.action = None; self.action_t = 0.0; self.last_action = None; self.action_side = 0
        self.next_glance = 0.4; self.gaze = (0.0, 0.0); self.gyaw = [0.0, 0.0]; self.gpitch = [0.0, 0.0]
        self.lean = 0.0; self.lean_st = [0.0, 0.0]; self.flip = 1.0
    @staticmethod
    def wander(t, a, b, phase=0.0):            # smooth -1..1 drift from two unrelated slow waves
        return 0.6 * math.sin(2 * math.pi * a * t + phase) + 0.4 * math.sin(2 * math.pi * b * t + 1.7 * phase + 0.5)
    @staticmethod
    def spring(st, goal, f, z, dt):
        w0 = 2 * math.pi * f; h = dt / 4
        for _ in range(4):
            st[1] += (w0 * w0 * (goal - st[0]) - 2 * z * w0 * st[1]) * h; st[0] += st[1] * h
        return st[0]
    def step(self, J, W, T, dt):
        self.t += dt; t = self.t
        vJ = (J - self.prevJ) / dt; self.prevJ = J
        if vJ > 2.5 and J > 0.25: self.pop = max(self.pop, min(1.0, (vJ - 2.5) / 4))
        self.pop *= math.exp(-dt / 0.18)
        side = self.wander(t, 0.11, 0.27)
        smirk = self.wander(t, 0.07, 0.19, 2.0)
        snarl = min(1.0, 0.55 * J + 0.45 * self.pop)
        n, w = max(0.0, -W), max(0.0, W)
        kw = dict(J=min(1.05, J + 0.08 * self.pop),       # past ~1 the lower lip sags into a V
                  wide=w, pucker=n * (1 - 0.5 * J), funnel=n * min(1.0, J * 1.4),
                  part=T * (1 - J), slide=1.0,
                  upper_up=(snarl * (1 + 0.35 * side), snarl * (1 - 0.35 * side)),
                  lower_down=(0.2 * J * (1 - 0.25 * side), 0.2 * J * (1 + 0.25 * side)),
                  smile=(max(0.0, 0.12 + 0.18 * smirk) + 0.2 * w, max(0.0, 0.12 - 0.18 * smirk) + 0.2 * w),
                  shift=0.05 * side * min(1.0, J * 1.5))
        nod = self.spring(self.nod, 3.0 * self.pop - 1.0 * J, 2.2, 0.45, dt)
        tilt = self.spring(self.tilt, 2.5 * smirk + 2.0 * self.pop * side, 1.2, 0.6, dt)
        squash = self.spring(self.sq, max(-1.0, min(1.0, vJ / 10.0)) * 0.09, 3.5, 0.35, dt)
        # a pause: the voice has been quiet a moment
        speaking = J > 0.06
        self.silent_for = 0.0 if speaking else self.silent_for + dt
        q = min(1.0, max(0.0, self.spring(self.quiet, 1.0 if self.silent_for > 0.35 else 0.0, 10.0 if speaking else 6.0, 1.0, dt)))
        if speaking and not self.was_speaking:      # a new phrase picks its own lean
            if self.rng.uniform(0, 1) < 0.7: self.flip = -self.flip
            self.lean = self.flip * self.rng.uniform(0.4, 1.0)
        self.was_speaking = speaking
        lean = self.spring(self.lean_st, self.lean, 1.0, 0.8, dt)
        kw["smile"] = (kw["smile"][0] + 0.18 * max(0.0, lean), kw["smile"][1] + 0.18 * max(0.0, -lean))
        self.next_glance -= dt * (1.0 if q > 0.5 else 0.5)
        if self.next_glance <= 0:
            self.gaze = (self.rng.uniform(-6, 6), self.rng.uniform(-2, 2.5))
            self.next_glance = self.rng.uniform(3, 7)
        yaw = self.spring(self.gyaw, self.gaze[0], 3.5, 0.8, dt)
        pitch = self.spring(self.gpitch, self.gaze[1], 3.5, 0.8, dt)
        breath = math.sin(2 * math.pi * 0.22 * t)
        kw["J"] += q * 0.02 * (1 + breath)
        kw["part"] += q * 0.12 * max(0.0, breath)
        if q > 0.8 and self.action is None:
            self.next_action -= dt
            if self.next_action <= 0:
                choices = [a for a in IDLE_ACTIONS if a != self.last_action]
                self.action = choices[min(len(choices) - 1, int(self.rng.uniform(0, len(choices))))]
                self.last_action = self.action; self.action_t = 0.0
                self.action_side = 0 if self.rng.uniform(0, 1) < 0.5 else 1
        if self.action:
            self.action_t += dt
            u = min(1.0, max(0.0, self.action_t / IDLE_SECONDS[self.action]))
            idle_apply(self.action, math.sin(math.pi * u) ** 2 * q, self.action_side, kw)
            if self.action_t >= IDLE_SECONDS[self.action]: self.action = None; self.next_action = self.rng.uniform(2.5, 6.0)
        head = (0.6 * nod + pitch, 0.6 * tilt + 2.0 * lean, 1.2 * self.wander(t, 0.05, 0.13, 4.0) + yaw)
        return kw, head, squash

def from_voice(fr):
    J, W, T = fr["J"], fr["W"], fr.get("T", 0.0); n = max(0.0, -W)
    return anat_targets(J=J, wide=max(0.0, W), pucker=n * (1 - 0.5 * J), funnel=n * min(1.0, J * 1.4), part=T * (1 - J), slide=1.0)

BOARD = {"0213": {}, "0090": {"J": 0.62, "part": 0.15, "funnel": 0.15}, "0033": {"J": 0.2, "wide": 0.45, "part": 0.35},
         "0068": {"J": 0.08, "pucker": 0.75, "funnel": 0.25}, "0285": {"J": 0.28, "part": 0.1}, "0177": {"J": 0.12, "funnel": 0.6, "pucker": 0.5}}
# follow-through: each lip bone's spring (Hz, damping ratio); the teeth and jaw never spring
TUNE = {**{f"d{i}": (5.0, 0.62) for i in range(1, NODES)}, **{f"u{i}": (7.0, 0.68) for i in range(1, NODES)},
        **{f"od{i}": (4.5, 0.6) for i in range(1, NODES)}, **{f"ou{i}": (6.5, 0.65) for i in range(1, NODES)},
        "c.L": (11.0, 0.75), "c.R": (11.0, 0.75), "oc.L": (10.0, 0.7), "oc.R": (10.0, 0.7)}
STILLS = {"wide": {"J": 1.05, "upper_up": (0.6, 0.7), "lower_down": (0.2, 0.2), "slide": 1.0}, "snarl": {"J": 0.55, "part": 0.3, "upper_up": (0.8, 0.9), "lower_down": (0.5, 0.5)}, "fv": {"fv": 1.0}, "rest": {}, "half": {"J": 0.35}, "ah": {"J": 1.0}, "ee": {"J": 0.3, "wide": 0.9},
          "oo": {"J": 0.75, "pucker": 1.0, "funnel": 0.3}, "teeth": {"J": 0.02, "part": 1.0}, "mbp": {"J": 0.3, "close": 1.0}}

# ---------- camera, light ----------
rig.rotation_euler = (math.radians(LOOK["pitch"]), math.radians(LOOK["roll"]), math.radians(LOOK["yaw"]))
cam_data = bpy.data.cameras.new("Cam"); cam_data.type = "ORTHO"; cam_data.ortho_scale = 3.0
cam = bpy.data.objects.new("Cam", cam_data); bpy.context.collection.objects.link(cam)
cam.location = (0, -10, -0.12); cam.rotation_euler = (math.radians(90), 0, 0)
bpy.context.scene.camera = cam
sun_data = bpy.data.lights.new("Sun", "SUN"); sun_data.energy = 1.0; sun_data.use_shadow = False
sun = bpy.data.objects.new("Sun", sun_data); bpy.context.collection.objects.link(sun)
d = Vector((0.35, 0.8, -1.0)).normalized(); sun.rotation_euler = (-d).to_track_quat("Z", "Y").to_euler()
sc = bpy.context.scene
for eng in ("BLENDER_EEVEE", "BLENDER_EEVEE_NEXT"):
    try: sc.render.engine = eng; break
    except TypeError: pass
sc.render.film_transparent = True
sc.render.resolution_x, sc.render.resolution_y = 900, 640
sc.view_settings.view_transform = "Standard"
sc.world = bpy.data.worlds.new("W"); sc.world.color = (0, 0, 0)
try: sc.eevee.taa_render_samples = 16
except Exception: pass
def shoot(path):
    bpy.context.view_layer.update(); sc.render.filepath = path; bpy.ops.render.render(write_still=True)

# ---------- modes ----------
import json
opt = lambda k, dflt: next((a.split("=", 1)[1] for a in ARGS if a.startswith(k + "=")), dflt)
RES = opt("--res", "")                         # e.g. --res=320x200 (framing for the pill mockups)
if RES: sc.render.resolution_x, sc.render.resolution_y = map(int, RES.split("x"))
cam_data.ortho_scale = float(opt("--ortho", "3.0")); cam.location.z = float(opt("--camz", "-0.12"))
# ---------- export for the app ----------
def export(rig_path, fix_dir):
    """mouth.rig: 'MRIG', u32 version, u32 header length, the JSON header, then 4-byte aligned little-
    endian arrays the header points at. Positions are in the rig's space (the Mouth empty), Blender
    axes: x right, y into the screen, z up. fixtures: deformed vertices for each still, for the
    Swift parity test, plus reference renders."""
    import struct
    apply_targets(anat_targets())
    bones = ["root", "jaw"] + list(RING.keys())
    bix = {n: i for i, n in enumerate(bones)}
    blob = bytearray()
    def put(fmt, values):
        while len(blob) % 4: blob.append(0)
        off = len(blob); blob.extend(struct.pack("<%d%s" % (len(values), fmt), *values))
        return {"offset": off, "count": len(values)}

    def evaluated(ob, armature):
        saved = []
        for m in ob.modifiers:
            if m.type == "SOLIDIFY" or (m.type == "ARMATURE" and not armature):
                saved.append((m, m.show_viewport)); m.show_viewport = False
        bpy.context.view_layer.update()
        dg = bpy.context.evaluated_depsgraph_get()
        ev = ob.evaluated_get(dg); me = ev.to_mesh()
        return ev, me, saved
    def release(ev, saved):
        ev.to_mesh_clear()
        for m, v in saved: m.show_viewport = v

    def mat_info(m):
        if m.name == "Skin": return {"kind": "holdout"}
        nt = m.node_tree
        em = next(n for n in nt.nodes if n.type == "EMISSION")
        ramps = [n for n in nt.nodes if n.type == "VALTORGB"]
        if not ramps:
            c = em.inputs[0].default_value; return {"kind": "flat", "color": [c[0], c[1], c[2]]}
        els = ramps[0].color_ramp.elements
        info = {"kind": "cel", "bands": [{"at": e.position, "color": list(e.color[:3])} for e in els]}
        if m.name in ("LipUpper", "LipLower"):
            info["band"] = 0.13; info["bandTint"] = [0.58, 0.55, 0.55]
            info["strokes"] = [list(st) for st in (UP_STROKES if m.name == "LipUpper" else LO_STROKES)]
            info["strokeColor"] = list(srgb(0x7A130F)); info["strokeWidth"] = 0.0055
        if m.name == "Tongue2":
            info["strokes"] = [list(st) for st in TONGUE_STROKES]
            info["strokeColor"] = list(srgb(0xB3343C)); info["strokeWidth"] = 0.0055
        return info

    mats, mat_ix = [], {}
    def mat_id(m):
        if m.name not in mat_ix: mat_ix[m.name] = len(mats); mats.append({"name": m.name, **mat_info(m)})
        return mat_ix[m.name]

    def world_light():
        w = sc.world
        if w.use_nodes and w.node_tree:
            bg = next((n for n in w.node_tree.nodes if n.type == "BACKGROUND"), None)
            if bg and not bg.inputs[0].is_linked:
                c = bg.inputs[0].default_value; return float(bg.inputs[1].default_value) * (c[0] + c[1] + c[2]) / 3
        return float(sum(w.color) / 3)

    order = ["Inside", "SkinUpper", "SkinLower", "UpperLip", "LowerLip", "TeethBack"] + \
            [o.name for o in upper_teeth] + [o.name for o in lower_teeth] + ["GumUpper", "GumLower", "Tongue"]
    objects = []
    for name in order:
        ob = bpy.data.objects[name]
        groups = {g.index: g.name for g in ob.vertex_groups}
        bind = None
        skinned = name in ("UpperLip", "LowerLip", "SkinUpper", "SkinLower")
        if not skinned:
            bind = "jaw" if any(groups[g.group] == "jaw" for g in ob.data.vertices[0].groups) else "root"
        sol = ob.modifiers.get("Outline")
        ev, me, saved = evaluated(ob, armature=False)
        me.calc_loop_triangles()
        uv = me.uv_layers.get("st")
        vn = [v.normal.copy() for v in me.vertices]
        ink = [0.0] * len(me.vertices)
        if sol:
            if sol.vertex_group:
                gi = ob.vertex_groups[sol.vertex_group].index
                for v in ob.data.vertices:
                    ink[v.index] = next((g.weight for g in v.groups if g.group == gi), 0.0)
            else:
                ink = [1.0] * len(me.vertices)
        P, N, H, UV, W, IDX = [], [], [], [], [], []
        if skinned:                            # one vertex per mesh vertex: the app re-skins them
            for v in me.vertices:
                P += v.co[:]; N += vn[v.index][:]; H += vn[v.index][:]; W.append(ink[v.index])
            stv = [(0.0, 0.0)] * len(me.vertices)
            if uv:
                for l in me.loops: stv[l.vertex_index] = tuple(uv.data[l.index].uv)
            for a, b in stv: UV += [a, b]
            for t in me.loop_triangles: IDX += list(t.vertices)
            ws, wb, wv = [0], [], []
            for v in ob.data.vertices:
                for g in v.groups:
                    nm = groups[g.group]
                    if nm in bix and g.weight > 0: wb.append(bix[nm]); wv.append(g.weight)
                ws.append(len(wb))
        else:                                  # rigid: split per corner so flat faces stay flat
            cn = me.corner_normals
            for t in me.loop_triangles:
                for li, vi in zip(t.loops, t.vertices):
                    IDX.append(len(P) // 3)
                    P += me.vertices[vi].co[:]; N += cn[li].vector[:]; H += vn[vi][:]; W.append(ink[vi])
                    UV += list(uv.data[li].uv) if uv else [0.0, 0.0]
        smooth = all(p.use_smooth for p in ob.data.polygons)
        o = {"name": name, "material": mat_id(ob.data.materials[0]), "smooth": smooth,
             "vertexCount": len(P) // 3, "position": put("f", P), "normal": put("f", N),
             "hullNormal": put("f", H), "uv": put("f", UV), "ink": put("f", W), "index": put("I", IDX)}
        if skinned: o["weightStart"] = put("I", ws); o["weightBone"] = put("H", wb); o["weightValue"] = put("f", wv)
        else: o["bind"] = bind
        if sol: o["outline"] = {"thickness": sol.thickness, "material": mat_id(ob.data.materials[-1])}
        objects.append(o)
        release(ev, saved)

    header = {
        "version": 1,
        "bones": bones,
        "look": LOOK_NAME,
        "rig": {"hinge": list(HINGE), "jawMax": JAW_MAX, "nodes": NODES, "wrap": WRAP, "upperLift": LOOK["upper_lift"], "ovalDrop": LOOK["oval_drop"],
                "ring": {n: {"p": list(RING[n]), "s": S_OF[n], "follow": FOLLOW[n]} for n in RING},
                "upIn": UP_IN, "loIn": LO_IN, "upOut": UP_OUT, "loOut": LO_OUT,
                "tune": {n: list(v) for n, v in TUNE.items()}},
        # EEVEE's Diffuse BSDF (albedo 0.8) under a strength-1 sun gives 0.8/pi * N.L, plus the world's
        # uniform background light (Blender 5 gives a new world a 0.05 grey Background node).
        "view": {"rotationDeg": [LOOK["pitch"], LOOK["roll"], LOOK["yaw"]], "ortho": 3.0, "camZ": -0.12, "camY": -10.0,
                 "lightTowards": list((-d).normalized()), "diffuse": 0.8 / math.pi,
                 "ambient": 0.8 * world_light()},
        "materials": mats, "objects": objects,
    }
    hj = json.dumps(header, separators=(",", ":")).encode()
    hj += b" " * ((4 - len(hj) % 4) % 4)
    os.makedirs(os.path.dirname(os.path.abspath(rig_path)), exist_ok=True)
    with open(rig_path, "wb") as f:
        f.write(b"MRIG"); f.write(struct.pack("<II", 1, len(hj))); f.write(hj); f.write(blob)
    print("EXPORT", rig_path, len(hj) + len(blob), "bytes,", sum(o["vertexCount"] for o in objects), "vertices")

    if not fix_dir: return
    os.makedirs(fix_dir, exist_ok=True)
    skinned = ["UpperLip", "LowerLip", "SkinUpper", "SkinLower", "LowerTooth2"]
    STEP = 3
    fx = {"step": STEP, "poses": [], "objects": skinned}
    fblob = bytearray()
    apply_targets(anat_targets())
    ev, me, saved = evaluated(bpy.data.objects["LowerTooth2"], armature=False)
    rest = [c for v in list(me.vertices)[:24] for c in v.co[:]]
    fx["rigidRest"] = {"offset": len(fblob), "count": len(rest)}
    fblob.extend(struct.pack("<%df" % len(rest), *rest))
    release(ev, saved)
    for pose, kw in STILLS.items():
        apply_targets(anat_targets(**kw))
        entry = {"name": pose, "args": kw, "data": {}}
        for name in skinned:
            ob = bpy.data.objects[name]
            ev, me, saved = evaluated(ob, armature=True)
            if name == "LowerTooth2":          # rigid: compare its first few vertices
                co = [c for v in list(me.vertices)[:24] for c in v.co[:]]
            else:
                co = [c for v in list(me.vertices)[::STEP] for c in v.co[:]]
            entry["data"][name] = {"offset": len(fblob), "count": len(co)}
            fblob.extend(struct.pack("<%df" % len(co), *co))
            release(ev, saved)
        fx["poses"].append(entry)
    json.dump(fx, open(os.path.join(fix_dir, "poses.json"), "w"), indent=1)
    open(os.path.join(fix_dir, "poses.bin"), "wb").write(fblob)
    # reference renders at the test framing, for the renderer's golden check
    sc.render.resolution_x, sc.render.resolution_y = 320, 200
    cam_data.ortho_scale = 4.0; cam.location.z = -0.25
    rig.rotation_euler = (math.radians(LOOK["pitch"]), math.radians(LOOK["roll"]), math.radians(LOOK["yaw"]))
    for pose in ("rest", "ah", "ee", "oo", "fv", "snarl"):
        apply_targets(anat_targets(**STILLS[pose])); shoot(os.path.join(os.path.abspath(fix_dir), f"ref_{pose}.png"))
    apply_targets(anat_targets())
    print("FIXTURES", fix_dir)

if opt("--export", ""):
    export(opt("--export", ""), opt("--fixtures", ""))
    raise SystemExit
SPRING_K = float(opt("--spring", "0"))          # 0 = off, 1 = full follow-through, 0.5 = half
HEAD_SCALE = float(opt("--head", "0.5"))
ARKIT_JAW_FULL = float(opt("--jawfull", "0.32"))
if TRACK == "--board":
    rig.rotation_euler = (math.radians(4), 0, 0)
    for k, kw in BOARD.items():
        apply_targets(anat_targets(**kw)); shoot(os.path.join(out, f"board_{k}.png"))
    raise SystemExit
if TRACK is None and opt("--stills", ""):        # just these stills, e.g. --stills=rest,ee,ah,oo
    for name in opt("--stills", "").split(","):
        apply_targets(anat_targets(**STILLS[name])); shoot(os.path.join(out, f"pose_{name}.png"))
    raise SystemExit
if TRACK is None:
    for name, kw in STILLS.items():
        apply_targets(anat_targets(**kw)); shoot(os.path.join(out, f"pose_{name}.png"))
    base = rig.rotation_euler.copy(); rig.rotation_euler = (base.x, base.y, base.z - math.radians(60))
    for name in ("rest", "ah", "oo", "fv"):
        apply_targets(anat_targets(**STILLS[name])); shoot(os.path.join(out, f"side_{name}.png"))
    rig.rotation_euler = base
    bpy.ops.wm.save_as_mainfile(filepath=os.path.join(out, "mouth.blend"))
else:
    tr = json.load(open(TRACK)); fps = tr["fps"]; frs = tr["frames"]
    arkit = "--arkit" in ARGS
    pick = opt("--frames", "")                   # e.g. --frames=213,90,33 renders just those (front, no head)
    if pick:
        rig.rotation_euler = (math.radians(4), 0, 0)
        for k in [int(v) for v in pick.split(",")]:
            apply_targets(from_arkit(frs[k]) if arkit else from_voice(frs[k])); shoot(os.path.join(out, f"pick_{k:04d}.png"))
        raise SystemExit
    state, prevJ = {}, 0.0
    ONLY = int(opt("--only", "0"))               # render just this frame (springs still run up to it)
    if "--hide-lips" in ARGS:                    # teeth-only check: hide the lips, skin and inside
        for nm in ("UpperLip", "LowerLip", "SkinUpper", "SkinLower", "Inside"): bpy.data.objects[nm].hide_render = True
    perf = Performer() if "--perform" in ARGS else None
    for i, fr in enumerate(frs, start=1):
        sc.frame_set(i)
        if perf:
            kw, head, squash = perf.step(fr["J"], fr["W"], fr.get("T", 0.0), 1.0 / fps)
            tg = anat_targets(**kw)
        else:
            tg = from_arkit(fr) if arkit else from_voice(fr)
        smear = None
        if SPRING_K > 0:
            for n, (f, z) in TUNE.items():
                w0 = 2 * math.pi * f; k, c = w0 * w0, 2 * z * w0; h = 1.0 / fps / 4
                st = state.setdefault(n, [[v, 0.0] for v in tg[n]])
                for ci, v in enumerate(tg[n]):
                    x_, v_ = st[ci]
                    for _ in range(4): v_ += (k * (v - x_) - c * v_) * h; x_ += v_ * h
                    st[ci] = [x_, v_]
                    tg[n][ci] = v + SPRING_K * (x_ - v)               # keep only part of the lag/overshoot
            Jn = tg["_jaw"][0]; vJ = (Jn - prevJ) * fps; prevJ = Jn
            amt = SPRING_K * max(0.0, min(1.0, (abs(vJ) - 4.0) / 4.0))
            if amt > 0:
                sg = 1.0 if vJ > 0 else -1.0
                smear = {n: (0.4 * amt * centre(S_OF[n]), 0.05 * amt * sg * centre(S_OF[n])) for n in RING if n.startswith("d") or n.startswith("od")}
        apply_targets(tg, smear=smear)
        if perf:
            rig.rotation_euler = (math.radians(LOOK["pitch"] + head[0]), math.radians(LOOK["roll"] + head[1]),
                                  math.radians(LOOK["yaw"] + head[2]))
            rig.scale = (1 - 0.5 * squash, 1.0, 1 + squash)
        elif arkit:
            rig.rotation_euler = (math.radians(6 + HEAD_SCALE * fr.get("headPitch", 0.0)),
                                  math.radians(HEAD_SCALE * fr.get("headRoll", 0.0)), math.radians(HEAD_SCALE * fr.get("headYaw", 0.0)))
        else:
            rig.rotation_euler = (math.radians(LOOK["pitch"] + fr.get("head", 0.0)), 0,
                                  math.radians(LOOK["yaw"] + 2.0 * math.sin(i / fps * 0.7)))
        if ONLY and i != ONLY: continue
        shoot(os.path.join(out, f"f_{i:04d}.png"))
        if ONLY: break
print("DONE", out)
