#!/usr/bin/env python3
from __future__ import annotations

import math
import random
import subprocess
from dataclasses import dataclass
from pathlib import Path

import cv2
import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont


ROOT = Path(__file__).resolve().parents[1]
OUT_DIR = ROOT / "marketing" / "videos"
DEMO_VIDEO = ROOT / "docs" / "assets" / "demo.mp4"
APP_ICON = ROOT / "docs" / "assets" / "app-icon.png"
FORTUNE_STICK = ROOT / "docs" / "assets" / "fortune-stick.png"
FORTUNE_JAR = (
    ROOT
    / "Huge cursor"
    / "Shake Cursor"
    / "Assets.xcassets"
    / "fortune-jar.imageset"
    / "fortune-jar.png"
)

FONT_REGULAR = "/System/Library/Fonts/STHeiti Light.ttc"
FONT_SERIF = "/System/Library/Fonts/Supplemental/Songti.ttc"


@dataclass(frozen=True)
class Size:
    width: int
    height: int


def font(size: int, serif: bool = False) -> ImageFont.FreeTypeFont:
    return ImageFont.truetype(FONT_SERIF if serif else FONT_REGULAR, size=size)


def ease(x: float) -> float:
    x = max(0.0, min(1.0, x))
    return x * x * (3 - 2 * x)


def clamp(value: float, lower: float = 0.0, upper: float = 1.0) -> float:
    return max(lower, min(upper, value))


def rgba(hex_color: str, alpha: int = 255) -> tuple[int, int, int, int]:
    value = hex_color.lstrip("#")
    return (int(value[0:2], 16), int(value[2:4], 16), int(value[4:6], 16), alpha)


def rounded_rect_layer(
    size: tuple[int, int],
    radius: int,
    fill: tuple[int, int, int, int],
    outline: tuple[int, int, int, int] | None = None,
    width: int = 1,
) -> Image.Image:
    layer = Image.new("RGBA", size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    box = (width // 2, width // 2, size[0] - width // 2 - 1, size[1] - width // 2 - 1)
    draw.rounded_rectangle(box, radius=radius, fill=fill, outline=outline, width=width)
    return layer


def paste_alpha(base: Image.Image, overlay: Image.Image, xy: tuple[int, int], opacity: float = 1.0) -> None:
    if opacity <= 0:
        return
    if opacity < 1:
        overlay = overlay.copy()
        alpha = overlay.getchannel("A").point(lambda p: int(p * opacity))
        overlay.putalpha(alpha)
    base.alpha_composite(overlay, xy)


def fit_image(img: Image.Image, box: tuple[int, int], cover: bool = False) -> Image.Image:
    source = img.convert("RGBA")
    scale = max(box[0] / source.width, box[1] / source.height) if cover else min(box[0] / source.width, box[1] / source.height)
    resized = source.resize((int(source.width * scale), int(source.height * scale)), Image.Resampling.LANCZOS)
    if not cover:
        return resized
    left = max(0, (resized.width - box[0]) // 2)
    top = max(0, (resized.height - box[1]) // 2)
    return resized.crop((left, top, left + box[0], top + box[1]))


def fit_video_frame(frame: np.ndarray, box: tuple[int, int], cover: bool = False) -> Image.Image:
    rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
    return fit_image(Image.fromarray(rgb), box, cover=cover)


def draw_text(
    image: Image.Image,
    xy: tuple[int, int],
    text: str,
    size: int,
    color: tuple[int, int, int, int] = (255, 255, 255, 255),
    serif: bool = False,
    anchor: str = "la",
    spacing: int = 12,
    align: str = "left",
) -> None:
    draw = ImageDraw.Draw(image)
    draw.multiline_text(xy, text, fill=color, font=font(size, serif), anchor=anchor, spacing=spacing, align=align)


def draw_wrapped_text(
    image: Image.Image,
    xy: tuple[int, int],
    text: str,
    size: int,
    max_width: int,
    color: tuple[int, int, int, int] = (255, 255, 255, 255),
    serif: bool = False,
    spacing: int = 12,
) -> None:
    f = font(size, serif)
    draw = ImageDraw.Draw(image)
    lines: list[str] = []
    current = ""
    for char in text:
        candidate = current + char
        if draw.textbbox((0, 0), candidate, font=f)[2] <= max_width or not current:
            current = candidate
        else:
            lines.append(current)
            current = char
    if current:
        lines.append(current)
    draw.multiline_text(xy, "\n".join(lines), fill=color, font=f, spacing=spacing)


def make_gradient(size: Size, light: bool = False) -> Image.Image:
    w, h = size.width, size.height
    y = np.linspace(0, 1, h)[:, None]
    x = np.linspace(0, 1, w)[None, :]
    if light:
        r = 242 + 10 * (1 - y) + 5 * np.sin(x * math.pi)
        g = 244 + 8 * (1 - y)
        b = 253 + 12 * x
    else:
        r = 16 + 24 * x + 18 * (1 - y)
        g = 14 + 18 * y + 8 * np.sin(x * math.pi)
        b = 34 + 72 * x + 44 * (1 - y)
    r = np.broadcast_to(r, (h, w))
    g = np.broadcast_to(g, (h, w))
    b = np.broadcast_to(b, (h, w))
    arr = np.dstack([r.clip(0, 255), g.clip(0, 255), b.clip(0, 255)]).astype(np.uint8)
    img = Image.fromarray(arr, "RGB").convert("RGBA")
    glow = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    gd.ellipse((int(w * 0.45), int(h * -0.15), int(w * 1.18), int(h * 0.45)), fill=(142, 106, 255, 48))
    gd.ellipse((int(w * -0.2), int(h * 0.50), int(w * 0.6), int(h * 1.2)), fill=(80, 216, 255, 30))
    return Image.alpha_composite(img, glow.filter(ImageFilter.GaussianBlur(72)))


def make_video_reader(path: Path) -> tuple[cv2.VideoCapture, float, int]:
    cap = cv2.VideoCapture(str(path))
    if not cap.isOpened():
        raise RuntimeError(f"Cannot open video: {path}")
    fps = cap.get(cv2.CAP_PROP_FPS) or 30
    frames = int(cap.get(cv2.CAP_PROP_FRAME_COUNT) or 0)
    return cap, fps, frames


def demo_frame_at(cap: cv2.VideoCapture, fps: float, second: float) -> np.ndarray:
    cap.set(cv2.CAP_PROP_POS_FRAMES, int(second * fps))
    ok, frame = cap.read()
    if not ok:
        cap.set(cv2.CAP_PROP_POS_FRAMES, 0)
        ok, frame = cap.read()
    if not ok:
        raise RuntimeError("Cannot read demo frame")
    return frame


def write_mp4(path: Path, size: Size, fps: int, frames) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    cmd = [
        "ffmpeg",
        "-y",
        "-hide_banner",
        "-loglevel",
        "error",
        "-f",
        "rawvideo",
        "-pix_fmt",
        "rgb24",
        "-s",
        f"{size.width}x{size.height}",
        "-r",
        str(fps),
        "-i",
        "-",
        "-an",
        "-c:v",
        "libx264",
        "-profile:v",
        "high",
        "-crf",
        "18",
        "-preset",
        "medium",
        "-pix_fmt",
        "yuv420p",
        "-movflags",
        "+faststart",
        str(path),
    ]
    proc = subprocess.Popen(cmd, stdin=subprocess.PIPE)
    assert proc.stdin is not None
    try:
        for frame in frames:
            proc.stdin.write(frame.convert("RGB").tobytes())
    finally:
        proc.stdin.close()
    if proc.wait() != 0:
        raise RuntimeError(f"ffmpeg failed for {path}")


def make_twinkles(count: int, area: tuple[int, int, int, int], seed: int) -> list[tuple[float, float, float, float]]:
    rnd = random.Random(seed)
    x0, y0, x1, y1 = area
    return [
        (
            rnd.uniform(x0, x1),
            rnd.uniform(y0, y1),
            rnd.uniform(1.6, 5.2),
            rnd.uniform(0, math.tau),
        )
        for _ in range(count)
    ]


def draw_twinkles(image: Image.Image, twinkles: list[tuple[float, float, float, float]], t: float, color=(218, 204, 255)) -> None:
    layer = Image.new("RGBA", image.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    for x, y, radius, phase in twinkles:
        pulse = 0.5 + 0.5 * math.sin(t * 2.15 + phase)
        alpha = int(34 + 150 * pulse)
        r = radius * (0.75 + 0.35 * pulse)
        draw.ellipse((x - r, y - r, x + r, y + r), fill=(color[0], color[1], color[2], alpha))
    image.alpha_composite(layer.filter(ImageFilter.GaussianBlur(0.35)))


def glass_card(size: tuple[int, int], radius: int = 42, tint=(255, 255, 255, 54)) -> Image.Image:
    card = rounded_rect_layer(size, radius, tint, outline=(255, 255, 255, 82), width=2)
    glow = rounded_rect_layer(size, radius, (132, 105, 255, 34), outline=None)
    return Image.alpha_composite(glow.filter(ImageFilter.GaussianBlur(14)), card)


def render_vertical() -> None:
    size = Size(1080, 1920)
    fps = 24
    duration = 23
    total = duration * fps
    bg = make_gradient(size)
    icon = fit_image(Image.open(APP_ICON), (180, 180))
    jar = fit_image(Image.open(FORTUNE_JAR), (310, 466))
    stick = fit_image(Image.open(FORTUNE_STICK), (360, 778))
    cap, demo_fps, _ = make_video_reader(DEMO_VIDEO)
    twinkles = make_twinkles(46, (330, 500, 760, 1510), 42)
    ambient = make_twinkles(38, (100, 140, 980, 1780), 99)
    cover: Image.Image | None = None

    def frames():
        nonlocal cover
        for i in range(total):
            t = i / fps
            frame = bg.copy()
            draw_twinkles(frame, ambient, t, color=(178, 225, 255))

            if t < 4.0:
                p = ease(t / 1.1)
                y = int(250 - (1 - p) * 50)
                paste_alpha(frame, icon, ((size.width - icon.width) // 2, y), p)
                draw_text(frame, (size.width // 2, y + 250), "Shake Cursor", 86, anchor="ma")
                draw_text(frame, (size.width // 2, y + 365), "安装后即可用", 46, rgba("#D8D0FF"), anchor="ma")
                draw_text(frame, (size.width // 2, y + 435), "摇一摇鼠标，唤起本地 Codex", 42, rgba("#FFFFFF", 232), anchor="ma")
                pill = glass_card((740, 110), 55, (255, 255, 255, 44))
                paste_alpha(frame, pill, (170, 1380), ease((t - 1.3) / 0.9))
                draw_text(frame, (235, 1438), "AI  问今天、安排、灵感...", 34, rgba("#EDE8FF", int(230 * ease((t - 1.4) / 0.8))))
                if cover is None and t > 1.0:
                    cover = frame.copy()

            elif t < 10.0:
                local = t - 4.0
                demo = demo_frame_at(cap, demo_fps, 3.0 + local * 1.15)
                demo_img = fit_video_frame(demo, (910, 466), cover=True)
                shell = glass_card((950, 506), 54, (255, 255, 255, 52))
                paste_alpha(frame, shell, (65, 530), 1.0)
                mask = Image.new("L", demo_img.size, 0)
                ImageDraw.Draw(mask).rounded_rectangle((0, 0, demo_img.width, demo_img.height), radius=34, fill=255)
                demo_img.putalpha(mask)
                paste_alpha(frame, demo_img, (85, 550), 1.0)
                draw_text(frame, (95, 310), "光标在哪里，入口就在哪里", 58, rgba("#FFFFFF", 245))
                draw_wrapped_text(frame, (95, 405), "隐藏到后台后，任意位置快速晃动鼠标，轻量浮层会直接出现在当前位置。", 34, 870, rgba("#CEC5FF", 235))
                draw_text(frame, (95, 1120), "不是新聊天窗口，也不是又一个快捷键。", 38, rgba("#FFFFFF", 230))
                draw_text(frame, (95, 1190), "这是一个系统级生活入口。", 52, rgba("#FFFFFF", 255), serif=True)

            elif t < 17.0:
                local = t - 10.0
                alpha = ease(local / 1.0)
                draw_text(frame, (size.width // 2, 185), "每支签都由 Codex 实时生成", 52, rgba("#FFFFFF", 245), anchor="ma")
                draw_text(frame, (size.width // 2, 260), "不是预设文案，所以不会机械重复", 36, rgba("#CEC5FF", 230), anchor="ma")
                float_y = int(575 + 12 * math.sin(t * 1.4))
                paste_alpha(frame, stick, ((size.width - stick.width) // 2, float_y), alpha)
                draw_twinkles(frame, twinkles, t, color=(236, 228, 255))
                info = glass_card((820, 210), 44, (112, 85, 198, 72))
                paste_alpha(frame, info, (130, 1530), ease((local - 2.2) / 0.8))
                draw_text(frame, (175, 1592), "结合当前时间、触发位置、最近对话、历史签文等可用上下文。", 31, rgba("#FFFFFF", 232))
                draw_text(frame, (175, 1660), "每次生成一支只属于当下的签。", 39, rgba("#FFFFFF", 255), serif=True)

            else:
                local = t - 17.0
                paste_alpha(frame, icon, (92, 170), 1.0)
                draw_text(frame, (305, 220), "也可以当日常助手", 58, rgba("#FFFFFF", 250))
                draw_text(frame, (305, 305), "提问、整理待办、写入 macOS 日历", 36, rgba("#CEC5FF", 235))
                prompts = [
                    ("问今天怎么安排", "给出短小、可执行的下一步"),
                    ("把想法变成待办", "自动提炼行动项"),
                    ("明天 8 点开会", "明确时间会写入日历"),
                ]
                for idx, (title, detail) in enumerate(prompts):
                    y = 520 + idx * 260
                    card = glass_card((880, 178), 38, (255, 255, 255, 44))
                    paste_alpha(frame, card, (100, y), ease((local - idx * 0.35) / 0.75))
                    draw_text(frame, (155, y + 62), title, 42, rgba("#FFFFFF", 248))
                    draw_text(frame, (155, y + 122), detail, 30, rgba("#CEC5FF", 232))
                draw_text(frame, (size.width // 2, 1430), "开源 + 已公证 DMG", 42, rgba("#FFFFFF", 250), anchor="ma")
                draw_text(frame, (size.width // 2, 1502), "jayztwo.github.io/huge-cursor", 34, rgba("#BFEFFF", 255), anchor="ma")
                draw_text(frame, (size.width // 2, 1608), "所有 Codex 用户都应该拥有", 48, rgba("#FFFFFF", 255), anchor="ma", serif=True)

            yield frame

    out = OUT_DIR / "shake-cursor-social-vertical.mp4"
    write_mp4(out, size, fps, frames())
    if cover:
        cover.save(OUT_DIR / "shake-cursor-social-cover.png")


def render_landscape() -> None:
    size = Size(1920, 1080)
    fps = 24
    duration = 18
    total = duration * fps
    bg = make_gradient(size, light=True)
    icon = fit_image(Image.open(APP_ICON), (128, 128))
    jar = fit_image(Image.open(FORTUNE_JAR), (260, 390))
    stick = fit_image(Image.open(FORTUNE_STICK), (270, 584))
    cap, demo_fps, _ = make_video_reader(DEMO_VIDEO)
    twinkles = make_twinkles(36, (1230, 190, 1690, 890), 7)
    cover: Image.Image | None = None

    def frames():
        nonlocal cover
        for i in range(total):
            t = i / fps
            frame = bg.copy()
            draw = ImageDraw.Draw(frame)
            draw.rounded_rectangle((86, 82, 1834, 998), radius=62, fill=(255, 255, 255, 100), outline=(255, 255, 255, 148), width=2)
            paste_alpha(frame, icon, (150, 150), 1.0)
            draw_text(frame, (150, 345), "Shake Cursor", 78, rgba("#201B35", 255))
            draw_wrapped_text(frame, (150, 462), "安装后即可用。摇一摇鼠标，在当前位置唤起本地 Codex 生活助手。", 40, 650, rgba("#514B68", 255))
            draw_text(frame, (150, 615), "签文不是预设库", 52, rgba("#201B35", 255), serif=True)
            draw_wrapped_text(frame, (150, 698), "每一支签都由 Codex 结合当前时间、触发位置、最近对话和历史签文实时生成，因此不会机械重复。", 34, 720, rgba("#625A7A", 255))
            draw_text(frame, (150, 885), "开源 + DMG  jayztwo.github.io/huge-cursor", 32, rgba("#7157D9", 255))

            if t < 8.8:
                demo = demo_frame_at(cap, demo_fps, 2.5 + t * 1.1)
                demo_img = fit_video_frame(demo, (840, 430), cover=True)
                mask = Image.new("L", demo_img.size, 0)
                ImageDraw.Draw(mask).rounded_rectangle((0, 0, demo_img.width, demo_img.height), radius=36, fill=255)
                demo_img.putalpha(mask)
                shadow = rounded_rect_layer((880, 470), 46, (62, 44, 120, 54)).filter(ImageFilter.GaussianBlur(28))
                paste_alpha(frame, shadow, (940, 264), 1.0)
                shell = glass_card((880, 470), 46, (255, 255, 255, 88))
                paste_alpha(frame, shell, (920, 244), 1.0)
                paste_alpha(frame, demo_img, (940, 264), 1.0)
                draw_text(frame, (960, 795), "摇动鼠标，输入框出现在光标附近", 36, rgba("#2E274A", 255))
            else:
                pulse = 0.94 + 0.025 * math.sin(t * 1.2)
                scaled = stick.resize((int(stick.width * pulse), int(stick.height * pulse)), Image.Resampling.LANCZOS)
                paste_alpha(frame, scaled, (1312 - scaled.width // 2, 228), 1.0)
                draw_twinkles(frame, twinkles, t, color=(148, 110, 255))
                paste_alpha(frame, jar, (1510, 350), 0.46)
                draw_text(frame, (960, 795), "实时生成，不重复；也能把明确时间写入日历", 36, rgba("#2E274A", 255))

            if cover is None and t > 1:
                cover = frame.copy()
            yield frame

    out = OUT_DIR / "shake-cursor-launch-landscape.mp4"
    write_mp4(out, size, fps, frames())
    if cover:
        cover.save(OUT_DIR / "shake-cursor-launch-cover.png")


def main() -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    render_vertical()
    render_landscape()
    print(f"Wrote videos to {OUT_DIR}")


if __name__ == "__main__":
    main()
