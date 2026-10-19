# Independent reference generator for the v2 golden vectors next to this file.
# Usage: python3 -I generate_relay_envelope_hmac_v2.py <output.json>
# Needs only the standard library. Output must match the committed JSON exactly.
import hmac, hashlib, json, struct, uuid, base64, sys

def hkdf(ikm, salt, info, n=32):
    if not salt: salt = b"\0"*32
    prk = hmac.new(salt, ikm, hashlib.sha256).digest()
    out, t, i = b"", b"", 1
    while len(out) < n:
        t = hmac.new(prk, t + info + bytes([i]), hashlib.sha256).digest(); out += t; i += 1
    return out[:n]

def lp(b): return struct.pack(">I", len(b)) + b
def ub(u): return uuid.UUID(u).bytes

SECRET = bytes.fromhex("3c3d3e3f404142434445464748494a4b4c4d4e4f505152535455565758595a5b")
POOL = "A0A0A0A0-B1B1-4C2C-8D3D-E4E4E4E4E4E4"
MSG = "0F1E2D3C-4B5A-4978-8695-A4B3C2D1E0F0"
SALT = ub(POOL) + b"StealthOS-RelayEnvelope-HMAC-Salt"
K1 = hkdf(SECRET, SALT, b"envelope-integrity-v1")
K2 = hkdf(SECRET, SALT, b"envelope-integrity-v2")

def v1_input(o, d, pool, mid, ts2001):
    return lp(o.encode()) + lp((d or "").encode()) + ub(pool) + ub(mid) + struct.pack("<q", 5) + struct.pack("<d", ts2001 + 978307200.0)

def v2_input(o, d, pool, mid, otl, ts2001, payload):
    b = lp(b"STEALTH_RELAY_ENVELOPE_V2") + lp(o.encode())
    b += b"\x00" if d is None else b"\x01" + lp(d.encode())
    b += ub(pool) + ub(mid) + struct.pack(">I", otl) + struct.pack(">d", ts2001) + struct.pack(">Q", len(payload)) + payload
    return b

def env_json(o, d, ttl, hops, payload, pool, mid, ts, h1, v, otl, h2):
    j = {"messageID": mid.upper(), "originPeerID": o, "ttl": ttl, "hopPath": hops,
         "encryptedPayload": base64.b64encode(payload).decode(), "poolID": pool.upper(), "timestamp": ts}
    if d is not None: j["destinationPeerID"] = d
    if h1 is not None: j["envelopeHMAC"] = base64.b64encode(h1).decode()
    if v is not None: j["envelopeVersion"] = v
    if otl is not None: j["originTTL"] = otl
    if h2 is not None: j["envelopeHMACV2"] = base64.b64encode(h2).decode()
    return json.dumps(j, ensure_ascii=False, sort_keys=True)

vectors = []
vectors.append({"name": "hmac_key_v2", "kind": "hmac_key_v2", "expect": "ok", "description": "v2 key: HKDF-SHA256(ikm = pool secret, salt = pool_id(16) || 'StealthOS-RelayEnvelope-HMAC-Salt', info = 'envelope-integrity-v2', 32). Must differ from the v1 key.",
                "inputs": {"pool_id": POOL, "shared_secret_hex": SECRET.hex()}, "outputs": {"hmac_key_v2_hex": K2.hex(), "hmac_key_v1_hex": K1.hex()}})

TS = 821692800.0
cases = [
 ("directed", "Directed message, fresh from the origin.", "peer-origin", "peer-dest", 5, ["peer-origin"], b"e2e-ciphertext", TS, MSG),
 ("broadcast_nil_destination", "Broadcast: presence tag 0x00, no destination bytes.", "peer-origin", None, 5, ["peer-origin"], b"e2e-ciphertext", TS, MSG),
 ("empty_string_destination", "Destination \"\": presence tag 0x01 + zero length. MAC differs from the broadcast vector.", "peer-origin", "", 5, ["peer-origin"], b"e2e-ciphertext", TS, MSG),
 ("length_prefix_ab_cd", "origin 'ab', destination 'cd'.", "ab", "cd", 5, ["ab"], b"x", TS, MSG),
 ("length_prefix_abc_d", "origin 'abc', destination 'd': different MAC from ab/cd.", "abc", "d", 5, ["abc"], b"x", TS, MSG),
 ("unicode_peers", "Non-ASCII peer IDs are hashed as their UTF-8 bytes, NFC and NFD kept distinct.", "café-\U0001F510", "café", 5, ["café-\U0001F510"], b"\x00\x01\x02", TS, MSG),
 ("fractional_timestamp", "Timestamp with a fraction: the MAC covers the IEEE-754 bits of the JSON number itself.", "peer-origin", "peer-dest", 5, ["peer-origin"], b"e2e-ciphertext", 821692800.123, MSG),
 ("empty_payload", "Zero-length payload: u64 length 0 and no payload bytes.", "peer-origin", "peer-dest", 5, ["peer-origin"], b"", TS, MSG),
 ("relayed_two_hops", "After two relays: ttl 3, hopPath has origin + 2 relays; originTTL stays 5 and the MAC is unchanged.", "peer-origin", "peer-dest", 3, ["peer-origin", "relay-1", "relay-2"], b"e2e-ciphertext", TS, MSG),
 ("origin_ttl_3", "Origin created the envelope with ttl 3.", "peer-origin", None, 3, ["peer-origin"], b"payload", TS, "11111111-2222-4333-8444-555555555555"),
]
for name, desc, o, d, ttl, hops, payload, ts, mid in cases:
    otl = 5 if name != "origin_ttl_3" else 3
    i1 = v1_input(o, d, POOL, mid, ts); h1 = hmac.new(K1, i1, hashlib.sha256).digest()
    i2 = v2_input(o, d, POOL, mid, otl, ts, payload); h2 = hmac.new(K2, i2, hashlib.sha256).digest()
    vectors.append({"name": name, "kind": "envelope_v2", "expect": "ok", "description": desc,
        "inputs": {"origin_peer_id": o, "destination_peer_id": d, "ttl": ttl, "origin_ttl": otl, "hop_path": hops,
                   "payload_hex": payload.hex(), "pool_id": POOL, "receiver_pool_id": POOL, "message_id": mid,
                   "shared_secret_hex": SECRET.hex(), "timestamp_since_2001": ts},
        "outputs": {"envelope_json": env_json(o, d, ttl, hops, payload, POOL, mid, ts, h1, 2, otl, h2),
                    "hmac_v2_input_hex": i2.hex(), "hmac_v2_hex": h2.hex(), "hmac_v1_hex": h1.hex(),
                    "timestamp_f64_be_hex": struct.pack(">d", ts).hex()}})

# tamper vectors built from 'directed'
o, d, payload, ts = "peer-origin", "peer-dest", b"e2e-ciphertext", TS
def signed(o, d, payload, ts, otl=5, mid=MSG):
    h1 = hmac.new(K1, v1_input(o, d, POOL, mid, ts), hashlib.sha256).digest()
    h2 = hmac.new(K2, v2_input(o, d, POOL, mid, otl, ts, payload), hashlib.sha256).digest()
    return h1, h2
h1, h2 = signed(o, d, payload, ts)
hb1, hb2 = signed(o, None, payload, ts)
hab1, hab2 = signed("ab", "cd", b"x", ts)
tampers = [
 ("swap_payload", "encryptedPayload replaced by a relay.", env_json(o, d, 5, [o], b"other-ciphertext", POOL, MSG, ts, h1, 2, 5, h2)),
 ("destination_nil_to_empty", "Broadcast relabelled with destination \"\".", env_json(o, "", 5, [o], payload, POOL, MSG, ts, hb1, 2, 5, hb2)),
 ("destination_empty_to_nil", "Destination \"\" relabelled as broadcast.", env_json(o, None, 5, [o], payload, POOL, MSG, ts, *signed(o, "", payload, ts)[:1], 2, 5, signed(o, "", payload, ts)[1])),
 ("destination_retargeted", "Destination changed.", env_json(o, "peer-evil", 5, [o], payload, POOL, MSG, ts, h1, 2, 5, h2)),
 ("origin_changed", "originPeerID changed (hop path updated consistently).", env_json("peer-evil", d, 5, ["peer-evil"], payload, POOL, MSG, ts, h1, 2, 5, h2)),
 ("timestamp_plus_1s", "Timestamp moved by one second.", env_json(o, d, 5, [o], payload, POOL, MSG, ts + 1, h1, 2, 5, h2)),
 ("timestamp_one_ulp", "Timestamp changed in its last mantissa bit.", env_json(o, d, 5, [o], payload, POOL, MSG, struct.unpack(">d", (struct.unpack(">Q", struct.pack(">d", ts))[0] + 1).to_bytes(8, "big"))[0], h1, 2, 5, h2)),
 ("origin_ttl_raised", "originTTL raised from 5 to 6 (also above maxTTL).", env_json(o, d, 6, [o], payload, POOL, MSG, ts, h1, 2, 6, h2)),
 ("origin_ttl_lowered", "originTTL lowered from 5 to 4.", env_json(o, d, 4, [o], payload, POOL, MSG, ts, h1, 2, 4, h2)),
 ("ttl_above_origin_ttl", "Per-hop ttl raised above the MAC'd originTTL.", env_json(o, d, 6, [o], payload, POOL, MSG, ts, h1, 2, 5, h2)),
 ("ttl_inflated_keeping_hops", "A relay reset ttl to 5 but left two relays in hopPath (hops + ttl != originTTL + 1).", env_json(o, d, 5, [o, "r1", "r2"], payload, POOL, MSG, ts, h1, 2, 5, h2)),
 ("hop_path_not_starting_at_origin", "hopPath does not start with the origin.", env_json(o, d, 5, ["peer-evil"], payload, POOL, MSG, ts, h1, 2, 5, h2)),
 ("message_id_changed", "messageID changed.", env_json(o, d, 5, [o], payload, POOL, "0F1E2D3C-4B5A-4978-8695-A4B3C2D1E0F1", ts, h1, 2, 5, h2)),
 ("v2_tag_bit_flipped", "One bit of the v2 tag flipped.", env_json(o, d, 5, [o], payload, POOL, MSG, ts, h1, 2, 5, bytes([h2[0] ^ 1]) + h2[1:])),
 ("v2_tag_truncated", "v2 tag cut to 16 bytes.", env_json(o, d, 5, [o], payload, POOL, MSG, ts, h1, 2, 5, h2[:16])),
 ("v2_tag_removed_version_kept", "envelopeHMACV2 removed but envelopeVersion 2 kept: must not fall back to v1.", env_json(o, d, 5, [o], payload, POOL, MSG, ts, h1, 2, 5, None)),
 ("version_removed_tag_kept", "envelopeVersion removed but the v2 tag kept: still claims v2, must fail closed.", env_json(o, d, 5, [o], payload, POOL, MSG, ts, h1, None, 5, h2)),
 ("unknown_version_3", "envelopeVersion 3 (unknown to this build).", env_json(o, d, 5, [o], payload, POOL, MSG, ts, h1, 3, 5, h2)),
 ("v1_tag_used_as_v2", "The v1 tag placed in the v2 field.", env_json(o, d, 5, [o], payload, POOL, MSG, ts, h1, 2, 5, h1)),
 ("boundary_shift_ab_cd_to_abc_d", "Signed as origin 'ab'/dest 'cd', presented as origin 'abc'/dest 'd'.", env_json("abc", "d", 5, ["abc"], b"x", POOL, MSG, ts, hab1, 2, 5, hab2)),
 ("boundary_shift_ab_cd_to_a_bcd", "Signed as origin 'ab'/dest 'cd', presented as origin 'a'/dest 'bcd'.", env_json("a", "bcd", 5, ["a"], b"x", POOL, MSG, ts, hab1, 2, 5, hab2)),
 ("wrong_pool_receiver", "Valid envelope checked by a receiver in another pool.", env_json(o, d, 5, [o], payload, POOL, MSG, ts, h1, 2, 5, h2)),
]
for name, desc, j in tampers:
    recv = POOL if name != "wrong_pool_receiver" else "A0A0A0A0-B1B1-4C2C-8D3D-E4E4E4E4E4E5"
    vectors.append({"name": name, "kind": "envelope_v2_tamper", "expect": "error", "description": desc,
                    "inputs": {"envelope_json": j, "receiver_pool_id": recv, "shared_secret_hex": SECRET.hex()},
                    "outputs": {"verifies": False}})

doc = {
 "format": "relay-envelope-hmac-v2", "schema_version": 1,
 "description": "RelayEnvelope integrity v2 (StealthOS 1.5.0+). The v1 envelopeHMAC is still attached for 1.4.x peers; v2 receivers verify envelopeHMACV2 only. MAC input (big-endian): lp32('STEALTH_RELAY_ENVELOPE_V2') || lp32(origin UTF-8) || (0x00 | 0x01 || lp32(destination UTF-8)) || pool_id(16) || message_id(16) || u32 originTTL || u64 bits(timestamp seconds since 2001 as f64) || u64 len || payload.",
 "sources": ["LocalPackages/ConnectionPool/Sources/Models/RelayEnvelope+V2.swift"],
 "verification": "production+reference",
 "notes": [
  "lp32(x) = u32 big-endian byte length of x, then x.",
  "The timestamp is the JSON 'timestamp' number (seconds since 2001-01-01, Foundation's default Date encoding) as IEEE-754 binary64 big-endian; no 1970 conversion.",
  "JSON keys added in v2: envelopeVersion (2), originTTL (int), envelopeHMACV2 (base64). Absent on v1 envelopes; 1.4.x decoders ignore them, and 1.4.x relays drop them when they re-encode.",
  "Routing invariants enforced after the MAC: 1 <= ttl <= originTTL <= 5, hopPath[0] == originPeerID, len(hopPath) + ttl == originTTL + 1.",
  "Any v2 field present means the envelope is verified as v2 only; there is no fallback to the v1 MAC.",
  "envelope_json here is serialised with sorted keys by the reference generator; Swift's JSONEncoder key order differs. Compare decoded values, not bytes.",
  "Generated by an independent Python reference (hmac/hashlib), not by the Swift code under test."
 ],
 "vectors": vectors}
json.dump(doc, open(sys.argv[1], "w"), indent=2, ensure_ascii=False, sort_keys=True)
print(len(vectors))
