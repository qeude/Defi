#!/usr/bin/env python3
"""Keyboard capture probe: do Defi shortcuts stay silent while another app captures the keyboard?
Sets the global hotkey operating mode to 1 the way SDL does, holds it so a person can press a Defi
shortcut and see nothing happen, then restores 0, also on Ctrl-C and SIGTERM.
Usage (under script/desktop_lock.py): script/keyboard_capture_probe.py [SECONDS, default 15]"""
import argparse, ctypes, signal, sys, time

SKYLIGHT = '/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('seconds', nargs='?', type=float, default=15)
    args = parser.parse_args()

    skylight = ctypes.CDLL(SKYLIGHT)
    connection = skylight.CGSMainConnectionID()

    def read_mode():
        mode = ctypes.c_int32()
        error = skylight.CGSGetGlobalHotKeyOperatingMode(connection, ctypes.byref(mode))
        return mode.value if error == 0 else f'error {error}'

    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    try:
        error = skylight.CGSSetGlobalHotKeyOperatingMode(connection, 1)
        print(f'set mode 1: error {error}, read back {read_mode()}', flush=True)
        print(f'holding for {args.seconds:g} s; press a Defi shortcut now', flush=True)
        time.sleep(args.seconds)
    except KeyboardInterrupt:
        pass
    finally:
        error = skylight.CGSSetGlobalHotKeyOperatingMode(connection, 0)
        print(f'restored mode 0: error {error}, read back {read_mode()}', flush=True)


if __name__ == '__main__':
    main()
