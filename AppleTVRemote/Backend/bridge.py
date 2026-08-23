#!/usr/bin/env python3
"""JSON-lines bridge between the macOS remote app and pyatv.

Protocol (newline-delimited JSON on stdin/stdout):

  Request:  {"id": <int>, "op": "<operation>", "params": {...}}
  Response: {"id": <int>, "ok": true,  "result": <json>}
            {"id": <int>, "ok": false, "error": "<message>"}
  Event:    {"event": "connection", "state": "connected" | "disconnected"}
            {"event": "pairing",    "state": "awaiting_pin" | "done" | "failed"}

Everything else (logs) goes to stderr.
"""

import argparse
import asyncio
import base64
import json
import logging
import sys
from pathlib import Path
from typing import Any, Dict, Optional

import pyatv
from pyatv.const import PowerState, Protocol
from pyatv.exceptions import NotSupportedError
from pyatv.storage.file_storage import FileStorage

_LOGGER = logging.getLogger("bridge")

APP_SUPPORT = Path.home() / "Library" / "Application Support" / "AppleTVRemote"
DEFAULT_STORAGE = APP_SUPPORT / "pyatv.json"
PAIRING_NAME = "MacBook Remote"


class BridgeError(Exception):
    """An error that should be reported back to the app."""


class Bridge:
    def __init__(self, storage_path: Path) -> None:
        self.storage_path = storage_path
        self.storage: Optional[FileStorage] = None
        self.atv: Optional[pyatv.interface.AppleTV] = None
        self.pairing: Optional[pyatv.interface.PairingHandler] = None
        self.scan_cache: Dict[str, pyatv.interface.BaseConfig] = {}
        self.op_lock = asyncio.Lock()
        self._tasks: set = set()
        self._artwork_key: Optional[str] = None
        self._artwork_b64: Optional[str] = None

    # ---------------------------------------------------------------- io

    def emit(self, event: Dict[str, Any]) -> None:
        print(json.dumps(event, ensure_ascii=False), flush=True)

    def log_event(self, message: str) -> None:
        self.emit({"event": "log", "message": message})

    # ------------------------------------------------------------- scan

    async def do_scan(self, params: Dict[str, Any]) -> list:
        timeout = int(params.get("timeout", 6))
        configs = await pyatv.scan(asyncio.get_running_loop(), timeout=timeout, storage=self.storage)
        devices = []
        self.scan_cache.clear()
        for config in configs:
            self.scan_cache[config.identifier] = config
            devices.append(
                {
                    "identifier": config.identifier,
                    "name": config.name,
                    "address": str(config.address),
                    "model": config.properties.get("model") or "",
                    "services": [service.protocol.name for service in config.services],
                }
            )
        return devices

    # ------------------------------------------------------------ pair

    async def _config_for(self, identifier: str) -> pyatv.interface.BaseConfig:
        config = self.scan_cache.get(identifier)
        if config is not None:
            return config
        # Device was not scanned yet (e.g. after a bridge restart): scan just
        # for this identifier, which also loads stored credentials.
        configs = await pyatv.scan(
            asyncio.get_running_loop(),
            timeout=4,
            identifier=identifier,
            storage=self.storage,
        )
        if not configs:
            raise BridgeError(f"找不到设备 {identifier}，请先在设置中扫描并连接")
        config = configs[0]
        self.scan_cache[identifier] = config
        return config

    async def do_pair_begin(self, params: Dict[str, Any]) -> dict:
        config = await self._config_for(params["identifier"])
        self.pairing = await pyatv.pair(
            config,
            Protocol.Companion,
            asyncio.get_running_loop(),
            storage=self.storage,
            name=params.get("name", PAIRING_NAME),
        )
        await self.pairing.begin()
        if self.pairing.device_provides_pin:
            self.emit({"event": "pairing", "state": "awaiting_pin"})
        return {"awaiting_pin": bool(self.pairing.device_provides_pin)}

    async def do_pair_finish(self, params: Dict[str, Any]) -> dict:
        if self.pairing is None:
            raise BridgeError("当前没有进行中的配对流程")
        pin = str(params.get("pin", "")).strip()
        if not pin:
            raise BridgeError("请输入 Apple TV 屏幕上的 PIN 码")
        self.pairing.pin(pin)
        await self.pairing.finish()
        if not self.pairing.has_paired:
            self.emit({"event": "pairing", "state": "failed"})
            raise BridgeError("配对失败，请确认 PIN 码后重试")
        await self.storage.save()
        self.emit({"event": "pairing", "state": "done"})
        return {"paired": True}

    # ---------------------------------------------------------- connect

    async def do_connect(self, params: Dict[str, Any]) -> dict:
        identifier = params["identifier"]
        config = await self._config_for(identifier)
        self.atv = await pyatv.connect(config, asyncio.get_running_loop(), storage=self.storage)
        # A connection can succeed at the transport level even when the
        # device has no usable credentials (i.e. not paired yet). Probe a
        # read-only capability so the UI can tell the user to pair instead
        # of showing a "connected" state where every button fails.
        try:
            await self.atv.apps.app_list()
        except NotSupportedError as exc:
            self.atv.close()
            self.atv = None
            self.emit({"event": "connection", "state": "disconnected"})
            raise BridgeError(f"尚未配对：设备功能不可用（{exc}）。请在设置中先对这台设备执行“配对”。")
        self._artwork_key = None
        self._artwork_b64 = None
        self.emit({"event": "connection", "state": "connected"})
        return {
            "identifier": config.identifier,
            "name": config.name,
            "model": config.properties.get("model") or "",
        }

    async def do_disconnect(self, params: Dict[str, Any]) -> dict:
        if self.atv is not None:
            try:
                self.atv.close()
            except Exception:  # pylint: disable=broad-except
                pass
            self.atv = None
        self.emit({"event": "connection", "state": "disconnected"})
        return {}

    def _require_atv(self) -> pyatv.interface.AppleTV:
        if self.atv is None:
            raise BridgeError("尚未连接到 Apple TV，请先在设置中连接")
        return self.atv

    # ------------------------------------------------------------ keys

    async def do_key(self, params: Dict[str, Any]) -> dict:
        atv = self._require_atv()
        key = params.get("key", "")
        rc = atv.remote_control
        handlers = {
            "up": rc.up,
            "down": rc.down,
            "left": rc.left,
            "right": rc.right,
            "select": rc.select,
            "menu": rc.menu,
            "top_menu": rc.top_menu,
            "home": rc.home,
            "home_hold": rc.home_hold,
            "play": rc.play,
            "pause": rc.pause,
            "play_pause": rc.play_pause,
            "next": rc.next,
            "previous": rc.previous,
            "stop": rc.stop,
            "suspend": rc.suspend,
            "wakeup": rc.wakeup,
            "volume_up": rc.volume_up,
            "volume_down": rc.volume_down,
            "skip_forward": rc.skip_forward,
            "skip_backward": rc.skip_backward,
            "control_center": rc.control_center,
            "screensaver": rc.screensaver,
            "channel_up": rc.channel_up,
            "channel_down": rc.channel_down,
            "guide": rc.guide,
        }
        handler = handlers.get(key)
        if handler is None:
            raise BridgeError(f"未知按键: {key}")
        await handler()
        return {}

    # ------------------------------------------------------------ power

    async def do_power(self, params: Dict[str, Any]) -> dict:
        atv = self._require_atv()
        action = params.get("action", "toggle")
        if action == "on":
            await atv.power.turn_on()
        elif action == "off":
            await atv.power.turn_off()
        else:
            if atv.power.power_state in (None, PowerState.Unknown, PowerState.Off):
                await atv.power.turn_on()
            else:
                await atv.power.turn_off()
        return {"action": action}

    # ----------------------------------------------------------- volume

    async def do_volume(self, params: Dict[str, Any]) -> dict:
        atv = self._require_atv()
        action = params.get("action", "up")
        if action == "up":
            await atv.remote_control.volume_up()
        elif action == "down":
            await atv.remote_control.volume_down()
        elif action == "set":
            await atv.audio.set_volume(float(params.get("level", 0)))
        else:
            raise BridgeError(f"未知音量操作: {action}")
        return {}

    # ------------------------------------------------------------ apps

    async def do_apps(self, params: Dict[str, Any]) -> list:
        atv = self._require_atv()
        apps = await atv.apps.app_list()
        return [{"identifier": app.identifier, "name": app.name} for app in apps]

    async def do_launch(self, params: Dict[str, Any]) -> dict:
        atv = self._require_atv()
        app_id = params.get("app", "")
        if not app_id:
            raise BridgeError("缺少 app 参数")
        await atv.apps.launch_app(app_id)
        return {}

    # ------------------------------------------------------------- text

    async def do_text(self, params: Dict[str, Any]) -> dict:
        atv = self._require_atv()
        text = str(params.get("text", ""))
        if not text:
            raise BridgeError("缺少 text 参数")
        await atv.keyboard.text_append(text)
        return {}

    # ----------------------------------------------------------- status

    async def do_status(self, params: Dict[str, Any]) -> dict:
        atv = self._require_atv()
        playing = await atv.metadata.playing()
        try:
            power = atv.power.power_state
        except Exception:  # pylint: disable=broad-except
            power = None

        # Only re-fetch artwork when the playing item changed.
        artwork_b64 = None
        if playing.hash and playing.hash != self._artwork_key:
            try:
                artwork = await atv.metadata.artwork(width=512)
                if artwork is not None and artwork.bytes:
                    artwork_b64 = base64.b64encode(artwork.bytes).decode("ascii")
                    self._artwork_key = playing.hash
                    self._artwork_b64 = artwork_b64
                else:
                    self._artwork_key = playing.hash
                    self._artwork_b64 = None
            except Exception:  # pylint: disable=broad-except
                _LOGGER.debug("artwork fetch failed", exc_info=True)
        elif playing.hash == self._artwork_key:
            artwork_b64 = self._artwork_b64

        def name_of(enum_value) -> Optional[str]:
            return getattr(enum_value, "name", None) if enum_value is not None else None

        return {
            "title": playing.title,
            "artist": playing.artist,
            "album": playing.album,
            "media_type": name_of(playing.media_type),
            "device_state": name_of(playing.device_state),
            "position": playing.position,
            "total_time": playing.total_time,
            "artwork": artwork_b64,
            "power_state": name_of(power),
        }

    # ------------------------------------------------------------ main

    async def dispatch(self, request: dict) -> None:
        req_id = request.get("id")
        op = request.get("op", "")
        params = request.get("params") or {}
        try:
            async with self.op_lock:
                handlers = {
                    "scan": self.do_scan,
                    "pair_begin": self.do_pair_begin,
                    "pair_finish": self.do_pair_finish,
                    "connect": self.do_connect,
                    "disconnect": self.do_disconnect,
                    "key": self.do_key,
                    "power": self.do_power,
                    "volume": self.do_volume,
                    "apps": self.do_apps,
                    "launch": self.do_launch,
                    "text": self.do_text,
                    "status": self.do_status,
                }
                handler = handlers.get(op)
                if handler is None:
                    raise BridgeError(f"未知操作: {op}")
                result = await handler(params)
            self.emit({"id": req_id, "ok": True, "result": result})
        except Exception as exc:  # pylint: disable=broad-except
            _LOGGER.exception("request %s failed", op)
            self.emit({"id": req_id, "ok": False, "error": str(exc)})

    async def run(self) -> None:
        self.storage_path.parent.mkdir(parents=True, exist_ok=True)
        self.storage = FileStorage(str(self.storage_path), asyncio.get_running_loop())
        await self.storage.load()
        self.log_event(f"bridge ready (pyatv {pyatv.const.__version__})")
        loop = asyncio.get_running_loop()
        while True:
            line = await loop.run_in_executor(None, sys.stdin.readline)
            if not line:
                _LOGGER.info("stdin closed, exiting")
                break
            line = line.strip()
            if not line:
                continue
            try:
                request = json.loads(line)
            except json.JSONDecodeError as exc:
                _LOGGER.warning("invalid request: %s", exc)
                continue
            task = asyncio.ensure_future(self.dispatch(request))
            self._tasks.add(task)
            task.add_done_callback(self._tasks.discard)
        if self._tasks:
            _LOGGER.info("draining %d pending request(s)", len(self._tasks))
            await asyncio.wait(self._tasks, timeout=60)
        if self.atv is not None:
            try:
                self.atv.close()
            except Exception:  # pylint: disable=broad-except
                pass
            self.atv = None


def main() -> int:
    parser = argparse.ArgumentParser(description="Apple TV bridge")
    parser.add_argument("--storage", default=str(DEFAULT_STORAGE), help="pyatv storage file")
    parser.add_argument("--log-level", default="INFO", help="logging level")
    args = parser.parse_args()

    logging.basicConfig(
        stream=sys.stderr,
        level=getattr(logging, args.log_level.upper(), logging.INFO),
        format="%(asctime)s %(levelname)s [%(name)s] %(message)s",
    )
    logging.getLogger("requests").setLevel(logging.WARNING)
    logging.getLogger("zeroconf").setLevel(logging.WARNING)

    bridge = Bridge(Path(args.storage))
    try:
        asyncio.run(bridge.run())
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
