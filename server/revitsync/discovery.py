import logging
import socket

log = logging.getLogger("revitsync.discovery")

SERVICE_TYPE = "_revitsync._tcp.local."


def lan_ipv4s() -> list[str]:
    ips = set()
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.connect(("10.255.255.255", 1))
            ips.add(s.getsockname()[0])
    except OSError:
        pass
    try:
        for info in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
            ips.add(info[4][0])
    except OSError:
        pass
    return sorted(ip for ip in ips if not ip.startswith("127."))


def start(port: int):
    try:
        from zeroconf import IPVersion, ServiceInfo, Zeroconf

        ips = lan_ipv4s()
        host = socket.gethostname().split(".")[0]
        info = ServiceInfo(
            SERVICE_TYPE,
            f"{host}.{SERVICE_TYPE}",
            addresses=[socket.inet_aton(ip) for ip in ips],
            port=port,
            properties={"path": "/api"},
            server=f"{host}.local.",
        )
        zc = Zeroconf(interfaces=ips or None, ip_version=IPVersion.V4Only)
        zc.register_service(info)
        log.info("advertising %s on %s:%d", SERVICE_TYPE, ",".join(ips), port)
        return zc, info
    except Exception as e:
        log.warning("mDNS advertisement failed, continuing without it: %s", e)
        return None


def stop(handle) -> None:
    if not handle:
        return
    zc, info = handle
    try:
        zc.unregister_service(info)
    finally:
        zc.close()
