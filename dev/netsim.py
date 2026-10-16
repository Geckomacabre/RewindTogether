"""
A bad internet connection between a guest and a host on ONE PC.

    py dev/netsim.py                                  # 150 ms round trip, 25 ms jitter, 2% loss
    py dev/netsim.py --lag 250 --jitter 60 --loss 5   # worse
    py dev/coop_test.py up 127.0.0.1:27016            # the guest joins through it

Every test before this ran a host and a guest over 127.0.0.1: no delay, no loss,
packets always in order. A real friend is 50-200 ms away and loses the odd packet,
and the first real two-PC session found bugs the lab never had. The knowledge
base's multiplayer note puts it as "everything is fine in the lab, breaks on the
internet".

Unreal's own NetEmulation.* commands are compiled out of Shipping builds, so this
sits in the middle instead: the guest joins 127.0.0.1:27016, and each datagram is
held for half the round trip (plus or minus the jitter, so packets can arrive out
of order, as on the internet) or dropped, in both directions, before it goes on to
the host's 27015. One upstream socket per guest, so the host sees each guest as a
separate client. Nothing is installed and nothing leaves this PC.

Packets keep their order unless --reorder is given. MEASURED: with every packet
delayed on its own (300 ms +/- 80 ms, 5% loss) a rejoining guest took about three
minutes to receive the store, because Unreal drops a packet that arrives after a
newer one - the jitter alone was losing far more than the 5%. Real connections
seldom reorder; their jitter moves whole runs of packets.
"""
import argparse
import asyncio
import random
import sys
import time


class Link:
    def __init__(self, args):
        self.a = args
        self.loop = None
        self.down = None                 # the socket guests talk to
        self.clients = {}                # guest address -> its upstream transport (or a list while opening)
        self.stats = {"up": 0, "down": 0, "dropped_up": 0, "dropped_down": 0}
        self.rand = random.Random(args.seed)
        self.last = {}                   # (guest, direction) -> when its last packet goes out

    def when(self, guest, direction):
        """Loop time to deliver at: half the round trip, plus or minus the jitter,
        and never before the packet ahead of it unless reordering is allowed."""
        one_way = self.a.lag / 2000.0
        jitter = self.a.jitter / 1000.0
        at = self.loop.time() + max(0.0, one_way + self.rand.uniform(-jitter, jitter))
        if not self.a.reorder:
            at = max(at, self.last.get((guest, direction), 0.0) + 0.0001)
            self.last[(guest, direction)] = at
        return at

    def lost(self):
        return self.rand.random() * 100.0 < self.a.loss

    def to_host(self, guest, data):
        if self.lost():
            self.stats["dropped_up"] += 1
            return
        self.stats["up"] += 1
        up = self.clients.get(guest)
        self.loop.call_at(self.when(guest, "up"), lambda: up.sendto(data) if not isinstance(up, list) else None)

    def to_guest(self, guest, data):
        if self.lost():
            self.stats["dropped_down"] += 1
            return
        self.stats["down"] += 1
        self.loop.call_at(self.when(guest, "down"), lambda: self.down.sendto(data, guest))


class FromGuests(asyncio.DatagramProtocol):
    def __init__(self, link):
        self.link = link

    def connection_made(self, transport):
        self.link.down = transport

    def error_received(self, exc):
        # Windows answers a datagram sent to a guest that has left with "port
        # unreachable", which surfaces here. Nothing to do: keep listening.
        pass

    def datagram_received(self, data, addr):
        link = self.link
        known = link.clients.get(addr)
        if known is None:
            link.clients[addr] = [data]              # hold until its upstream socket is open
            link.loop.create_task(open_upstream(link, addr))
            print("guest %s:%d connected through the link" % addr, flush=True)
        elif isinstance(known, list):
            known.append(data)
        else:
            link.to_host(addr, data)


class FromHost(asyncio.DatagramProtocol):
    def __init__(self, link, guest):
        self.link, self.guest = link, guest

    def error_received(self, exc):
        pass

    def datagram_received(self, data, addr):
        self.link.to_guest(self.guest, data)


async def open_upstream(link, guest):
    transport, _ = await link.loop.create_datagram_endpoint(
        lambda: FromHost(link, guest), remote_addr=("127.0.0.1", link.a.target))
    held = link.clients.get(guest) or []
    link.clients[guest] = transport
    for data in held:
        link.to_host(guest, data)


async def main(args):
    link = Link(args)
    link.loop = asyncio.get_running_loop()
    await link.loop.create_datagram_endpoint(lambda: FromGuests(link), local_addr=("127.0.0.1", args.listen))
    print("netsim: 127.0.0.1:%d -> 127.0.0.1:%d, %d ms round trip, +/-%d ms jitter, %.1f%% loss each way%s"
          % (args.listen, args.target, args.lag, args.jitter, args.loss,
             ", packets may overtake each other" if args.reorder else ""), flush=True)
    t0 = time.time()
    while args.seconds <= 0 or time.time() - t0 < args.seconds:
        await asyncio.sleep(args.report)
        s = link.stats
        print("netsim: %d guest(s), to host %d (+%d dropped), to guests %d (+%d dropped)"
              % (len(link.clients), s["up"], s["dropped_up"], s["down"], s["dropped_down"]), flush=True)


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--lag", type=int, default=150, help="round trip, ms")
    p.add_argument("--jitter", type=int, default=25, help="+/- per packet, ms")
    p.add_argument("--loss", type=float, default=2.0, help="percent of packets dropped, each way")
    p.add_argument("--listen", type=int, default=27016, help="the port guests join")
    p.add_argument("--target", type=int, default=27015, help="the host's port")
    p.add_argument("--seconds", type=int, default=0, help="stop after this long (0 = run until killed)")
    p.add_argument("--report", type=int, default=30, help="seconds between stats lines")
    p.add_argument("--reorder", action="store_true", help="let jitter reorder packets (harsher than most real links)")
    p.add_argument("--seed", type=int, default=None)
    args = p.parse_args()
    if sys.platform == "win32":
        # MEASURED: the default (proactor) loop stops reading a UDP socket for good
        # after one "port unreachable" - the proxy went deaf the moment the first
        # guest left, and the guest's rejoin found nothing there. The selector loop
        # reports it to error_received and keeps reading.
        asyncio.run(main(args), loop_factory=asyncio.SelectorEventLoop)
    else:
        asyncio.run(main(args))
