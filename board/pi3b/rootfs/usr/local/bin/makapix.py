#!/usr/bin/env python3
"""
Makapix Club - Optimized Linux Framebuffer Art Display

Before running, install dependencies:
    pip install numpy Pillow requests


Controls:
  Right / Left arrow  — next / previous artwork
  x                   — refresh artwork list and restart from index 0
  Esc, q, Ctrl+C      — exit

Logs:
  /var/log/makapix.log
"""

import requests
import struct
import fcntl
import sys
import time
import io
import os
import tty
import termios
import threading
import mmap
import queue

import numpy as np

from PIL import Image, ImageSequence
from collections import OrderedDict
from pathlib import Path

limit = min(int(sys.argv[1]), 200) if sys.argv[1:] else 100

BASE_URL = "https://makapix.club"
API_URL = f"{BASE_URL}/api/post?sort=random&limit={limit}"

FB_DEV = "/dev/fb0"
LOG_FILE = "/var/log/makapix.log"

FBIOGET_VSCREENINFO = 0x4600
FBIOGET_FSCREENINFO = 0x4602

NAV_NEXT = "next"
NAV_PREV = "prev"
NAV_REFRESH = "refresh"

CACHE_DIR = Path.home() / ".makapix"
CACHE_DIR.mkdir(
    parents=True,
    exist_ok=True
)

quit_event = threading.Event()
nav_command = None
nav_lock = threading.Lock()

_log_fh = None


def log(msg: str):
    if _log_fh:
        ts = time.strftime("%Y-%m-%d %H:%M:%S")
        _log_fh.write(f"[{ts}] {msg}\n")
        _log_fh.flush()


def cursor_hide():
    try:
        with open("/dev/tty", "w") as tty_out:
            tty_out.write("\033[?25l")
            tty_out.flush()
    except Exception:
        pass


def cursor_show():
    try:
        with open("/dev/tty", "w") as tty_out:
            tty_out.write("\033[?25h")
            tty_out.flush()
    except Exception:
        pass


def post_nav(cmd: str):
    global nav_command
    with nav_lock:
        nav_command = cmd


def take_nav():
    global nav_command
    with nav_lock:
        cmd = nav_command
        nav_command = None
    return cmd


def keyboard_listener():
    try:
        import select
        fd = os.open("/dev/tty", os.O_RDONLY)
        old_attrs = termios.tcgetattr(fd)
        tty.setraw(fd)

        try:
            while not quit_event.is_set():
                r, _, _ = select.select([fd], [], [], 0.1)
                if not r:
                    continue
                data = os.read(fd, 8)
                if not data:
                    continue
                if data == b"\x1b[C":
                    post_nav(NAV_NEXT)
                elif data == b"\x1b[D":
                    post_nav(NAV_PREV)
                elif data in (b"x", b"X"):
                    post_nav(NAV_REFRESH)
                elif data in (b"\x1b", b"q", b"Q", b"\x03"):
                    quit_event.set()
                    break
        finally:
            termios.tcsetattr(fd, termios.TCSADRAIN, old_attrs)
            os.close(fd)
    except Exception as e:
        log(f"keyboard_listener error: {e}")


def get_fb_info(fb):
    vinfo_buf = b"\x00" * 160
    vinfo_buf = fcntl.ioctl(fb, FBIOGET_VSCREENINFO, vinfo_buf)
    xres, yres, _, _, _, _, bpp = struct.unpack_from("7I", vinfo_buf)
    return xres, yres, bpp


def image_to_fb_bytes(img: Image.Image, fb_w: int, fb_h: int, bpp: int) -> bytes:
    # Convert to RGBA and resize to screen size while maintaining aspect ratio
    img = img.convert("RGBA")
    iw, ih = img.size
    scale = min(fb_w / iw, fb_h / ih)
    new_w = max(1, int(iw * scale))
    new_h = max(1, int(ih * scale))
    resample = Image.NEAREST     # NEAREST / BILINEAR
    img = img.resize((new_w, new_h), resample)

    # Convert to framebuffer bytes
    canvas = Image.new("RGBA", (fb_w, fb_h), (0, 0, 0, 255))
    x_off = (fb_w - new_w) // 2
    y_off = (fb_h - new_h) // 2
    canvas.paste(img, (x_off, y_off), img)

    if bpp == 32:
        arr = np.array(canvas, dtype=np.uint8)
        bgra = arr[:, :, [2, 1, 0, 3]]
        return bgra.tobytes()
    elif bpp == 24:
        arr = np.array(canvas.convert("RGB"), dtype=np.uint8)
        bgr = arr[:, :, [2, 1, 0]]
        return bgr.tobytes()
    elif bpp == 16:
        rgb = np.array(canvas.convert("RGB"), dtype=np.uint16)
        r = (rgb[:, :, 0] >> 3) << 11
        g = (rgb[:, :, 1] >> 2) << 5
        b = rgb[:, :, 2] >> 3
        rgb565 = (r | g | b).astype("<u2")
        return rgb565.tobytes()
    raise ValueError(f"Unsupported bpp: {bpp}")


def fetch_artwork_list(retries=5, retry_delay=2,):
    last_error = None
    for attempt in range(1, retries + 1):
        try:
            log(f"Fetching artwork list (attempt {attempt}/{retries})  from {API_URL}")
            print(f"Fetching artwork list (attempt {attempt}/{retries})...\r")
            resp = requests.get(API_URL, timeout=15)
            resp.raise_for_status()
            data = resp.json()
            items = data.get("items", [])
            log(f"Fetched {len(items)} items")
            return items
        except Exception as e:
            last_error = e
            log(f"fetch_artwork_list failed: {e}")
            if attempt < retries:
                time.sleep(retry_delay)
    log(f"All retries failed: {last_error}")
    raise last_error

def fetch_image(title: str, art_url: str) -> Image.Image:
    if art_url.startswith("/"):
        art_url = BASE_URL + art_url
    filename = os.path.basename(art_url.split("?")[0])
    cache_path = CACHE_DIR / filename
    # disk cache hit
    if cache_path.exists():
        log(f"Image in disk, skip downloading: {title} - {cache_path}")
        return Image.open(cache_path)
    # download
    resp = requests.get(art_url, timeout=20)
    resp.raise_for_status()
    # save to disk
    with open(cache_path, "wb") as f:
        f.write(resp.content)
    log(f"Saved image to disk: {title} - {cache_path}")
    return Image.open(cache_path)

def prepare_frames(img, fb_w, fb_h, bpp):
    prepared = []

    try:
        iterator = ImageSequence.Iterator(img)
        for frame in iterator:
            frame = frame.copy()
            raw = image_to_fb_bytes(frame, fb_w, fb_h, bpp)
            duration = frame.info.get("duration", 100)
            prepared.append((raw, duration))
    except Exception:
        pass

    if not prepared:
        raw = image_to_fb_bytes(img, fb_w, fb_h, bpp)
        prepared.append((raw, 3000))
    return prepared


def interruptible_sleep(seconds: float):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if quit_event.is_set():
            return "quit"
        cmd = take_nav()
        if cmd:
            return cmd
        remaining = deadline - time.monotonic()
        if remaining > 0:
            time.sleep(min(0.01, remaining))
    return take_nav()


class Prefetcher:
    def __init__(self, fb_w, fb_h, bpp):
        self.fb_w = fb_w
        self.fb_h = fb_h
        self.bpp = bpp
        self.cache = OrderedDict()
        self.max_cache = 5
        self.loading = set()
        self.lock = threading.Lock()

    def _cache_put(self, art_url, prepared):
        self.cache[art_url] = prepared
        # move newest to end
        self.cache.move_to_end(art_url)
        # evict oldest
        while len(self.cache) > self.max_cache:
            old_url, _ = self.cache.popitem(last=False)
            # log(f"Evicted cache: {old_url}")

    def preload(self, item):
        title = item.get("title", "(untitled)")
        art_url = item.get("art_url", "")
        if art_url.startswith("/"):
            art_url = BASE_URL + art_url
        with self.lock:
            if art_url in self.cache:
                return
            if art_url in self.loading:
                return
            self.loading.add(art_url)
        thread = threading.Thread(
            target=self._worker,
            args=(title, art_url),
            daemon=True,
        )
        thread.start()

    def _worker(self, title, art_url):
        try:
            img = fetch_image(title, art_url)
            prepared = prepare_frames(
                img,
                self.fb_w,
                self.fb_h,
                self.bpp,
            )
            with self.lock:
                self._cache_put(art_url, prepared)
                log(f"Pre-rendered: {title}")
        except Exception as e:
            log(f"Prefetch error: {e}")
        finally:
            with self.lock:
                self.loading.discard(art_url)

    def get(self, item):
        title = item.get("title", "(untitled)")
        art_url = item.get("art_url")
        if art_url.startswith("/"):
            art_url = BASE_URL + art_url
        with self.lock:
            cached = self.cache.get(art_url)
            if cached:
                self.cache.move_to_end(art_url)
        if cached:
            return cached

        # if another thread is already loading this URL, wait for it to finish and return the result if available
        if art_url in self.loading:
            print(f"Still loading: {title}\r")
            while True:
                time.sleep(0.2)
                with self.lock:
                    cached = self.cache.get(art_url)
                    if cached:
                        self.cache.move_to_end(art_url)
                        return cached
                    if art_url not in self.loading:
                        break
            if cached:
                return cached

        print(f"Cache miss, loading synchronously: {title}\r")
        img = fetch_image(title, art_url)
        prepared = prepare_frames(
            img,
            self.fb_w,
            self.fb_h,
            self.bpp,
        )
        with self.lock:
            self._cache_put(art_url, prepared)
        return prepared

    def clear(self):
        with self.lock:
            self.cache.clear()
            self.loading.clear()
        log("Prefetch cache cleared")

def display_item(idx, item, fb_mm, prefetcher, items_len):
    title = item.get("title", "(untitled)")
    dwell_default = 30
    dwell = (item.get("dwell_time_ms") or dwell_default * 1000) / 1000.0
    try:
        prepared = prefetcher.get(item)
        log(f"Displaying: [{idx+1}/{items_len}] {title} - width={item.get('width')} height={item.get('height')} frame_count={item.get('frame_count')} dwell={dwell} art_url={item.get('art_url')}")
    except Exception as e:
        log(f"Display error: {e}")
        return None
    start = time.monotonic()
    while time.monotonic() - start < dwell:
        for raw, dur_ms in prepared:
            fb_mm.seek(0)
            fb_mm.write(raw)
            remaining = dwell - (time.monotonic() - start)
            if remaining <= 0:
                break
            signal = interruptible_sleep(
                min(dur_ms / 1000.0, remaining)
            )
            if signal:
                return signal

    return None


def main():
    global _log_fh
    _log_fh = open(LOG_FILE, "w")
    log("=== makapix_fb started ===")
    print(f"=== makapix_fb started ===\r")

    cursor_hide()

    try:
        threading.Thread(
            target=keyboard_listener,
            daemon=True,
        ).start()

        items = fetch_artwork_list()
        items_len = len(items)

        if not items:
            log("No items returned")
            sys.exit(1)

        fb = open(FB_DEV, "r+b")
        fb_w, fb_h, bpp = get_fb_info(fb)
        fb_size = fb_w * fb_h * (bpp // 8)
        fb_mm = mmap.mmap(
            fb.fileno(),
            fb_size,
            mmap.MAP_SHARED,
            mmap.PROT_WRITE | mmap.PROT_READ,
        )

        log(f"Framebuffer: {fb_w}x{fb_h} {bpp}bpp")
        prefetcher = Prefetcher(fb_w, fb_h, bpp)
        idx = 0

        while not quit_event.is_set():
            # Preload next 3 items
            for i in range(1, 4):
                next_idx = (idx + i) % items_len
                # log(f"Scheduling preload: {next_idx+1}/{items_len} {items[next_idx].get('title')}")
                prefetcher.preload(items[next_idx])

            signal = display_item(
                idx,
                items[idx],
                fb_mm,
                prefetcher,
                items_len
            )

            if signal == "quit" or quit_event.is_set():
                break
            elif signal == NAV_REFRESH:
                log("Refreshing artwork list")
                new_items = fetch_artwork_list()
                if new_items:
                    prefetcher.clear()
                    items = new_items
                    items_len = len(items)
                    idx = 0
            elif signal == NAV_PREV:
                idx = (idx - 1) % items_len
            else:
                idx += 1
                # reached end of list
                if idx >= items_len:
                    log("Reached end of artwork list")
                    try:
                        new_items = fetch_artwork_list()
                        if new_items:
                            prefetcher.clear()
                            items = new_items
                            items_len = len(items)
                            idx = 0
                            log(f"Loaded new artwork list ({items_len} items)")
                    except Exception as e:
                        log(f"Failed to refresh artwork list: {e}")
                        idx = 0

        fb_mm.close()
        fb.close()

    except KeyboardInterrupt:
        quit_event.set()
    finally:
        cursor_show()
        log("=== makapix_fb exited ===")
        print(f"=== makapix_fb exited ===\r")
        if _log_fh:
            _log_fh.close()


if __name__ == "__main__":
    if not os.path.exists(FB_DEV):
        sys.stderr.write(
            f"ERROR: Framebuffer device {FB_DEV} not found.\n"
        )
        sys.exit(1)

    main()