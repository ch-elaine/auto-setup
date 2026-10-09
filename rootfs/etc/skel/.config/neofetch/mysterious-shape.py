from random import random, randrange, shuffle

def hue(p, q, t):
  t %= 1.0
  if t < 1/6: return p + (q - p) * 6 * t
  if t < 1/2: return q
  if t < 2/3: return p + (q - p) * (2/3 - t) * 6
  return p

def hsl_to_rgb(h, s, l):
  h, s, l = h % 1.0, max(0, min(1, s)), max(0, min(1, l))
  if s == 0:
    r = g = b = l
  else:
    q = l * (1 + s) if l < 0.5 else l + s - l * s
    p = 2 * l - q
  r = hue(p, q, h + 1/3)
  g = hue(p, q, h)
  b = hue(p, q, h - 1/3)

  return tuple(round(c * 255) for c in (r, g, b))

def color(hue):
  return hsl_to_rgb(hue, 1.0, 0.55)

def color_match(hue1, hue2):
  a = abs(hue1 - hue2)
  return min(a, 1 - a)

DIRS = (
  (0, -1), (1, -1), (1, 0), (1, 1), (0, 1), (-1, 1), (-1, 0), (-1, -1)
)

BOX = 30
CHANCE = 0.5
DEVI = 0.01
WRITE = 1

BONUS_COEXIST = 0.2
BONUS_DESTROY = 0.9
BONUS_SAME = 0.6

# cell:
#   HSL color (hue variable)
#   color to coexist
#   color to destroy
#
# score = 0
# score += bonus_destroy * match(destroy, neighbour)
# score -= bonus_coexist * match(coexist, neighbour)
# score -= bonus_same * match(own, neighbour)

def score(cell, neigh):
  h, c, d = cell
  v = neigh[0]

  score = (0
    + BONUS_DESTROY * color_match(d, v)
    - BONUS_COEXIST * color_match(c, v)
    - BONUS_SAME * color_match(h, v)
  )

  return score

def random_cell():
  return tuple(random() for _ in range(3))

def mutate_nonwrap(value):
  hi = min(1.0, value + DEVI)
  lo = hi - 2 * DEVI
  return random() * (hi - lo) + lo

def mutate_color(hue):
  return (hue + 2 * random() * DEVI - DEVI) % 1.0

def mutate_cell(cell):
  h, c, d = cell
  return (
    mutate_color(h) if random() < CHANCE else h,
    mutate_color(c) if random() < CHANCE else c,
    mutate_color(d) if random() < CHANCE else d
  )

field = [[random_cell() for _ in range(BOX)] for _ in range(BOX)]

def check(y, x):
  x = (2 * x / BOX - 1) / 0.7
  y = (1 - 2 * y / BOX) / 0.7 + 0.15
  return (x*x + y*y - 1)**3 - x*x*y**3 <= 0

def pref(y, x):
  return randrange(5, 8) if not check(y, x) else randrange(0, 3)

try:
  print("\x1b[H\x1b[2J\x1b[3J\n\n\n\x1b[s")

  while True:
    overwrites = [[None for _ in range(BOX)] for _ in range(BOX)]
    order = [*range(BOX ** 2)]
    shuffle(order)

    for i in order:
      y, x = divmod(i, BOX)
      cell = field[y][x]
      if random() >= WRITE: continue
      scores = []
      dirs = [*DIRS]
      shuffle(dirs)
      for dy, dx in dirs:
        ny, nx = (y + dy) % BOX, (x + dx) % BOX
        neigh = field[ny][nx]
        scores.append((score(cell, neigh), (ny, nx)))
      scores.sort(key=lambda s: s[0], reverse=True)
      fy, fx = scores[pref(y, x)][1]

      overwrites[fy][fx] = mutate_cell(cell)

    text = ""
    for y in range(BOX):
      for x in range(BOX):
        ow = overwrites[y][x]
        if ow is not None:
          field[y][x] = ow
        r, g, b = color(field[y][x][0])
        text += f"\x1b[48;2;{r};{g};{b}m  "
      text += "\n"
    print("\x1b[?25l\x1b[u" + text + "\x1b[?25h")
except KeyboardInterrupt:
  print("\x1b[0m\x1b[H\x1b[2J\x1b[3J\n\n\x1b[?25h")
