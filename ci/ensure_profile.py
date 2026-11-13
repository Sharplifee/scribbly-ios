"""Makes sure an App Store provisioning profile exists for a bundle id,
registering the bundle id first if Apple doesn't know it yet.
Usage: ensure_profile.py <bundle id> <profile name> <out.mobileprovision>
Needs /tmp/dist.pem (the signing cert) and the ASC_* env vars."""
import base64, json, os, subprocess, sys, time, urllib.request, urllib.error
import jwt  # pyjwt

BUNDLE, NAME, OUT = sys.argv[1], sys.argv[2], sys.argv[3]
API = "https://api.appstoreconnect.apple.com/v1"
key = base64.b64decode(os.environ["ASC_KEY_P8"]).decode()
tok = jwt.encode({"iss": os.environ["ASC_ISSUER_ID"], "iat": int(time.time()), "exp": int(time.time()) + 1100,
                  "aud": "appstoreconnect-v1"}, key, algorithm="ES256", headers={"kid": os.environ["ASC_KEY_ID"]})

def call(method, path, body=None):
    req = urllib.request.Request(API + path, method=method, data=json.dumps(body).encode() if body else None,
                                 headers={"Authorization": "Bearer " + tok, "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req) as r:
            return json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        print(f"{method} {path} -> {e.code} {e.read()[:600]!r}", file=sys.stderr); raise

found = [x for x in call("GET", f"/bundleIds?filter[identifier]={BUNDLE}&limit=20")["data"]
         if x["attributes"]["identifier"] == BUNDLE]
if found:
    bundle = found[0]
else:
    bundle = call("POST", "/bundleIds", {"data": {"type": "bundleIds", "attributes": {
        "identifier": BUNDLE, "name": NAME.replace(" CI", ""), "platform": "IOS"}}})["data"]
    print("registered bundle id", BUNDLE, file=sys.stderr)

serial = subprocess.check_output(["bash", "-c", "openssl x509 -in /tmp/dist.pem -noout -serial"]).decode().split("=")[1].strip().lstrip("0").upper()
cert = next(c for c in call("GET", "/certificates?limit=50")["data"]
            if c["attributes"]["serialNumber"].lstrip("0").upper() == serial)

existing = call("GET", f"/profiles?filter[name]={urllib.request.quote(NAME)}&limit=10")["data"]
prof = next((p for p in existing if p["attributes"]["profileState"] == "ACTIVE"), None)
if prof is None:
    prof = call("POST", "/profiles", {"data": {"type": "profiles",
        "attributes": {"name": NAME, "profileType": "IOS_APP_STORE"},
        "relationships": {"bundleId": {"data": {"type": "bundleIds", "id": bundle["id"]}},
                          "certificates": {"data": [{"type": "certificates", "id": cert["id"]}]}}}})["data"]
    print("created profile", prof["id"], file=sys.stderr)
open(OUT, "wb").write(base64.b64decode(prof["attributes"]["profileContent"]))
print(NAME)
