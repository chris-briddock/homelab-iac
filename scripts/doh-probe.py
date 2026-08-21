#!/usr/bin/env python3
"""
doh-probe.py — smoke-test the lab's RFC 8484 DoH endpoints.

Builds a real DNS wire-format query for a lab-internal name, base64url-encodes
it, hits https://<host>/dns-query?dns=<b64> over HTTPS using the lab root CA
as the trust anchor, and reports the resolved IPv4 from the wire-format answer.

Usage:
  python3 scripts/doh-probe.py                          # defaults: probe both dns + dns2 for gitea.lab.internal/A
  python3 scripts/doh-probe.py penpot.lab.internal     # different query name
  python3 scripts/doh-probe.py gitea.lab.internal dns2.lab.internal   # 1 host only
"""

import base64
import socket
import ssl
import struct
import sys
import urllib.request

# The live trust anchor is the file-based root (see pki.tf); the old
# pki/root-ca-cert.pem is the dead tfstate-era root, kept for reference only.
LAB_CA = 'pki/root-ca.crt'
DEFAULT_HOSTS = ('dns.lab.internal', 'dns2.lab.internal')
DEFAULT_QNAME = 'gitea.lab.internal'
QTYPE = 1  # A record


def build_query(qname: str, qtype: int = QTYPE, qid: int = 0x1234) -> bytes:
    """
    Construct a minimal DNS wire-format packet:
      [12-byte header]  [qname labels]  [qtype(2B) + qclass(2B)]
    """
    # Header: qid, flags (RD=1), qdcount=1, ancount=nscount=arcount=0
    header = struct.pack('>HHHHHH', qid, 0x0100, 1, 0, 0, 0)
    # QNAME as a sequence of length-prefixed labels + null terminator
    qname_wire = b''.join(
        bytes([len(label)]) + label.encode('ascii')
        for label in qname.rstrip('.').split('.')
    ) + b'\x00'
    return header + qname_wire + struct.pack('>HH', qtype, 1)


def b64url_nopad(data: bytes) -> str:
    """base64.urlsafe_b64encode with trailing '=' stripped (RFC 8484 §6)."""
    return base64.urlsafe_b64encode(data).rstrip(b'=').decode('ascii')


def parse_first_a_rdata(packet: bytes) -> str:
    """
    Walk a wire-format DNS response and return the IPv4 from the first A RR
    in the answer section. The naive "last 4 bytes of the body" heuristic
    returns the wrong value whenever additional sections (EDNS SOA, TSIG, or
    a CNAME chase) extend the packet — which is most of the time in
    production, including for our step-ca-fronted DoH server.
    """
    # Header: qid(2) flags(2) qdcount(2) ancount(2) nscount(2) arcount(2)
    if len(packet) < 12:
        raise RuntimeError('response body too short for DNS header')
    qd = struct.unpack('>H', packet[4:6])[0]
    an = struct.unpack('>H', packet[6:8])[0]
    if an == 0:
        raise RuntimeError('no answer RRs in response')
    pos = 12
    # Skip the question section (one or more qname+qtype+qclass entries)
    for _ in range(qd):
        # QNAME may have compression pointers (0xC0) or be a label sequence
        while True:
            length = packet[pos]
            pos += 1
            if length == 0:
                break
            if length & 0xC0 == 0xC0:
                pos += 1
                break
            pos += length
        pos += 4  # qtype + qclass
    # Walk the answer RRs, return the IPv4 from the first A one
    for _ in range(an):
        # NAME (pointer or labels)
        while True:
            length = packet[pos]
            pos += 1
            if length == 0:
                break
            if length & 0xC0 == 0xC0:
                pos += 1
                break
            pos += length
        rtype, _rclass, _ttl, rdlen = struct.unpack('>HHIH', packet[pos:pos+10])
        pos += 10
        rdata = packet[pos:pos+rdlen]
        pos += rdlen
        if rtype == 1 and rdlen == 4:  # A record with a 4-byte IPv4
            return '.'.join(str(b) for b in rdata)
    raise RuntimeError('no A RRs in answer section')


def probe(host: str, qname: str, timeout: int = 10) -> str:
    q = build_query(qname)
    url = f'https://{host}/dns-query?dns={b64url_nopad(q)}'
    # Pin TLS >= 1.3 explicitly (SonarQube python:S4423): create_default_context
    # inherits the running OpenSSL's floor, which can be lower, and Python 3.14
    # deprecates implicit version selection in favour of explicit minimum_version.
    ctx = ssl.create_default_context(cafile=LAB_CA)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_3
    req = urllib.request.Request(url, headers={'accept': 'application/dns-message'})
    with urllib.request.urlopen(req, context=ctx, timeout=timeout) as r:
        body = r.read()
        return parse_first_a_rdata(body)


def main() -> int:
    argv = sys.argv[1:]
    qname = argv[0] if len(argv) >= 1 else DEFAULT_QNAME
    hosts = (argv[1],) if len(argv) >= 2 else DEFAULT_HOSTS

    failures = 0
    for host in hosts:
        try:
            ip = probe(host, qname)
            print(f'{host}: HTTP 200  answer {qname} -> {ip}')
        except Exception as e:
            failures += 1
            print(f'{host}: FAILED — {e}')
    return 0 if failures == 0 else 1


if __name__ == '__main__':
    sys.exit(main())
