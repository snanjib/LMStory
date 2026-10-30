# 概念图 Prompt 清单（WS1 P1）

> 用途：本文为概念图生成 prompt 清单，供视觉设计复现使用。各条 prompt 按
> 「酒红玻璃风格」基准方向改写，防翻车要点已内置在每条 prompt 的 AVOID 段。

## 使用约定

1. **投喂**：英文版效果普遍更好，优先投英文；即梦/可灵等用中文版。
   每次投喂一条，不要合并。
2. **评审口径**：只投票「氛围对不对」，忽略文字乱码与假 UI；
   概念图**不作实现依据**，工程数值以
   `doc/design/v0.4.0/外观体系v2设计.md` 为准。
3. **产出命名**（存本目录，竖屏 1024×1536 或模型默认手机比例）：
   - `night-chat.png` —— 夜间 · 故事会话页
   - `night-settings.png` —— 夜间 · 设置页
   - `day-a-gallery.png` —— 日间 A 清晨画廊白墙
   - `day-b-vino.png` —— 日间 B 午后果酒
   - `day-c-cellar.png` —— 日间 C 石灰酒窖
4. **重点核对**（对应设计文档 §2.9）：无紫色；渐变只在背景一处；最亮元素是
   白色药丸（日间三张改为：最深的元素是酒红药丸）；正文区无磨砂玻璃；
   每屏只有一处霓虹/glow；卡片无发光；对比度不被"高级感"牺牲。

---

## 1. 夜间 · 故事会话页 → `night-chat.png`

```text
Premium mobile app UI concept, dark cinematic "Bordeaux" night theme for a
story-reading app. Portrait phone screen, full-bleed.

COLOR: deep wine gradient background — near-black plum #150C13 flowing into a
burgundy glow #5C1F38 from the lower-left corner, subtle vignette; the content
column sits away from the glowing corner. Hue locked to wine red; strictly NO
purple, NO violet, NO blue. One neon pink accent #FF4F6E used only for the
streaming caret, a focus ring and a tiny brand mark. The brightest element on
screen is a solid white pill "send" button with a near-black wine-tinted label.

MATERIAL: a large opaque dark-plum reading card (#221420, ~24px radius) holds
the story prose, occupying most of the screen — absolutely no blur or glass
over the text. Assistant message cards are translucent white at 6% fill with a
1px top-lit inner hairline highlight, lit from above, never outlined; the user
reply is translucent white at 10%. One small floating action bar above the
keyboard is frosted glass. Soft long shadows, no hard borders.

GEOMETRY: continuous large corner radii — pill-shaped controls, cards ~24px,
inputs ~14px. Everything soft, nothing angular.

TYPE: rounded sans-serif prose, generous line height; small technical
monospace uppercase labels with wide tracking separated by "//" (e.g.
"CHAPTER 03 // NIGHTFALL"); monospace numbers. No other decorative type.

MOOD: wine lounge at night, a single warm light across the room; restrained
and precise — 90% discipline, 10% drama.

AVOID: purple gradients, rainbow accents, gradient text, glassmorphism or
blur over body text, low-contrast gray on dark, glowing cards, cluttered
neon, more than four corner radii.
```

```text
高级感手机应用 UI 概念图，深夜酒馆气质的"波尔多酒红"夜间主题，故事阅读类工具。
竖屏手机整屏。背景：深酒红渐变——近黑梅子色 #150C13 向左下角的酒红光晕 #5C1F38
过渡，带轻微暗角；内容列避开发光角。色相严格锁定酒红-粉红区间，禁止紫色、紫罗兰、
蓝色。唯一强调色霓虹粉 #FF4F6E 只用于流式光标、焦点环和小品牌标。屏幕上最亮的元素
是实心白色药丸"发送"按钮，配近黑深酒红文字。材质：一块大的不透明深梅色阅读卡
（#221420，约 24px 圆角）承载故事正文，占据屏幕大部分——正文上绝对没有玻璃和模糊。
助手消息卡是 6% 半透明白、顶部 1px 内侧高光，像被上方灯光打亮；用户回复是 10% 半透明白。
键盘上方一条小的悬浮操作条是磨砂玻璃。柔和长阴影，无硬描边。几何：连续大圆角——
控件一律药丸形，卡片约 24px，输入框约 14px。字体：正文圆润无衬线、行距宽松；辅以
等宽字体全大写宽字距的技术小标签，用"//"分隔（如"CHAPTER 03 // NIGHTFALL"）；
数字用等宽。无其他装饰字。氛围：深夜酒馆雅座，全屋一盏暖光；克制、精密，
90% 纪律 + 10% 戏剧。禁止：紫色渐变、彩虹配色、渐变文字、正文区玻璃模糊、
深底低对比灰字、发光卡片、霓虹堆料、超过四种圆角。
```

## 2. 夜间 · 设置页 → `night-settings.png`

```text
Premium mobile app UI concept, dark cinematic "Bordeaux" night theme, settings
screen of a story-reading app. Portrait phone screen.

COLOR: same deep wine gradient background #150C13 with a burgundy glow #5C1F38
in the lower-left, subtle vignette. Hue locked to wine red; strictly NO purple,
NO violet, NO blue. Neon pink accent #FF4F6E only on an active toggle and a
focus ring. The brightest element is one solid white pill button ("done") with
a near-black wine-tinted label.

MATERIAL: hierarchy through translucent white tiers — setting rows are
transparent, hover-dark groups sit in translucent white 6% panels with a 1px
top-lit inner hairline highlight; one selected row glows faint white at 16%.
A small modal sheet at the bottom third is frosted glass over the list. Soft
long shadows, no hard borders.

GEOMETRY: pill toggles and segmented controls, panels ~24px radius, small
version badge with ~8px radius.

TYPE: clean rounded sans-serif labels; monospace uppercase technical captions
with wide tracking separated by "//" (e.g. "MEMORY // 12 ENTRIES",
"VERSION 0.4.0"); monospace numbers everywhere.

MOOD: precise, orderly, near-monochrome; the discipline is the luxury.

AVOID: purple gradients, rainbow accents, gradient text, blur over list text,
low-contrast gray on dark, glowing cards, more than four corner radii.
```

```text
高级感手机应用 UI 概念图，深夜酒馆气质的"波尔多酒红"夜间主题，故事阅读类工具的
设置页。竖屏整屏。背景：同一深酒红渐变 #150C13，左下酒红光晕 #5C1F38，轻微暗角；
色相锁定酒红，禁止紫色、蓝色。霓虹粉 #FF4F6E 只出现在一个开启状态的开关和焦点环上。
屏幕最亮元素是一颗实心白药丸按钮（"完成"），配近黑深酒红字。材质：层级用半透明白
台阶表达——设置行透明，分组坐在 6% 半透明白面板里、顶部 1px 内侧高光；一行选中态
泛 16% 白。屏幕下三分之一的模态小面板是磨砂玻璃盖在列表上。柔和长阴影，无硬描边。
几何：开关和分段控件都是药丸形，面板约 24px 圆角，小版本徽标约 8px 圆角。字体：
干净的圆润无衬线标签；等宽字体全大写宽字距技术小字，用"//"分隔（如
"MEMORY // 12 ENTRIES"、"VERSION 0.4.0"）；数字一律等宽。氛围：精密、秩序、
近乎单色——纪律本身就是奢侈感。禁止：紫色渐变、彩虹配色、渐变文字、列表文字上的
模糊、深底低对比灰字、发光卡片、超过四种圆角。
```

## 3. 日间 A · 清晨画廊白墙 → `day-a-gallery.png`

```text
Premium mobile app UI concept, light "gallery white wall" Bordeaux day theme
for a story-reading app. Portrait phone screen.

COLOR: light warm-gray gallery background #F5F2F3, near-invisible rose glow
#E9D9DE in one lower corner. Wine red is the INK, not the background: prose
and headings in deep bordeaux #3A222C-#8C2440 tones. The DARKEST element on
screen is a solid wine-red pill button #8C2440 with a warm near-white label
#FFF5F8. One dusty rose accent #B3325A used sparingly. Strictly NO purple,
NO violet, NO blue, NO cream-yellow.

MATERIAL: crisp white opaque cards (#FFFFFF, ~24px radius) with soft daylight
shadows — like framed works on a gallery wall; a translucent white 50% panel
slides over the list; selected row tinted blush. Absolutely no blur or glass
over body text.

GEOMETRY: pill-shaped controls, cards ~24px, inputs ~14px, small badges ~8px.

TYPE: rounded sans-serif prose in wine ink; small monospace uppercase labels
with wide tracking separated by "//"; monospace numbers.

MOOD: morning gallery with white walls; quiet, editorial, the wine label is
the only color in the room.

AVOID: purple, rainbow accents, gradient text, blur over body text, heavy
saturated backgrounds, cluttered decoration, more than four corner radii.
```

```text
高级感手机应用 UI 概念图，浅色"清晨画廊白墙"波尔多日间主题，故事阅读类工具。
竖屏整屏。颜色：浅暖灰画廊背景 #F5F2F3，下角一抹几乎看不见的玫瑰晕 #E9D9DE。
酒红是"墨"，不是背景：正文与标题用深酒红 #3A222C-#8C2440 系。屏幕上最深的元素
是实心酒红药丸按钮 #8C2440，配暖白标签 #FFF5F8。灰玫瑰强调色 #B3325A 少量使用。
严格禁止紫色、紫罗兰、蓝色、奶黄色。材质：干脆的白色不透明卡片（#FFFFFF，约 24px
圆角）配柔和日光阴影——像画廊白墙上的装框作品；一块 50% 半透明白面板滑在列表上方；
选中行带酒晕浅色。正文上绝对没有玻璃和模糊。几何：控件一律药丸形，卡片约 24px，
输入框约 14px，小徽标约 8px。字体：酒红墨水的圆润无衬线正文；等宽全大写宽字距
"//"技术小标签；数字等宽。氛围：清晨的画廊白墙，安静、编辑感，酒标是房间里
唯一的颜色。禁止：紫色、彩虹配色、渐变文字、正文区模糊、高饱和背景、装饰堆料、
超过四种圆角。
```

## 4. 日间 B · 午后果酒 → `day-b-vino.png`

```text
Premium mobile app UI concept, light "afternoon vino" Bordeaux day theme for
a story-reading app. Portrait phone screen.

COLOR: warm ivory tablecloth background #F7F4EE; the wine lives in ONE place —
a soft rosé gradient glow #E7CBD3 blooming from the lower-left corner, like
light through a glass of vinho. Ink in warm dark plum #35272B. The DARKEST
element is a solid wine pill button #7E2440 with an ivory label #FFF6F0.
Dusty rose accent #A63A58 sparingly. Strictly NO purple, NO blue.

MATERIAL: white opaque cards (#FFFFFF, ~24px radius) resting softly on the
ivory cloth, gentle shadows; a translucent white 50% sheet over the list;
blush-tinted selected state. No blur or glass over body text.

GEOMETRY: pill controls, cards ~24px, inputs ~14px.

TYPE: rounded sans-serif prose; monospace uppercase "//" tracked labels;
monospace numbers.

MOOD: afternoon on the veranda, a glass of vinho on an ivory tablecloth —
relaxed, warm, the wine never leaves the glass.

AVOID: purple, rainbow accents, gradient text, blur over body text, toast-brown
or cream-yellow drift, cluttered neon, more than four corner radii.
```

```text
高级感手机应用 UI 概念图，浅色"午后果酒"波尔多日间主题，故事阅读类工具。竖屏整屏。
颜色：暖米白桌布背景 #F7F4EE；酒色只活在一处——左下角泛起的玫瑰果酒渐变光晕
#E7CBD3，像光线穿过一杯果酒。墨色是暖深梅 #35272B。屏幕最深元素是实心酒红药丸
按钮 #7E2440，配米白标签 #FFF6F0。灰玫瑰强调 #A63A58 少量。严格禁止紫色、蓝色。
材质：白色不透明卡片（#FFFFFF，约 24px 圆角）轻放在米白桌布上，阴影柔和；
列表上一张 50% 半透明白薄板；选中态带酒晕。正文上无玻璃无模糊。几何：药丸控件、
卡片约 24px、输入框约 14px。字体：圆润无衬线正文；等宽大写"//"宽字距标签；
数字等宽。氛围：午后的廊下，米白桌布上放着一杯果酒——松弛、温暖，酒不洒出杯子。
禁止：紫色、彩虹配色、渐变文字、正文模糊、烤棕或奶黄跑偏、霓虹堆料、超过四种圆角。
```

## 5. 日间 C · 石灰酒窖 → `day-c-cellar.png`

```text
Premium mobile app UI concept, light "limestone cellar" Bordeaux day theme
for a story-reading app. Portrait phone screen.

COLOR: cool pale stone-gray background #F3F1F4, faint mauve glow #DFD3DC in
one corner, like skylight on cellar limestone. Near-black plum ink #2B2028;
the wine appears as STAINS on surfaces: elevated and selected cards carry a
blush tint #F8F1F5, primary pill in wine #93264B with a pure white label.
Dusty rose accent #AB3355 sparingly. Strictly NO blue, NO violet saturation.

MATERIAL: cool white opaque cards with crisp soft shadows, slight blush-tinted
elevation tiers; translucent white 50% panel; selected surfaces carry the wine
stain. No blur or glass over body text.

GEOMETRY: pill controls, cards ~24px, inputs ~14px.

TYPE: rounded sans-serif prose; monospace uppercase "//" tracked labels;
monospace numbers.

MOOD: a wine cellar's limestone wall lit by a skylight — the stone is cool
and gray, the wine stain is the only warmth.

AVOID: blue or violet cast, purple gradients, rainbow accents, gradient text,
blur over body text, warm cream drift, more than four corner radii.
```

```text
高级感手机应用 UI 概念图，浅色"石灰酒窖"波尔多日间主题，故事阅读类工具。竖屏整屏。
颜色：冷调浅石灰墙灰背景 #F3F1F4，一角淡淡的灰紫酒晕 #DFD3DC，像天窗照在酒窖
石灰墙上。近黑梅子墨色 #2B2028；酒红以"渍"的方式出现在表面上：浮起与选中的卡片
带酒晕浅色 #F8F1F5，主操作是酒红药丸 #93264B 配纯白标签。灰玫瑰强调 #AB3355 少量。
严格禁止蓝色、饱和紫色。材质：冷白不透明卡片配干脆柔和的阴影，浮起层带轻微酒晕；
50% 半透明白面板；选中表面带酒渍色。正文上无玻璃无模糊。几何：药丸控件、卡片
约 24px、输入框约 14px。字体：圆润无衬线正文；等宽大写"//"宽字距标签；数字等宽。
氛围：天窗照亮酒窖石灰墙——石头是冷灰的，酒渍是唯一的暖色。禁止：蓝色或紫色倾向、
紫色渐变、彩虹配色、渐变文字、正文模糊、暖奶油跑偏、超过四种圆角。
```

---

*清单对应《外观体系v2设计》§三 三方向与 §二 夜间定稿；若补生成，产出文件名见「使用约定 3」。*
