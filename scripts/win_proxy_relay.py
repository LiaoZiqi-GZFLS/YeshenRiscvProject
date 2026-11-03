#!/usr/bin/env python3
"""win_proxy_relay.py -- make the Windows loopback proxy usable from WSL.

Why: Clash-family proxies bind 127.0.0.1 only, and WSL2 in NAT mode cannot reach the
Windows loopback. WSL also inherits no usable proxy, so `git clone` from github.com dies
with `GnuTLS recv error (-110): The TLS connection was non-properly terminated`.
This relay listens on the WSL-facing host address and forwards to the loopback proxy, so
inside WSL you can just `export https_proxy=http://<win-ip>:7898`.

Run on WINDOWS (not in WSL):
    python scripts/win_proxy_relay.py                 # listen 172.21.128.1:7898 -> 127.0.0.1:7897
    python scripts/win_proxy_relay.py --bind 0.0.0.0  # or any interface

Find the Windows host address from WSL with:
    ip route | awk '/^default/{print $3}'

It is a plain TCP relay: HTTP and CONNECT both work, so git / curl / wget / buildroot all
work once https_proxy is set. It changes nothing on disk and stops with Ctrl-C.
"""
import argparse
import socket
import threading


def pipe(src, dst):
    try:
        while True:
            data = src.recv(65536)
            if not data:
                break
            dst.sendall(data)
    except OSError:
        pass
    finally:
        try:
            dst.shutdown(socket.SHUT_WR)
        except OSError:
            pass


def handle(client, target):
    try:
        upstream = socket.create_connection(target)
    except OSError as exc:
        print("relay: cannot reach upstream %s: %s" % (target, exc), flush=True)
        client.close()
        return
    threading.Thread(target=pipe, args=(client, upstream), daemon=True).start()
    pipe(upstream, client)
    client.close()
    upstream.close()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bind", default="172.21.128.1", help="address to listen on (the WSL-facing host IP)")
    ap.add_argument("--port", type=int, default=7898)
    ap.add_argument("--target-host", default="127.0.0.1")
    ap.add_argument("--target-port", type=int, default=7897)
    a = ap.parse_args()

    srv = socket.socket()
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((a.bind, a.port))
    srv.listen(64)
    print("relay: %s:%d -> %s:%d  (Ctrl-C to stop)" % (a.bind, a.port, a.target_host, a.target_port), flush=True)
    while True:
        client, _ = srv.accept()
        threading.Thread(target=handle, args=(client, (a.target_host, a.target_port)), daemon=True).start()


if __name__ == "__main__":
    main()
