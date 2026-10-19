# Independent reference generator for relay_envelope_hmac_v2.json (next to this file).
# Usage: python3 -I generate_relay_envelope_hmac_v2.py <output.json>
# Needs the standard library plus `cryptography` (Ed25519, RFC 8032 deterministic signatures).
# Output must match the committed JSON exactly.
import hmac, hashlib, json, struct, uuid, base64, sys
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives import serialization

def hkdf(ikm, salt, info, n=32):
    if not salt: salt = b"\0" * 32
    prk = hmac.new(salt, ikm, hashlib.sha256).digest()
    out, t, i = b"", b"", 1
    while len(out) < n:
        t = hmac.new(prk, t + info + bytes([i]), hashlib.sha256).digest(); out += t; i += 1
    return out[:n]

def lp(b): return struct.pack(">I", len(b)) + b
def ub(u): return uuid.UUID(u).bytes

def seed_for(peer): return hashlib.sha256(b"golden-envelope-signing-seed:" + peer.encode()).digest()
def sk(peer): return Ed25519PrivateKey.from_private_bytes(seed_for(peer))
def pub(peer): return sk(peer).public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)

SECRET = bytes.fromhex("3c3d3e3f404142434445464748494a4b4c4d4e4f505152535455565758595a5b")
SECRET2 = bytes.fromhex("5c5d5e5f606162636465666768696a6b6c6d6e6f707172737475767778797a7b")
POOL = "A0A0A0A0-B1B1-4C2C-8D3D-E4E4E4E4E4E4"
POOL2 = "A0A0A0A0-B1B1-4C2C-8D3D-E4E4E4E4E4E5"
MSG = "0F1E2D3C-4B5A-4978-8695-A4B3C2D1E0F0"
def keys(secret, pool):
    salt = ub(pool) + b"StealthOS-RelayEnvelope-HMAC-Salt"
    return hkdf(secret, salt, b"envelope-integrity-v1"), hkdf(secret, salt, b"envelope-integrity-v2")
K1, K2 = keys(SECRET, POOL)

def v1_input(o, d, pool, mid, ts):
    return lp(o.encode()) + lp((d or "").encode()) + ub(pool) + ub(mid) + struct.pack("<q", 5) + struct.pack("<d", ts + 978307200.0)

def v2_input(o, d, pool, mid, otl, ts, payload, intro=None):
    b = lp(b"STEALTH_RELAY_ENVELOPE_V2") + lp(o.encode())
    b += b"\x00" if d is None else b"\x01" + lp(d.encode())
    b += ub(pool) + ub(mid) + struct.pack(">I", otl) + struct.pack(">d", ts) + struct.pack(">Q", len(payload)) + payload
    b += b"\x00" if intro is None else b"\x01" + intro
    return b

def env_json(o, d, ttl, hops, payload, pool, mid, ts, h1, v, otl, h2, sig, intro=None):
    j = {"messageID": mid.upper(), "originPeerID": o, "ttl": ttl, "hopPath": hops,
         "encryptedPayload": base64.b64encode(payload).decode(), "poolID": pool.upper(), "timestamp": ts}
    if d is not None: j["destinationPeerID"] = d
    if h1 is not None: j["envelopeHMAC"] = base64.b64encode(h1).decode()
    if v is not None: j["envelopeVersion"] = v
    if otl is not None: j["originTTL"] = otl
    if h2 is not None: j["envelopeHMACV2"] = base64.b64encode(h2).decode()
    if sig is not None: j["originSignature"] = base64.b64encode(sig).decode()
    if intro is not None: j["originIntroduction"] = base64.b64encode(intro).decode()
    return json.dumps(j, ensure_ascii=False, sort_keys=True)

def signed(o, d, payload, ts, otl=5, mid=MSG, pool=POOL, secret=SECRET, signer=None, intro=None):
    k1, k2 = keys(secret, pool)
    h1 = hmac.new(k1, v1_input(o, d, pool, mid, ts), hashlib.sha256).digest()
    i2 = v2_input(o, d, pool, mid, otl, ts, payload, intro)
    h2 = hmac.new(k2, i2, hashlib.sha256).digest()
    s = sk(signer or o).sign(i2)
    return h1, h2, s, i2

KNOWN = ["peer-origin", "ab", "abc", "a", "café-\U0001F510", "peer-mallory"]
def known_signers(peers=KNOWN): return {p: pub(p).hex() for p in peers}

vectors = []
vectors.append({"name": "hmac_key_v2", "kind": "hmac_key_v2", "expect": "ok",
    "description": "v2 pool MAC key: HKDF-SHA256(ikm = pool secret, salt = pool_id(16) || 'StealthOS-RelayEnvelope-HMAC-Salt', info = 'envelope-integrity-v2', 32). Must differ from the v1 key.",
    "inputs": {"pool_id": POOL, "shared_secret_hex": SECRET.hex()}, "outputs": {"hmac_key_v2_hex": K2.hex(), "hmac_key_v1_hex": K1.hex()}})

# Signing-key binding (carried in KeyExchangePayload).
X25519 = bytes.fromhex("07a37cbc142093c8b755dc1b10e86cb426374ad16aa853ed0bdfc0b2b86d1c7c")
def statement(peer, pool, x, spub):
    return lp(b"STEALTH_ENVELOPE_SIGNING_KEY_V2") + lp(peer.encode()) + ub(pool) + x + spub
for peer in ["peer-origin", "café-\U0001F510", ""]:
    st = statement(peer, POOL, X25519, pub(peer or "empty"))
    sig = sk(peer or "empty").sign(st)
    vectors.append({"name": "binding_" + (hashlib.sha256(peer.encode()).hexdigest()[:8] if peer else "empty_peer"), "kind": "signing_key_binding", "expect": "ok",
        "description": "Binding statement lp32('STEALTH_ENVELOPE_SIGNING_KEY_V2') || lp32(peerID) || poolID(16) || X25519(32) || Ed25519(32), signed by the Ed25519 key.",
        "inputs": {"peer_id": peer, "pool_id": POOL, "key_agreement_public_hex": X25519.hex(), "signing_seed_hex": seed_for(peer or "empty").hex()},
        "outputs": {"signing_public_hex": pub(peer or "empty").hex(), "statement_hex": st.hex(), "binding_signature_hex": sig.hex()}})
st = statement("peer-origin", POOL, X25519, pub("peer-origin")); good = sk("peer-origin").sign(st)
for name, desc, peer, pool, x, spub, sig in [
    ("binding_other_peer_id", "Valid binding for 'peer-origin' presented by 'peer-evil'.", "peer-evil", POOL, X25519, pub("peer-origin"), good),
    ("binding_other_pool", "Valid binding replayed into another pool.", "peer-origin", POOL2, X25519, pub("peer-origin"), good),
    ("binding_other_key_agreement_key", "Valid binding attached to a different X25519 key.", "peer-origin", POOL, bytes(31) + b"\x09", pub("peer-origin"), good),
    ("binding_substituted_signing_key", "Binding signed by the real key but presenting the attacker's signing key.", "peer-origin", POOL, X25519, pub("peer-mallory"), good),
    ("binding_bit_flip", "One bit of the binding signature flipped.", "peer-origin", POOL, X25519, pub("peer-origin"), bytes([good[0] ^ 1]) + good[1:]),
]:
    vectors.append({"name": name, "kind": "signing_key_binding", "expect": "error", "description": desc,
        "inputs": {"peer_id": peer, "pool_id": pool, "key_agreement_public_hex": x.hex(), "signing_public_hex": spub.hex(), "binding_signature_hex": sig.hex()},
        "outputs": {}})

TS = 821692800.0
cases = [
 ("directed", "Directed message, fresh from the origin.", "peer-origin", "peer-dest", 5, ["peer-origin"], b"e2e-ciphertext", TS, MSG, 5),
 ("broadcast_nil_destination", "Broadcast: presence tag 0x00, no destination bytes.", "peer-origin", None, 5, ["peer-origin"], b"e2e-ciphertext", TS, MSG, 5),
 ("empty_string_destination", "Destination \"\": presence tag 0x01 + zero length. MAC and signature differ from the broadcast vector.", "peer-origin", "", 5, ["peer-origin"], b"e2e-ciphertext", TS, MSG, 5),
 ("length_prefix_ab_cd", "origin 'ab', destination 'cd'.", "ab", "cd", 5, ["ab"], b"x", TS, MSG, 5),
 ("length_prefix_abc_d", "origin 'abc', destination 'd': different MAC from ab/cd.", "abc", "d", 5, ["abc"], b"x", TS, MSG, 5),
 ("unicode_peers", "Non-ASCII peer IDs are hashed as their UTF-8 bytes, NFC and NFD kept distinct.", "café-\U0001F510", "café", 5, ["café-\U0001F510"], b"\x00\x01\x02", TS, MSG, 5),
 ("fractional_timestamp", "Timestamp with a fraction: the MAC covers the IEEE-754 bits of the JSON number itself.", "peer-origin", "peer-dest", 5, ["peer-origin"], b"e2e-ciphertext", 821692800.123, MSG, 5),
 ("empty_payload", "Zero-length payload: u64 length 0 and no payload bytes.", "peer-origin", "peer-dest", 5, ["peer-origin"], b"", TS, MSG, 5),
 ("relayed_two_hops", "After two relays: ttl 3, hopPath has origin + 2 relays; originTTL, MAC and signature are unchanged.", "peer-origin", "peer-dest", 3, ["peer-origin", "relay-1", "relay-2"], b"e2e-ciphertext", TS, MSG, 5),
 ("origin_ttl_3", "Origin created the envelope with ttl 3.", "peer-origin", None, 3, ["peer-origin"], b"payload", TS, "11111111-2222-4333-8444-555555555555", 3),
]
for name, desc, o, d, ttl, hops, payload, ts, mid, otl in cases:
    h1, h2, sig, i2 = signed(o, d, payload, ts, otl, mid)
    vectors.append({"name": name, "kind": "envelope_v2", "expect": "ok", "description": desc,
        "inputs": {"origin_peer_id": o, "destination_peer_id": d, "ttl": ttl, "origin_ttl": otl, "hop_path": hops,
                   "payload_hex": payload.hex(), "pool_id": POOL, "receiver_pool_id": POOL, "message_id": mid,
                   "shared_secret_hex": SECRET.hex(), "timestamp_since_2001": ts,
                   "origin_signing_seed_hex": seed_for(o).hex(), "known_signers": known_signers()},
        "outputs": {"envelope_json": env_json(o, d, ttl, hops, payload, POOL, mid, ts, h1, 2, otl, h2, sig),
                    "hmac_v2_input_hex": i2.hex(), "hmac_v2_hex": h2.hex(), "hmac_v1_hex": h1.hex(),
                    "origin_signing_public_hex": pub(o).hex(), "origin_signature_hex": sig.hex(),
                    "timestamp_f64_be_hex": struct.pack(">d", ts).hex()}})

o, d, payload, ts = "peer-origin", "peer-dest", b"e2e-ciphertext", TS
h1, h2, sig, _ = signed(o, d, payload, ts)
hb1, hb2, sb, _ = signed(o, None, payload, ts)
he1, he2, se, _ = signed(o, "", payload, ts)
hab1, hab2, sab, _ = signed("ab", "cd", b"x", ts)
fh1, fh2, fsig, _ = signed(o, d, b"forged-by-member", ts, signer="peer-mallory")   # member forges origin
_, _, sig_other_payload, _ = signed(o, d, b"a-different-payload", ts)              # genuine sig, other payload
_, _, sig_by_mallory, _ = signed(o, d, payload, ts, signer="peer-mallory")         # right bytes, wrong key
x1, x2, xsig, _ = signed(o, d, payload, ts, pool=POOL2, secret=SECRET2)            # valid in pool 2
_, rem2, _, _ = signed(o, d, payload, ts)                                           # insider re-MAC for pool 1
def flipped(b, i=0): return bytes([b[i] ^ 1]) + b[i + 1:] if i == 0 else b[:i] + bytes([b[i] ^ 1]) + b[i + 1:]
uh1, uh2, usig, _ = signed("peer-unknown", d, payload, ts)

R = "rejected_invalid"
tampers = [
 ("swap_payload", "encryptedPayload replaced by a relay.", env_json(o, d, 5, [o], b"other-ciphertext", POOL, MSG, ts, h1, 2, 5, h2, sig), POOL, R),
 ("destination_nil_to_empty", "Broadcast relabelled with destination \"\".", env_json(o, "", 5, [o], payload, POOL, MSG, ts, hb1, 2, 5, hb2, sb), POOL, R),
 ("destination_empty_to_nil", "Destination \"\" relabelled as broadcast.", env_json(o, None, 5, [o], payload, POOL, MSG, ts, he1, 2, 5, he2, se), POOL, R),
 ("destination_retargeted", "Destination changed.", env_json(o, "peer-evil", 5, [o], payload, POOL, MSG, ts, h1, 2, 5, h2, sig), POOL, R),
 ("origin_changed", "originPeerID changed (hop path updated consistently).", env_json("peer-mallory", d, 5, ["peer-mallory"], payload, POOL, MSG, ts, h1, 2, 5, h2, sig), POOL, R),
 ("timestamp_plus_1s", "Timestamp moved by one second.", env_json(o, d, 5, [o], payload, POOL, MSG, ts + 1, h1, 2, 5, h2, sig), POOL, R),
 ("timestamp_one_ulp", "Timestamp changed in its last mantissa bit.", env_json(o, d, 5, [o], payload, POOL, MSG, struct.unpack(">d", (struct.unpack(">Q", struct.pack(">d", ts))[0] + 1).to_bytes(8, "big"))[0], h1, 2, 5, h2, sig), POOL, R),
 ("origin_ttl_raised", "originTTL raised from 5 to 6 (also above maxTTL).", env_json(o, d, 6, [o], payload, POOL, MSG, ts, h1, 2, 6, h2, sig), POOL, R),
 ("origin_ttl_lowered", "originTTL lowered from 5 to 4.", env_json(o, d, 4, [o], payload, POOL, MSG, ts, h1, 2, 4, h2, sig), POOL, R),
 ("ttl_above_origin_ttl", "Per-hop ttl raised above the MAC'd originTTL.", env_json(o, d, 6, [o], payload, POOL, MSG, ts, h1, 2, 5, h2, sig), POOL, R),
 ("ttl_inflated_keeping_hops", "A relay reset ttl to 5 but left two relays in hopPath.", env_json(o, d, 5, [o, "r1", "r2"], payload, POOL, MSG, ts, h1, 2, 5, h2, sig), POOL, R),
 ("hop_path_not_starting_at_origin", "hopPath does not start with the origin.", env_json(o, d, 5, ["peer-evil"], payload, POOL, MSG, ts, h1, 2, 5, h2, sig), POOL, R),
 ("message_id_changed", "messageID changed.", env_json(o, d, 5, [o], payload, POOL, "0F1E2D3C-4B5A-4978-8695-A4B3C2D1E0F1", ts, h1, 2, 5, h2, sig), POOL, R),
 ("v2_tag_bit_flipped", "One bit of the v2 MAC flipped.", env_json(o, d, 5, [o], payload, POOL, MSG, ts, h1, 2, 5, flipped(h2), sig), POOL, R),
 ("v2_tag_truncated", "v2 MAC cut to 16 bytes.", env_json(o, d, 5, [o], payload, POOL, MSG, ts, h1, 2, 5, h2[:16], sig), POOL, R),
 ("v2_tag_removed_version_kept", "envelopeHMACV2 removed but envelopeVersion 2 kept: must not fall back to v1.", env_json(o, d, 5, [o], payload, POOL, MSG, ts, h1, 2, 5, None, sig), POOL, R),
 ("version_removed_tag_kept", "envelopeVersion removed but the v2 MAC kept: still claims v2, must fail closed.", env_json(o, d, 5, [o], payload, POOL, MSG, ts, h1, None, 5, h2, sig), POOL, R),
 ("unknown_version_3", "envelopeVersion 3 (unknown to this build).", env_json(o, d, 5, [o], payload, POOL, MSG, ts, h1, 3, 5, h2, sig), POOL, R),
 ("v1_tag_used_as_v2", "The v1 MAC placed in the v2 field.", env_json(o, d, 5, [o], payload, POOL, MSG, ts, h1, 2, 5, h1, sig), POOL, R),
 ("boundary_shift_ab_cd_to_abc_d", "Signed as origin 'ab'/dest 'cd', presented as origin 'abc'/dest 'd'.", env_json("abc", "d", 5, ["abc"], b"x", POOL, MSG, ts, hab1, 2, 5, hab2, sab), POOL, R),
 ("boundary_shift_ab_cd_to_a_bcd", "Signed as origin 'ab'/dest 'cd', presented as origin 'a'/dest 'bcd'.", env_json("a", "bcd", 5, ["a"], b"x", POOL, MSG, ts, hab1, 2, 5, hab2, sab), POOL, R),
 ("wrong_pool_receiver", "Valid envelope checked by a receiver in another pool.", env_json(o, d, 5, [o], payload, POOL, MSG, ts, h1, 2, 5, h2, sig), POOL2, R),
 # Per-sender authenticity: every one of these carries a VALID pool MAC.
 ("member_forges_origin", "A pool member (peer-mallory, who holds the pool secret) builds an envelope claiming origin peer-origin with a valid v1 and v2 MAC, signed with its own key.", env_json(o, d, 5, [o], b"forged-by-member", POOL, MSG, ts, fh1, 2, 5, fh2, fsig), POOL, R),
 ("signature_stripped", "originSignature removed; both MACs valid.", env_json(o, d, 5, [o], payload, POOL, MSG, ts, h1, 2, 5, h2, None), POOL, R),
 ("signature_key_substitution", "Signature over the right bytes but made with another member's key.", env_json(o, d, 5, [o], payload, POOL, MSG, ts, h1, 2, 5, h2, sig_by_mallory), POOL, R),
 ("signature_for_other_payload", "Genuine origin signature lifted from an envelope with a different payload; the pool MAC was recomputed by an insider.", env_json(o, d, 5, [o], payload, POOL, MSG, ts, h1, 2, 5, h2, sig_other_payload), POOL, R),
 ("signature_bit_flipped", "One bit of the origin signature flipped.", env_json(o, d, 5, [o], payload, POOL, MSG, ts, h1, 2, 5, h2, flipped(sig, 40)), POOL, R),
 ("signature_truncated", "Origin signature cut to 63 bytes.", env_json(o, d, 5, [o], payload, POOL, MSG, ts, h1, 2, 5, h2, sig[:63]), POOL, R),
 ("cross_pool_replay_remac", "Genuine envelope from pool 2 replayed into pool 1: an insider of pool 1 rewrites poolID and recomputes pool 1's MACs, but the origin signature covers pool 2.", env_json(o, d, 5, [o], payload, POOL, MSG, ts, h1, 2, 5, rem2, xsig), POOL, R),
 ("unknown_signer", "Fully valid envelope from an origin this receiver never exchanged keys with: forward only, never deliver.", env_json("peer-unknown", d, 5, ["peer-unknown"], payload, POOL, MSG, ts, uh1, 2, 5, uh2, usig), POOL, "relay_only"),
]
for name, desc, j, recv, verdict in tampers:
    vectors.append({"name": name, "kind": "envelope_v2_tamper", "expect": "error", "description": desc,
                    "inputs": {"envelope_json": j, "receiver_pool_id": recv, "shared_secret_hex": SECRET.hex(), "known_signers": known_signers()},
                    "outputs": {"verdict": verdict}})

# Introductions (relayed key exchange, first contact through relays).
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey
def x25519_pub(peer):
    k = X25519PrivateKey.from_private_bytes(hashlib.sha256(b"golden-x25519-seed:" + peer.encode()).digest())
    return k.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
def intro_for(peer, pool=POOL, as_peer=None, signer=None):
    x = x25519_pub(peer)
    spub = pub(signer or peer)
    binding = sk(signer or peer).sign(statement(as_peer or peer, pool, x, spub))
    return x + spub + binding
NEW = "peer-newcomer"
it = intro_for(NEW)
ih1, ih2, isig, ii2 = signed(NEW, "peer-dest", b"relayed-key-exchange", TS, intro=it)
vectors.append({"name": "introduction_first_contact", "kind": "envelope_v2", "expect": "ok",
    "description": "First contact through relays: the envelope introduces the origin's X25519 and Ed25519 keys with their binding; the receiver has no key for the origin yet and verifies everything end to end.",
    "inputs": {"origin_peer_id": NEW, "destination_peer_id": "peer-dest", "ttl": 5, "origin_ttl": 5, "hop_path": [NEW],
               "payload_hex": b"relayed-key-exchange".hex(), "pool_id": POOL, "receiver_pool_id": POOL, "message_id": MSG,
               "shared_secret_hex": SECRET.hex(), "timestamp_since_2001": TS,
               "origin_signing_seed_hex": seed_for(NEW).hex(), "known_signers": known_signers()},
    "outputs": {"envelope_json": env_json(NEW, "peer-dest", 5, [NEW], b"relayed-key-exchange", POOL, MSG, TS, ih1, 2, 5, ih2, isig, it),
                "hmac_v2_input_hex": ii2.hex(), "hmac_v2_hex": ih2.hex(), "hmac_v1_hex": ih1.hex(),
                "origin_signing_public_hex": pub(NEW).hex(), "origin_signature_hex": isig.hex(),
                "origin_introduction_hex": it.hex(), "introduced_key_agreement_hex": x25519_pub(NEW).hex(),
                "timestamp_f64_be_hex": struct.pack(">d", TS).hex()}})
# Insider impersonation at a receiver that already knows the newcomer's real key.
fake = intro_for(NEW, signer="peer-mallory")
fh1b, fh2b, fsigb, _ = signed(NEW, "peer-dest", b"relayed-key-exchange", TS, intro=fake, signer="peer-mallory")
known_with_new = known_signers(KNOWN + [NEW])
bad_binding = intro_for(NEW, pool=POOL2)
bh1, bh2, bsig, _ = signed(NEW, "peer-dest", b"relayed-key-exchange", TS, intro=bad_binding)
wrong_peer = intro_for(NEW, as_peer="peer-other")
wh1, wh2, wsig, _ = signed(NEW, "peer-dest", b"relayed-key-exchange", TS, intro=wrong_peer)
for name, desc, j, known, verdict in [
    ("introduction_conflicting_key", "A member introduces its own key for peer-newcomer to a receiver that already holds the newcomer's real key: refused as a key change.",
     env_json(NEW, "peer-dest", 5, [NEW], b"relayed-key-exchange", POOL, MSG, TS, fh1b, 2, 5, fh2b, fsigb, fake), known_with_new, "key_change"),
    ("introduction_binding_other_pool", "Introduction binding made for another pool.",
     env_json(NEW, "peer-dest", 5, [NEW], b"relayed-key-exchange", POOL, MSG, TS, bh1, 2, 5, bh2, bsig, bad_binding), known_signers(), "rejected_invalid"),
    ("introduction_binding_other_peer", "Introduction binding made for another peer ID.",
     env_json(NEW, "peer-dest", 5, [NEW], b"relayed-key-exchange", POOL, MSG, TS, wh1, 2, 5, wh2, wsig, wrong_peer), known_signers(), "rejected_invalid"),
    ("introduction_stripped", "A relay removes the introduction: the MAC and signature cover it, so the envelope fails.",
     env_json(NEW, "peer-dest", 5, [NEW], b"relayed-key-exchange", POOL, MSG, TS, ih1, 2, 5, ih2, isig, None), known_signers(), "rejected_invalid"),
    ("introduction_key_agreement_swapped", "A relay swaps the introduced X25519 key for its own.",
     env_json(NEW, "peer-dest", 5, [NEW], b"relayed-key-exchange", POOL, MSG, TS, ih1, 2, 5, ih2, isig, x25519_pub("peer-mallory") + it[32:]), known_signers(), "rejected_invalid"),
]:
    vectors.append({"name": name, "kind": "envelope_v2_tamper", "expect": "error", "description": desc,
                    "inputs": {"envelope_json": j, "receiver_pool_id": POOL, "shared_secret_hex": SECRET.hex(), "known_signers": known},
                    "outputs": {"verdict": verdict}})

doc = {
 "format": "relay-envelope-hmac-v2", "schema_version": 1,
 "description": "RelayEnvelope integrity v2 (StealthOS 1.5.0+). The v1 envelopeHMAC is still attached for 1.4.x peers; v2 receivers check the v2 pool MAC (cheap filter), the routing invariants, and the origin's Ed25519 signature. MAC/signature input (big-endian): lp32('STEALTH_RELAY_ENVELOPE_V2') || lp32(origin UTF-8) || (0x00 | 0x01 || lp32(destination UTF-8)) || pool_id(16) || message_id(16) || u32 originTTL || u64 bits(timestamp seconds since 2001 as f64) || u64 len || payload.",
 "sources": ["LocalPackages/ConnectionPool/Sources/Models/RelayEnvelope+V2.swift", "LocalPackages/ConnectionPool/Sources/Security/EnvelopeSigningKeys.swift"],
 "verification": "production+reference",
 "notes": [
  "lp32(x) = u32 big-endian byte length of x, then x.",
  "The timestamp is the JSON 'timestamp' number (seconds since 2001-01-01, Foundation's default Date encoding) as IEEE-754 binary64 big-endian; no 1970 conversion.",
  "JSON keys added in v2: envelopeVersion (2), originTTL (int), envelopeHMACV2 (base64), originSignature (base64, 64 bytes). Absent on v1 envelopes; 1.4.x decoders ignore them, and 1.4.x relays drop them when they re-encode.",
  "originSignature = Ed25519 (RFC 8032) by the origin's per-session signing key over exactly the v2 MAC input. Signatures here are deterministic (RFC 8032); CryptoKit's are randomised, so readers must verify, not compare, signatures they produce.",
  "Receivers look up the origin's signing key from its E2E key exchange (KeyExchangePayload.signingPublicKey + signingKeyBinding). Unknown signer: forward only, never deliver. A different key for a known peer in the same session is refused.",
  "signing_key_binding: statement = lp32('STEALTH_ENVELOPE_SIGNING_KEY_V2') || lp32(peerID UTF-8) || poolID(16) || X25519 key-agreement public key(32) || Ed25519 signing public key(32), signed by the Ed25519 key.",
  "Routing invariants enforced after the MAC: 1 <= ttl <= originTTL <= 5, hopPath[0] == originPeerID, len(hopPath) + ttl == originTTL + 1.",
  "Any v2 field present means the envelope is verified as v2 only; there is no fallback to the v1 MAC.",
  "Signing seeds are SHA-256('golden-envelope-signing-seed:' || peerID UTF-8); known_signers maps peer IDs to the receiver's registered public keys.",
  "The MAC/signature input ends with u8 0x00, or u8 0x01 || originIntroduction (X25519(32) || Ed25519(32) || binding(64)). An introduction lets a receiver with no key for the origin verify it end to end (binding for origin ID, pool and E2E key, plus the signature); a different key for an origin already known is refused (key_change).",
  "X25519 seeds for introductions are SHA-256('golden-x25519-seed:' || peerID UTF-8).",
  "envelope_json is serialised with sorted keys by this generator; Swift's JSONEncoder key order differs. Compare decoded values, not bytes.",
  "Generated by an independent Python reference (hmac/hashlib + cryptography Ed25519), not by the Swift code under test."
 ],
 "vectors": vectors}
json.dump(doc, open(sys.argv[1], "w"), indent=2, ensure_ascii=False, sort_keys=True)
print(len(vectors))
