"""Generates the package icon (imgs/dart_smb2.png) and the README
diagrams in imgs/diagrams, as PNG only, in the style of mpv_audio_kit's.

The branding is flat colors: the icon's navy plate with a white glyph, and
light blue for your code in the diagrams.
Library nodes take the navy and your code's nodes the light blue. The
PNGs are transparent, so they sit on the page's own ground: text inside a
node relies on the node's fill, and the free text, arrows and bands use mid
tones that read on white and on GitHub's dark ground alike. The SVGs are
drawn in a temporary directory and exported at 2x with rsvg-convert.

Every free label is checked to keep at least CLEARANCE px from the arrows,
the nodes and the other labels (an estimate of the text's box from its
font size); the script fails and names the label when one comes closer.

Run from the repository root: python3 tool/diagrams/generate.py
"""
import math, os, re, subprocess, sys, tempfile

OUT = os.path.join('imgs', 'diagrams')
ICON = os.path.join('imgs', 'dart_smb2.png')
NAVY = '#0D2A75'
LIGHT_BLUE = '#A8EDFA'
# The icon's glyph: white on the navy disc. The diagrams keep the light
# blue, which also reads on a light page, where white would vanish.
GLYPH = '#FFFFFF'
SANS = "Noto Sans, system-ui, -apple-system, Segoe UI, sans-serif"
MONO = "Noto Sans Mono, ui-monospace, SFMono-Regular, Menlo, monospace"
CLEARANCE = 9

PAL = {
    # ink: text inside neutral nodes, on their own fill. label, muted, line,
    # main, fail and band sit on the page ground, light or dark.
    'light': dict(ink='#1F2328', label='#6B7689', muted='#6B7689', line='#7D8796', main='#2F6FD6',
                  fail='#D1392B', failSoft='#FDE3E0', neutral='#E6EBF3', band='#7D8796'),
}


def esc(t):
    return t.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')


class D:
    def __init__(self, name, w, h, theme, label):
        self.name, self.w, self.h, self.t, self.c = name, w, h, theme, PAL[theme]
        self.label = label
        self.body = []
        # For the clearance check: free labels, node boxes, arrow polylines.
        self.labels, self.boxes, self.paths = [], [], []

    def add(self, s):
        self.body.append(s)

    def svg(self):
        c = self.c
        defs = f'''<defs>
{''.join(f'<marker id="m{n}" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="10" markerHeight="10" markerUnits="userSpaceOnUse" orient="auto-start-reverse"><path d="M0,0 L10,5 L0,10 z" fill="{col}"/></marker>' for n, col in (('main', c['main']), ('sec', c['line']), ('fail', c['fail'])))}
</defs>'''
        return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {self.w} {self.h}" width="{self.w}" height="{self.h}" '
                f'role="img" aria-label="{esc(self.label)}">\n{defs}\n' + '\n'.join(self.body) + '\n</svg>\n')

    # role: lib (navy), app (light blue), neutral, fail, ghost (dimmed text)
    def node(self, x, y, w, h, title, sub=None, role='lib', mono=True, r=None, sub2=None, size=15):
        c = self.c
        r = 10 if r is None else r
        if role == 'lib':
            fill, tc, sc = NAVY, '#FFFFFF', '#C9DBFF'
        elif role == 'app':
            fill, tc, sc = LIGHT_BLUE, NAVY, '#1D3F7E'
        elif role == 'fail':
            fill, tc, sc = c['failSoft'], '#B42318', '#59636E'
        elif role == 'ghost':
            fill, tc, sc = c['neutral'], '#59636E', '#59636E'
        else:
            fill, tc, sc = c['neutral'], c['ink'], '#59636E'
        self.add(f'<rect x="{x - w / 2}" y="{y - h / 2}" width="{w}" height="{h}" rx="{r}" fill="{fill}"/>')
        self.boxes.append((x - w / 2, y - h / 2, x + w / 2, y + h / 2, title))
        lines = [s for s in (sub, sub2) if s]
        ty = y + 5 - 9 * len(lines)
        self.add(f'<text x="{x}" y="{ty}" text-anchor="middle" font-family="{MONO if mono else SANS}" font-size="{size}" font-weight="600" fill="{tc}">{esc(title)}</text>')
        for i, s in enumerate(lines):
            self.add(f'<text x="{x}" y="{ty + 19 + 16 * i}" text-anchor="middle" font-family="{SANS}" font-size="12" fill="{sc}">{esc(s)}</text>')

    def arrow(self, d, kind='main', dash=False, head=True, width=None):
        c = self.c
        col = {'main': c['main'], 'sec': c['line'], 'fail': c['fail']}[kind]
        w = width or (2.2 if kind == 'main' else 1.7)
        dsh = ' stroke-dasharray="5 5"' if dash else ''
        mk = f' marker-end="url(#m{kind})"' if head else ''
        self.add(f'<path d="{d}" fill="none" stroke="{col}" stroke-width="{w}"{dsh}{mk}/>')
        self.paths.append([tuple(map(float, p)) for p in re.findall(r'[ML]\s*(-?[\d.]+)\s*,\s*(-?[\d.]+)', d)])

    def lifeline(self, x, y0, y1):
        self.add(f'<line x1="{x}" y1="{y0}" x2="{x}" y2="{y1}" stroke="{self.c["line"]}" stroke-width="1.2" stroke-dasharray="4 5"/>')
        self.paths.append([(float(x), float(y0)), (float(x), float(y1))])

    def text(self, x, y, t, anchor='middle', color='muted', size=12, mono=False, weight=400, free=True):
        col = self.c.get(color, color)
        self.add(f'<text x="{x}" y="{y}" text-anchor="{anchor}" font-family="{MONO if mono else SANS}" font-size="{size}" font-weight="{weight}" fill="{col}">{esc(t)}</text>')
        if free:
            w = len(t) * size * (0.6 if mono else 0.54)
            x0 = {'middle': x - w / 2, 'start': x, 'end': x - w}[anchor]
            self.labels.append((x0, y - size * 0.78, x0 + w, y + size * 0.22, t))

    def band(self, x, y, w, h, title):
        self.add(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="14" fill="{self.c["band"]}" fill-opacity="0.12"/>')
        if title:
            self.text(x + 16, y + 24, title, anchor='start', color='muted', size=12, weight=600)

    def check(self):
        """The labels closer than CLEARANCE to an arrow, a node or another
        label, as messages."""
        problems = []

        def box_gap(a, b):
            dx = max(b[0] - a[2], a[0] - b[2], 0)
            dy = max(b[1] - a[3], a[1] - b[3], 0)
            return math.hypot(dx, dy)

        def seg_gap(b, p, q):
            # Distance from a box to a segment: sample the segment densely.
            n = max(2, int(math.dist(p, q) / 2))
            best = float('inf')
            for i in range(n + 1):
                x = p[0] + (q[0] - p[0]) * i / n
                y = p[1] + (q[1] - p[1]) * i / n
                best = min(best, box_gap(b, (x, y, x, y)))
            return best

        for i, l in enumerate(self.labels):
            for b in self.boxes:
                if box_gap(l, b) < CLEARANCE:
                    problems.append(f'{self.name}: "{l[4]}" is {box_gap(l, b):.1f} px from node "{b[4]}"')
            for path in self.paths:
                for p, q in zip(path, path[1:]):
                    g = seg_gap(l, p, q)
                    if g < CLEARANCE:
                        problems.append(f'{self.name}: "{l[4]}" is {g:.1f} px from the arrow {p}->{q}')
                        break
            for m in self.labels[i + 1:]:
                if box_gap(l, m) < CLEARANCE:
                    problems.append(f'{self.name}: "{l[4]}" is {box_gap(l, m):.1f} px from "{m[4]}"')
        return problems


def architecture(t):
    d = D('architecture', 900, 560, t, 'Architecture: your code, the pool, its worker isolates and the server')
    d.band(20, 20, 860, 130, 'Your app, any isolate (the UI one included)')
    d.node(200, 95, 260, 60, 'Your code', 'widgets, services', role='app', mono=False)
    d.node(640, 95, 300, 60, 'Smb2Pool', 'async, least busy worker first', role='lib')
    d.arrow('M330,95 L488,95'); d.text(409, 82, 'calls', size=11)
    d.band(20, 185, 860, 240, 'Worker isolates')
    for i, x in enumerate((180, 450, 720)):
        d.node(x, 265, 220, 60, f'worker {i + 1}', 'Smb2Client, sync', role='lib')
        d.node(x, 365, 220, 56, 'libsmb2', 'code asset from the hook', role='neutral', mono=False)
        d.arrow(f'M{x},295 L{x},335', kind='sec')
    d.arrow('M640,125 L640,160 L180,160 L180,233')
    d.arrow('M450,160 L450,233'); d.arrow('M640,160 L720,160 L720,233')
    d.text(462, 205, 'requests by id', anchor='start', size=11)
    d.node(450, 505, 300, 56, 'SMB server', 'Samba, Windows, a NAS', role='neutral', mono=False)
    for x in (180, 450, 720):
        d.arrow(f'M{x},393 L{x},440 L450,440 L450,475' if x != 450 else 'M450,393 L450,475', kind='sec')
    d.text(462, 460, 'SMB2/3', anchor='start', size=11)
    return d


def pool_lifecycle(t):
    d = D('pool_lifecycle', 1150, 150, t, 'Pool lifecycle')
    steps = [('Smb2Pool.connect()', 'workers in parallel', 'lib'), ('calls', 'list, read, write, stat', 'app'),
             ('withFile / streamFile', 'handles closed for you', 'app'), ('Smb2CancelToken', "a page's calls", 'app'),
             ('disconnect()', 'logoff, isolates end', 'lib')]
    for i, (a, b, role) in enumerate(steps):
        x = 115 + i * 230
        d.node(x, 75, 200, 64, a, b, role=role, size=14)
        if i:
            d.arrow(f'M{x - 230 + 100},75 L{x - 102},75')
    return d


def reconnect(t):
    d = D('reconnect', 900, 470, t, 'A network failure: one reconnect, then the call again')
    cols = [(130, 'Your code', 'app'), (380, 'Smb2Pool', 'lib'), (620, 'worker', 'lib'), (800, 'new worker', 'lib')]
    for x, n, role in cols:
        d.node(x, 45, 150, 50, n, role=role, mono=n != 'Your code')
        d.lifeline(x, 72, 410)
    steps = [(130, 380, 110, 'stat(path)', 'main'), (380, 620, 150, 'request', 'main'),
             (620, 380, 190, 'connection lost', 'fail'), (380, 800, 230, 'spawn, connect', 'main'),
             (800, 380, 270, 'ready', 'sec'), (380, 800, 310, 'stat again', 'main'),
             (800, 380, 350, 'result', 'sec'), (380, 130, 390, 'Smb2Stat', 'sec')]
    for a, b, y, label, kind in steps:
        d.arrow(f'M{a},{y} L{b + (8 if b < a else -8)},{y}', kind=kind)
        lx = (a + b) / 2 if abs(b - a) < 300 else (min(a, b) + 500) / 2 + 60
        d.text(lx, y - 12, label, mono='(' in label, color='label', size=12)
    d.text(450, 440, 'mkdir, rmdir, deleteFile, rename: reconnect, but no second try', size=12)
    return d


def streaming(t):
    d = D('streaming', 900, 330, t, 'streamFile and downloadToFile: one chunk ahead, a part file renamed at the end')
    d.band(20, 20, 860, 120, 'Worker')
    for i, (x, lab) in enumerate(((170, 'chunk 1'), (390, 'chunk 2'), (610, 'chunk 3'), (800, '...'))):
        d.node(x, 85, 170 if i < 3 else 90, 54, lab, 'read' if i < 3 else None, role='lib' if i < 3 else 'ghost', mono=False, size=14)
    d.band(20, 175, 860, 135, 'Your isolate')
    for i, (x, lab) in enumerate(((280, 'chunk 1'), (500, 'chunk 2'), (720, 'chunk 3'))):
        d.node(x, 240, 170, 54, lab, 'written to .part', role='app', mono=False, size=14)
    for a, b in ((170, 280), (390, 500), (610, 720)):
        d.arrow(f'M{a},112 L{a},150 L{b},150 L{b},211', kind='sec')
    d.text(280, 290, 'the next read runs while this chunk is written', size=11)
    d.text(720, 290, 'then rename to the destination', size=11)
    return d


def hook(t):
    d = D('hook', 900, 300, t, 'The build hook bundles libsmb2 for the target')
    d.node(150, 80, 230, 60, 'libsmb2-r9 release', 'one binary per target', role='neutral', mono=False)
    d.node(150, 220, 230, 60, 'hooks.user_defines', 'a local build instead', role='app')
    d.node(450, 150, 230, 64, 'hook/build.dart', 'SHA-256 checked', role='lib')
    d.node(750, 150, 230, 64, 'libdart_smb2', 'code asset in the app', role='lib')
    d.arrow('M265,80 L320,80 L320,135 L333,135'); d.arrow('M265,220 L320,220 L320,165 L333,165', kind='sec')
    d.arrow('M565,150 L633,150'); d.text(599, 137, 'bundle', size=11)
    d.text(450, 210, 'Android, iOS, Linux, macOS, Windows', size=11)
    return d


def icon_svg():
    """The package icon: an S drawn as two opposite arrows, white on a full
    navy disc.

    The glyph is 600 px tall, the height of mpv_audio_kit's tallest bar
    (0.86 x 700 = 602). It is symmetric under a half turn around its own
    origin, so it is centred by putting that point on the disc's centre:
    the point every rotation-symmetric shape balances on, which neither the
    bounding box nor the ink's weight can pull off-centre for this shape.
    The script checks it on the PNG (see check_icon)."""
    s = ('M-180,-250 L190,-250 L190,-300 L290,-200 L190,-100 L190,-150 L-130,-150 L-130,-50 '
         'L180,-50 A50,50 0 0 1 230,0 L230,200 A50,50 0 0 1 180,250 '
         'L-190,250 L-190,300 L-290,200 L-190,100 L-190,150 L130,150 L130,50 '
         'L-180,50 A50,50 0 0 1 -230,0 L-230,-200 A50,50 0 0 1 -180,-250 Z')
    return ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024" '
            'role="img" aria-label="dart_smb2">\n'
            f'<circle cx="512" cy="512" r="512" fill="{NAVY}"/>\n'
            f'<path transform="translate(512 512)" d="{s}" fill="{GLYPH}"/>\n</svg>\n')


def check_icon(png):
    """The white glyph's box on the PNG: its centre on the disc's and its
    height, and the glyph unchanged by a half turn."""
    import zlib, struct
    data = open(png, 'rb').read()
    w, h = struct.unpack('>II', data[16:24])
    idat, pos = b'', 8
    while pos < len(data):
        ln, = struct.unpack('>I', data[pos:pos + 4]); kind = data[pos + 4:pos + 8]
        if kind == b'IDAT':
            idat += data[pos + 8:pos + 8 + ln]
        pos += 12 + ln
    raw, bpp = zlib.decompress(idat), 4
    rows, prev, stride = [], bytearray(w * bpp), w * bpp
    for y in range(h):
        f, line = raw[y * (stride + 1)], bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        for i in range(stride):
            a = line[i - bpp] if i >= bpp else 0
            b, c = prev[i], prev[i - bpp] if i >= bpp else 0
            if f == 1: line[i] = (line[i] + a) & 255
            elif f == 2: line[i] = (line[i] + b) & 255
            elif f == 3: line[i] = (line[i] + (a + b) // 2) & 255
            elif f == 4:
                p = a + b - c; pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                line[i] = (line[i] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        rows.append(line); prev = line
    white = [[rows[y][x * 4] > 128 and rows[y][x * 4 + 2] > 128 and rows[y][x * 4 + 3] > 128 for x in range(w)] for y in range(h)]
    ys = [y for y in range(h) if any(white[y])]
    xs = [x for x in range(w) if any(white[y][x] for y in ys)]
    cx, cy = (xs[0] + xs[-1] + 1) / 2, (ys[0] + ys[-1] + 1) / 2
    area = sum(map(sum, white))
    asym = sum(white[y][x] != white[h - 1 - y][w - 1 - x] for y in range(h) for x in range(w))
    return cx, cy, ys[-1] - ys[0] + 1, asym, area


ALL = [architecture, pool_lifecycle, reconnect, streaming, hook]

problems = []
os.makedirs(OUT, exist_ok=True)
with tempfile.TemporaryDirectory() as tmp:
    for f in ALL:
        d = f('light')
        problems += d.check()
        svg = os.path.join(tmp, f'{d.name}.svg')
        with open(svg, 'w') as fh:
            fh.write(d.svg())
        png = os.path.join(OUT, f'{d.name}.png')
        subprocess.run(['rsvg-convert', '-z', '2', svg, '-o', png], check=True)
    svg = os.path.join(tmp, 'icon.svg')
    with open(svg, 'w') as fh:
        fh.write(icon_svg())
    subprocess.run(['rsvg-convert', svg, '-o', ICON], check=True)
cx, cy, height, asym, area = check_icon(ICON)
print(f'Icon {ICON}: glyph box centre ({cx}, {cy}), {height} px tall, '
      f'{asym} of {area} glyph px differ under a half turn')
# Only edge pixels may differ: the antialiasing of the arcs is not exactly
# symmetric. 0.3% of the glyph's area allows that and nothing more.
if abs(cx - 512) > 1 or abs(cy - 512) > 1 or abs(height - 600) > 2 or asym > area * 0.003:
    problems.append('icon: the glyph is not centred, 600 px tall and half-turn symmetric')
if problems:
    print('\n'.join(problems), file=sys.stderr)
    sys.exit(1)
print('Icon written to', ICON, 'and', len(ALL), 'diagrams to', OUT,
      f'(every label at least {CLEARANCE} px clear)')
