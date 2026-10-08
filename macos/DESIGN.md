# Design

## Visual theme
Warm graphite and paper neutrals with a single copper accent, like a darkroom: the color of a photo developing, not of a tech brand. Restrained strategy: the accent marks the primary action, the selection and progress only. Follows the system appearance (light and dark).

## Colors (OKLCH)
| Role | Light | Dark |
|---|---|---|
| canvas | 0.985 0.004 75 | 0.195 0.006 60 |
| panel | 0.965 0.005 75 | 0.230 0.007 60 |
| hairline | 0.900 0.007 75 | 0.330 0.008 60 |
| ink | 0.240 0.012 60 | 0.940 0.007 75 |
| ink secondary | 0.500 0.014 60 | 0.720 0.010 70 |
| accent (copper) | 0.560 0.115 48 | 0.720 0.105 55 |
| accent soft | 0.930 0.030 55 | 0.300 0.040 50 |
| success (sage) | 0.550 0.080 150 | 0.720 0.080 150 |
| warning (amber) | 0.620 0.120 75 | 0.780 0.110 80 |
| danger (brick) | 0.530 0.150 28 | 0.700 0.130 30 |

## Typography
SF Pro only. Titles 20/semibold, section labels 11/semibold uppercase with 0.6 tracking, body 13, secondary 11. Numbers always monospaced digits. No rounded or display faces.

## Components
- Sections: label + content on the canvas, separated by hairlines. Panels (8 pt radius, hairline border, no shadow) only for groups the user acts on.
- Choice rows: radio style rows with a copper check, never tinted tiles.
- Primary button: solid copper, standard macOS proportions. Secondary: native bordered.
- Progress: a 6 pt track with copper fill and one line of text, no rings, no hero numbers.
- Icons: SF Symbols in ink secondary; copper only when selected.

## Motion
150 to 200 ms ease-out for state changes. No decorative motion.
